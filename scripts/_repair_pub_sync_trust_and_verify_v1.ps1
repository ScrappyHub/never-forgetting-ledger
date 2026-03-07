param(
  [Parameter()][string]$RepoRoot = "C:\dev\nfl"
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Write-Utf8NoBom([string]$Path,[string]$Text) {
  $enc = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Get-OpenSshKeygenPath {
  $exe = Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"
  if (-not (Test-Path -LiteralPath $exe)) { throw ("Missing OpenSSH ssh-keygen: " + $exe) }
  return $exe
}

function Run-Keygen-CaptureStdout([string[]]$Argv, [int]$TimeoutSeconds = 20) {
  if ($null -eq $Argv -or $Argv.Count -eq 0) { throw "Run-Keygen Argv null/empty" }
  $exe = Get-OpenSshKeygenPath

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = (@($Argv) -join " ")
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.RedirectStandardInput  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  if (-not $p.Start()) { throw ("ssh-keygen failed to start: " + $exe) }

  # close stdin so it can never prompt/block
  try { $p.StandardInput.Close() } catch { }

  if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
    try { $p.Kill() } catch { }
    throw ("ssh-keygen timed out after " + $TimeoutSeconds + "s: " + $psi.Arguments)
  }

  $stdout = ""
  $stderr = ""
  try { $stdout = $p.StandardOutput.ReadToEnd() } catch { }
  try { $stderr = $p.StandardError.ReadToEnd() } catch { }

  if ($p.ExitCode -ne 0) {
    $msg = ("ssh-keygen failed (exit " + $p.ExitCode + "): " + $psi.Arguments)
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { $msg += "`r`nSTDERR:`r`n" + $stderr.TrimEnd() }
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { $msg += "`r`nSTDOUT:`r`n" + $stdout.TrimEnd() }
    throw $msg
  }

  return $stdout.Trim()
}

$Root = $RepoRoot
if (-not (Test-Path -LiteralPath $Root)) { throw ("Missing repo root: " + $Root) }

$KeysDir  = Join-Path $Root "proofs\keys"
$TrustDir = Join-Path $Root "proofs\trust"

$Priv = Join-Path $KeysDir "nfl-local_ed25519"
$Pub  = $Priv + ".pub"

$Tb = Join-Path $TrustDir "trust_bundle.json"
$As = Join-Path $TrustDir "allowed_signers"
$Sig = $Tb + ".sig"

foreach ($p in @($KeysDir,$TrustDir)) {
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
}
if (-not (Test-Path -LiteralPath $Priv)) { throw ("Missing private key: " + $Priv + " (re-run CANON2 bootstrap)") }

# Backup key + trust artifacts
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
if (Test-Path -LiteralPath $Pub) { Copy-Item -LiteralPath $Pub -Destination ($Pub + ".bak_" + $stamp) -Force }
if (Test-Path -LiteralPath $Tb)  { Copy-Item -LiteralPath $Tb  -Destination ($Tb  + ".bak_" + $stamp) -Force }
if (Test-Path -LiteralPath $As)  { Copy-Item -LiteralPath $As  -Destination ($As  + ".bak_" + $stamp) -Force }
if (Test-Path -LiteralPath $Sig) { Copy-Item -LiteralPath $Sig -Destination ($Sig + ".bak_" + $stamp) -Force }

# 1) Authoritative step: derive pubkey from private key, overwrite .pub
# ssh-keygen -y -f <priv> prints a single "ssh-ed25519 AAAA... comment" line
$pubLine = Run-Keygen-CaptureStdout -Argv @("-y","-f",$Priv) -TimeoutSeconds 20
if ([string]::IsNullOrWhiteSpace($pubLine)) { throw "Derived pubkey line was empty." }

Write-Utf8NoBom -Path $Pub -Text ($pubLine.TrimEnd() + "`r`n")
("WROTE_SYNCED_PUB: " + $Pub) | Out-Host

# 2) Rebuild trust_bundle.json + allowed_signers deterministically
$Principal = "single-tenant/local/authority/nfl"
$KeyId     = "dev-1"
$Namespaces = @("nfl/ingest-receipt")
$createdUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$L = @()
$L += "{"
$L += '  "schema": "neverlost.trust_bundle.v1",'
$L += ('  "created_utc": "' + $createdUtc + '",')
$L += '  "principals": ['
$L += "    {"
$L += ('      "principal": "' + $Principal + '",')
$L += '      "keys": ['
$L += "        {"
$L += ('          "key_id": "' + $KeyId + '",')
$L += ('          "pubkey": "' + ($pubLine -replace '"','\"') + '",')
$L += '          "namespaces": ['
for ($i=0; $i -lt $Namespaces.Count; $i++) {
  $ns = $Namespaces[$i]
  $comma = if ($i -lt ($Namespaces.Count-1)) { "," } else { "" }
  $L += ('            "' + ($ns -replace '"','\"') + '"' + $comma)
}
$L += '          ]'
$L += "        }"
$L += '      ]'
$L += "    }"
$L += '  ]'
$L += "}"

Write-Utf8NoBom -Path $Tb -Text (($L -join "`r`n") + "`r`n")
("WROTE: " + $Tb) | Out-Host

$als = @()
foreach ($ns in $Namespaces) {
  $als += ($Principal + " " + $ns + " " + $pubLine)
}
Write-Utf8NoBom -Path $As -Text (($als -join "`r`n") + "`r`n")
("WROTE: " + $As) | Out-Host

# 3) Re-sign + verify using your existing scripts (deterministic: delete .sig first)
$SignScript = Join-Path $Root "scripts\sign_file_v1.ps1"
$VerScript  = Join-Path $Root "scripts\verify_sig_v1.ps1"
foreach ($p in @($SignScript,$VerScript)) { if (-not (Test-Path -LiteralPath $p)) { throw ("Missing script: " + $p) } }

if (Test-Path -LiteralPath $Sig) { Remove-Item -LiteralPath $Sig -Force }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $SignScript -File $Tb -Namespace "nfl/ingest-receipt" -TimeoutSeconds 20 | Out-Host
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $VerScript  -File $Tb -Sig $Sig -Namespace "nfl/ingest-receipt" -TimeoutSeconds 20 | Out-Host

"OK: pubkey synced from private key + trust/allowed_signers rebuilt + signature verified" | Out-Host
