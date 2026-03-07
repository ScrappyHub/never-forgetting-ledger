param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }

function Invoke-CmdCapture([string]$CmdLine,[int]$TimeoutSeconds){
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

  $sbOut = New-Object System.Text.StringBuilder
  $sbErr = New-Object System.Text.StringBuilder

  $outHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender,$e)
    if ($e.Data -ne $null) { [void]$sbOut.AppendLine($e.Data) }
  }
  $errHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender,$e)
    if ($e.Data -ne $null) { [void]$sbErr.AppendLine($e.Data) }
  }

  $p.add_OutputDataReceived($outHandler)
  $p.add_ErrorDataReceived($errHandler)

  if (-not $p.Start()) { Die "Failed to start cmd.exe" }

  # Close stdin; cmd will handle <NUL in the command itself
  try { $p.StandardInput.Close() } catch { }

  $p.BeginOutputReadLine()
  $p.BeginErrorReadLine()

  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) {
    try { $p.Kill() | Out-Null } catch { }
    $stdout = ($sbOut.ToString() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    $stderr = ($sbErr.ToString() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
    Die ("cmd timeout after " + $TimeoutSeconds + "s`nCMD: " + $CmdLine + "`nSTDERR:`n" + $stderr + "`nSTDOUT:`n" + $stdout)
  }

  try { $p.WaitForExit() } catch { }

  $stdout = ($sbOut.ToString() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  $stderr = ($sbErr.ToString() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

  return [pscustomobject]@{
    ExitCode = $p.ExitCode
    Stdout   = $stdout
    Stderr   = $stderr
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

# KEYGEN via cmd + <NUL to guarantee non-interactive
# -N "" is passed as -N "" in cmd by using """" (cmd escaping)
$cmdKeygen = '""' + $ssh + '"" -q -t ed25519 -N """" -f ""' + $Priv + '"" -C ""nfl-local"" <NUL'
Write-Output ("RUN: " + $cmdKeygen)

$r = Invoke-CmdCapture -CmdLine $cmdKeygen -TimeoutSeconds 30
if ($r.ExitCode -ne 0) {
  Die ("KEYGEN_FAIL (exit " + $r.ExitCode + ")`nCMD: " + $r.Cmd + "`nSTDERR:`n" + $r.Stderr + "`nSTDOUT:`n" + $r.Stdout)
}

if (-not (Test-Path -LiteralPath $Priv -PathType Leaf)) { Die ("KEYGEN_MISSING_PRIV: " + $Priv) }
if (-not (Test-Path -LiteralPath $Pub  -PathType Leaf)) { Die ("KEYGEN_MISSING_PUB: " + $Pub) }

# DERIVE PUB (also via cmd + <NUL to avoid any prompt)
$cmdDerive = '""' + $ssh + '"" -y -f ""' + $Priv + '"" <NUL'
Write-Output ("RUN: " + $cmdDerive)

$ry = Invoke-CmdCapture -CmdLine $cmdDerive -TimeoutSeconds 10
if ($ry.ExitCode -ne 0) {
  Die ("DERIVE_PUB_FAIL (exit " + $ry.ExitCode + ")`nCMD: " + $ry.Cmd + "`nSTDERR:`n" + $ry.Stderr + "`nSTDOUT:`n" + $ry.Stdout)
}

$derived = $ry.Stdout.Trim()
if ([string]::IsNullOrWhiteSpace($derived)) { Die "DERIVE_PUB_EMPTY" }

Write-Output ("DERIVED_PUB: " + $derived)
Write-Output ("PUBFILE: " + ((Get-Content -Raw -LiteralPath $Pub -Encoding UTF8).Trim()))
Write-Output "OK: rotated NFL signing key to UNENCRYPTED repo-managed key"
