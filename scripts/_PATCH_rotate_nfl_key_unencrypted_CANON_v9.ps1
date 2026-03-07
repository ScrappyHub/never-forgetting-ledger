param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
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
  $psi.Arguments = "/c " + $CmdLine
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput  = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi

  if (-not $p.Start()) { Die "Failed to start cmd.exe" }

  # Close stdin; cmd handles <NUL in the command itself
  try { $p.StandardInput.Close() } catch { }

  # SYNC read to end (no async events / no races)
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

# cmd escaping:
# - wrap exe + paths in ""
# - represent empty passphrase as -N "" by writing -N """" inside cmd
$cmdKeygen = '""' + $ssh + '"" -q -t ed25519 -N """" -f ""' + $Priv + '"" -C ""nfl-local"" <NUL'
Write-Output ("RUN: " + $cmdKeygen)

$r = Invoke-CmdSync -CmdLine $cmdKeygen -TimeoutSeconds 30
Write-Output ("KEYGEN_EXIT: " + $r.ExitCode)
if (-not [string]::IsNullOrWhiteSpace($r.Stderr)) {
  Write-Output "KEYGEN_STDERR:"
  Write-Output $r.Stderr
}
if (-not [string]::IsNullOrWhiteSpace($r.Stdout)) {
  Write-Output "KEYGEN_STDOUT:"
  Write-Output $r.Stdout
}
if ($r.ExitCode -ne 0) {
  Die ("KEYGEN_FAIL (exit " + $r.ExitCode + ")`nCMD: " + $r.Cmd)
}

# Artifact proof
Write-Output ("PRIV_EXISTS: " + (Test-Path -LiteralPath $Priv -PathType Leaf))
Write-Output ("PUB_EXISTS:  " + (Test-Path -LiteralPath $Pub  -PathType Leaf))

if (-not (Test-Path -LiteralPath $Priv -PathType Leaf)) { Die ("KEYGEN_MISSING_PRIV: " + $Priv) }
if (-not (Test-Path -LiteralPath $Pub  -PathType Leaf)) { Die ("KEYGEN_MISSING_PUB: " + $Pub) }

Write-Output ("PRIV_SHA256: " + (Sha256Hex $Priv))
Write-Output ("PUB_SHA256:  " + (Sha256Hex $Pub))

# Derive pub (also non-interactive)
$cmdDerive = '""' + $ssh + '"" -y -f ""' + $Priv + '"" <NUL'
Write-Output ("RUN: " + $cmdDerive)

$ry = Invoke-CmdSync -CmdLine $cmdDerive -TimeoutSeconds 10
Write-Output ("DERIVE_EXIT: " + $ry.ExitCode)
if ($ry.ExitCode -ne 0) {
  Die ("DERIVE_PUB_FAIL (exit " + $ry.ExitCode + ")`nCMD: " + $ry.Cmd + "`nSTDERR:`n" + $ry.Stderr + "`nSTDOUT:`n" + $ry.Stdout)
}
$derived = $ry.Stdout.Trim()
if ([string]::IsNullOrWhiteSpace($derived)) { Die "DERIVE_PUB_EMPTY" }

Write-Output ("DERIVED_PUB: " + $derived)
Write-Output ("PUBFILE: " + ((Get-Content -Raw -LiteralPath $Pub -Encoding UTF8).Trim()))
Write-Output "OK: rotated NFL signing key to UNENCRYPTED repo-managed key"
