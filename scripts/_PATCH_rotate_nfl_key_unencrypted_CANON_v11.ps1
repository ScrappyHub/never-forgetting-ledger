param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter()][string]$TestPrincipal = "single-tenant/local/authority/nfl",
  [Parameter()][string]$TestNamespace = "nfl/ingest-receipt"
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }

function Sha256Hex([string]$Path){
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Die ("Missing for sha256: " + $Path) }
  return ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant())
}

function Invoke-CmdSync([string]$CmdLine,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { Die "TimeoutSeconds must be >= 1" }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = (Get-Command cmd.exe -ErrorAction Stop).Source
  $psi.Arguments = "/d /s /c " + $CmdLine
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  if (-not $p.Start()) { Die "Failed to start cmd.exe" }

  try { $p.StandardInput.Close() } catch { }

  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()

  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) {
    try { $p.Kill() | Out-Null } catch { }
    $so = ($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    $se = ($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    Die ("cmd timeout after " + $TimeoutSeconds + "s`nCMD: " + $CmdLine + "`nSTDERR:`n" + $se + "`nSTDOUT:`n" + $so)
  }

  $so2 = ($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  $se2 = ($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

  return [pscustomobject]@{
    ExitCode = $p.ExitCode
    Stdout   = $so2
    Stderr   = $se2
    Cmd      = $CmdLine
  }
}

function Write-Utf8NoBomFile([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $norm = ($Text -replace "`r`n","`n" -replace "`r","`n")
  [System.IO.File]::WriteAllText($Path, $norm, $enc)
}

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$KeysDir = Join-Path $Root "proofs\keys"
if (-not (Test-Path -LiteralPath $KeysDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $KeysDir | Out-Null }

$Priv  = Join-Path $KeysDir "nfl-local_ed25519"
$Pub   = $Priv + ".pub"
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

Write-Output ("REPO: " + $Root)

foreach($p in @($Priv,$Pub)){
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    $bak = $p + ".bak_" + $stamp
    Copy-Item -LiteralPath $p -Destination $bak -Force | Out-Null
    Write-Output ("BACKUP_KEY: " + $bak)
  }
}
foreach($p in @($Priv,$Pub)){
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    Remove-Item -LiteralPath $p -Force
    Write-Output ("REMOVED: " + $p)
  }
}

$ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source

# Keygen (unencrypted) via cmd, force non-interactive by piping newline
$cmdKeygen = 'echo.| ""' + $ssh + '"" -q -t ed25519 -N """" -f ""' + $Priv + '"" -C ""nfl-local""'
Write-Output ("RUN: " + $cmdKeygen)

$r = Invoke-CmdSync -CmdLine $cmdKeygen -TimeoutSeconds 30
Write-Output ("KEYGEN_EXIT: " + $r.ExitCode)
if ($r.ExitCode -ne 0) { Die ("KEYGEN_FAIL (exit " + $r.ExitCode + ")`nCMD: " + $r.Cmd + "`nSTDERR:`n" + $r.Stderr + "`nSTDOUT:`n" + $r.Stdout) }

if (-not (Test-Path -LiteralPath $Priv -PathType Leaf)) { Die ("KEYGEN_MISSING_PRIV: " + $Priv) }
if (-not (Test-Path -LiteralPath $Pub  -PathType Leaf)) { Die ("KEYGEN_MISSING_PUB: " + $Pub) }

Write-Output ("PRIV_SHA256: " + (Sha256Hex $Priv))
Write-Output ("PUB_SHA256:  " + (Sha256Hex $Pub))

$pubLine = (Get-Content -Raw -LiteralPath $Pub -Encoding UTF8).Trim()
if ([string]::IsNullOrWhiteSpace($pubLine)) { Die "PUBFILE_EMPTY" }
Write-Output ("PUBFILE_LINE: " + $pubLine)

# ---- self-test: sign + verify (NO ssh-keygen -y) ----
$tmpDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("nfl_keytest_" + [Guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

$payload = Join-Path $tmpDir "payload.txt"
$sig     = Join-Path $tmpDir "payload.txt.sig"
$allowed = Join-Path $tmpDir "allowed_signers"
$rev     = Join-Path $tmpDir "revoked_keys"

try {
  Write-Utf8NoBomFile -Path $payload -Text ("nfl key rotation self-test`n" + (Get-Date).ToUniversalTime().ToString("o"))
  Write-Utf8NoBomFile -Path $rev -Text ""

  # allowed_signers line format:
  # <principal> <keytype> <base64> [comment]
  # We reuse the pub line and prepend principal.
  Write-Utf8NoBomFile -Path $allowed -Text ($TestPrincipal + " " + $pubLine + "`n")

  # Sign (echo.| forces non-interactive; -f is keyfile; -I principal; -n namespace)
  $cmdSign = 'echo.| ""' + $ssh + '"" -Y sign -f ""' + $Priv + '"" -I ""' + $TestPrincipal + '"" -n ""' + $TestNamespace + '"" ""' + $payload + '""'
  Write-Output ("RUN: " + $cmdSign)
  $rs = Invoke-CmdSync -CmdLine $cmdSign -TimeoutSeconds 20
  Write-Output ("SIGN_EXIT: " + $rs.ExitCode)
  if ($rs.ExitCode -ne 0) { Die ("SIGN_FAIL`nCMD: " + $rs.Cmd + "`nSTDERR:`n" + $rs.Stderr + "`nSTDOUT:`n" + $rs.Stdout) }

  # ssh-keygen writes <file>.sig by default, so ensure it exists (or copy to our expected sig path)
  $defaultSig = $payload + ".sig"
  if (Test-Path -LiteralPath $defaultSig -PathType Leaf) {
    Copy-Item -LiteralPath $defaultSig -Destination $sig -Force | Out-Null
  }
  if (-not (Test-Path -LiteralPath $sig -PathType Leaf)) { Die ("SIG_MISSING: " + $sig) }

  Write-Output ("PAYLOAD_SHA256: " + (Sha256Hex $payload))
  Write-Output ("SIG_SHA256:     " + (Sha256Hex $sig))
  Write-Output ("ALLOWED_SHA256: " + (Sha256Hex $allowed))

  # Verify
  $cmdVerify = 'echo.| ""' + $ssh + '"" -Y verify -f ""' + $allowed + '"" -I ""' + $TestPrincipal + '"" -n ""' + $TestNamespace + '"" -s ""' + $sig + '"" -r ""' + $rev + '"" ""' + $payload + '""'
  Write-Output ("RUN: " + $cmdVerify)
  $rv = Invoke-CmdSync -CmdLine $cmdVerify -TimeoutSeconds 20
  Write-Output ("VERIFY_EXIT: " + $rv.ExitCode)
  if ($rv.ExitCode -ne 0) { Die ("VERIFY_FAIL`nCMD: " + $rv.Cmd + "`nSTDERR:`n" + $rv.Stderr + "`nSTDOUT:`n" + $rv.Stdout) }

  Write-Output "PASS: key rotated + sign/verify succeeded (no ssh-keygen -y used)"
}
finally {
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
