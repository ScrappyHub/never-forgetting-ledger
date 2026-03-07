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

function Write-Utf8NoBomFile([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $norm = ($Text -replace "`r`n","`n" -replace "`r","`n")
  [System.IO.File]::WriteAllText($Path, $norm, $enc)
}

function Invoke-CmdSync([string]$CmdLine,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { Die "TimeoutSeconds must be >= 1" }

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName  = (Get-Command cmd.exe -ErrorAction Stop).Source
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

  return [pscustomobject]@{ ExitCode=$p.ExitCode; Stdout=$so2; Stderr=$se2; Cmd=$CmdLine }
}

function WinPath-ToWsl([string]$Path){
  if ([string]::IsNullOrWhiteSpace($Path)) { Die "WinPath-ToWsl: empty path" }
  $p = (Resolve-Path -LiteralPath $Path).Path
  if ($p.Length -lt 3 -or $p[1] -ne ":" -or $p[2] -ne "\") { Die ("WinPath-ToWsl: not a drive path: " + $p) }
  $drive = $p.Substring(0,1).ToLowerInvariant()
  $rest  = $p.Substring(2) -replace "\\","/"
  return ("/mnt/" + $drive + $rest)
}

function Invoke-WslSync([string[]]$Argv,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { Die "TimeoutSeconds must be >= 1" }
  $wsl = (Get-Command wsl.exe -ErrorAction Stop).Source

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $wsl
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  # Build Arguments string for wsl.exe:
  #   wsl.exe -e <cmd> <arg1> <arg2> ...
  # Quote args that contain whitespace/quotes.
  $parts = New-Object System.Collections.Generic.List[string]
  [void]$parts.Add("-e")
  foreach($a in @(@($Argv))){
    if ($null -eq $a) { Die "Invoke-WslSync: null argv element" }
    $s = [string]$a
    if ($s -match '[\s"]') { $s = '"' + ($s -replace '"','\"') + '"' }
    [void]$parts.Add($s)
  }
  $psi.Arguments = ($parts.ToArray() -join " ")

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  if (-not $p.Start()) { Die "Failed to start wsl.exe" }

  # close stdin immediately
  try { $p.StandardInput.Close() } catch { }

  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()

  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) {
    try { $p.Kill() | Out-Null } catch { }
    $so = ($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    $se = ($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    Die ("wsl timeout after " + $TimeoutSeconds + "s`nARGV: " + ($Argv -join " ") + "`nSTDERR:`n" + $se + "`nSTDOUT:`n" + $so)
  }

  $so2 = ($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  $se2 = ($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

  return [pscustomobject]@{ ExitCode=$p.ExitCode; Stdout=$so2; Stderr=$se2; Args=($Argv -join " ") }
}

# ----------------------------
# Rotate key (Windows keygen)
# ----------------------------
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

$sshWin = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source
$cmdKeygen = 'echo.| ""' + $sshWin + '"" -q -t ed25519 -N """" -f ""' + $Priv + '"" -C ""nfl-local""'
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

# ------------------------------------------
# Self-test: WSL ssh-keygen -Y sign/verify
# ------------------------------------------
# If WSL isn't installed/available, fail loudly with a single reason.
try { [void](Get-Command wsl.exe -ErrorAction Stop) } catch { Die "WSL_MISSING: wsl.exe not found (install WSL or we need a different signing backend)" }

$tmpDir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("nfl_keytest_" + [Guid]::NewGuid().ToString("N")))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

$payload = Join-Path $tmpDir "payload.txt"
$sig     = Join-Path $tmpDir "payload.txt.sig"
$allowed = Join-Path $tmpDir "allowed_signers"
$rev     = Join-Path $tmpDir "revoked_keys"

try {
  Write-Utf8NoBomFile -Path $payload -Text ("nfl key rotation self-test`n" + (Get-Date).ToUniversalTime().ToString("o"))
  Write-Utf8NoBomFile -Path $rev -Text ""

  # allowed_signers: <principal> <pubkey...>
  Write-Utf8NoBomFile -Path $allowed -Text ($TestPrincipal + " " + $pubLine + "`n")

  $wslPriv    = WinPath-ToWsl $Priv
  $wslPayload = WinPath-ToWsl $payload
  $wslAllowed = WinPath-ToWsl $allowed
  $wslRev     = WinPath-ToWsl $rev
  $wslSig     = WinPath-ToWsl $sig

  # Sign (WSL): this must not hang; we hard-timeout.
  Write-Output ("RUN: wsl -e ssh-keygen -Y sign -f <priv> -I <principal> -n <ns> <payload>")
  $rs = Invoke-WslSync -Argv @("ssh-keygen","-Y","sign","-f",$wslPriv,"-I",$TestPrincipal,"-n",$TestNamespace,$wslPayload) -TimeoutSeconds 10
  Write-Output ("SIGN_EXIT: " + $rs.ExitCode)
  if ($rs.ExitCode -ne 0) { Die ("SIGN_FAIL`nSTDERR:`n" + $rs.Stderr + "`nSTDOUT:`n" + $rs.Stdout) }

  # ssh-keygen writes payload.sig by default (next to payload). Copy to our stable name.
  $defaultSig = $payload + ".sig"
  if (Test-Path -LiteralPath $defaultSig -PathType Leaf) { Copy-Item -LiteralPath $defaultSig -Destination $sig -Force | Out-Null }
  if (-not (Test-Path -LiteralPath $sig -PathType Leaf)) { Die ("SIG_MISSING: " + $sig) }

  Write-Output ("PAYLOAD_SHA256: " + (Sha256Hex $payload))
  Write-Output ("SIG_SHA256:     " + (Sha256Hex $sig))
  Write-Output ("ALLOWED_SHA256: " + (Sha256Hex $allowed))

  # Verify (WSL)
  Write-Output ("RUN: wsl -e ssh-keygen -Y verify -f <allowed> -I <principal> -n <ns> -s <sig> -r <rev> <payload>")
  $rv = Invoke-WslSync -Argv @("ssh-keygen","-Y","verify","-f",$wslAllowed,"-I",$TestPrincipal,"-n",$TestNamespace,"-s",$wslSig,"-r",$wslRev,$wslPayload) -TimeoutSeconds 10
  Write-Output ("VERIFY_EXIT: " + $rv.ExitCode)
  if ($rv.ExitCode -ne 0) { Die ("VERIFY_FAIL`nSTDERR:`n" + $rv.Stderr + "`nSTDOUT:`n" + $rv.Stdout) }

  Write-Output "PASS: key rotated + WSL -Y sign/verify succeeded"
  Write-Output "NEXT: pin WSL ssh-keygen for all -Y operations in NFL (Windows ssh-keygen -Y is not reliable on this host)."
}
finally {
  Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
