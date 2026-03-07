param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

function Quote-Arg([string]$x){
  # Quote for ProcessStartInfo.Arguments (single string). Preserve empty arg as "".
  if ($null -eq $x) { return '""' }
  if ($x -eq "")    { return '""' }
  if ($x -match '[\s"]') { return '"' + ($x -replace '"','\"') + '"' }
  return $x
}

function Invoke-SshKeygenPSI([string[]]$Argv,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { Die "TimeoutSeconds must be >= 1" }
  $ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source

  $parts = New-Object System.Collections.Generic.List[string]
  foreach($a in @(@($Argv))){
    [void]$parts.Add((Quote-Arg $a))
  }
  $argStr = ($parts.ToArray() -join " ")

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $ssh
  $psi.Arguments = $argStr
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.RedirectStandardInput  = $true   # critical: no interactive hangs
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi

  if (-not $p.Start()) { Die "Failed to start ssh-keygen" }

  # Ensure ssh-keygen can't wait for input (overwrite/passphrase prompts, etc.)
  try { $p.StandardInput.Close() } catch { }

  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) {
    try { $p.Kill() | Out-Null } catch { }
    Die ("ssh-keygen timeout after " + $TimeoutSeconds + "s`nARGS: " + $argStr)
  }

  # Small output; safe to read after exit for ssh-keygen
  $stdout = ""
  $stderr = ""
  try { $stdout = $p.StandardOutput.ReadToEnd() } catch { $stdout = "" }
  try { $stderr = $p.StandardError.ReadToEnd()  } catch { $stderr = "" }

  $stdout = ($stdout -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  $stderr = ($stderr -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

  if ($p.ExitCode -ne 0) {
    Die ("ssh-keygen failed (exit " + $p.ExitCode + ")`nARGS: " + $argStr + "`nSTDERR:`n" + $stderr + "`nSTDOUT:`n" + $stdout)
  }

  return [pscustomobject]@{
    Exe      = $ssh
    Args     = $argStr
    ExitCode = $p.ExitCode
    Stdout   = $stdout
    Stderr   = $stderr
  }
}

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$KeysDir = Join-Path $Root "proofs\keys"
if (-not (Test-Path -LiteralPath $KeysDir -PathType Container)) { New-Item -ItemType Directory -Force -Path $KeysDir | Out-Null }

$Priv  = Join-Path $KeysDir "nfl-local_ed25519"
$Pub   = $Priv + ".pub"
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

Write-Output ("REPO: " + $Root)

# Backup existing key material (if present)
foreach($p in @($Priv,$Pub)){
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    $bak = $p + ".bak_" + $stamp
    Copy-Item -LiteralPath $p -Destination $bak -Force | Out-Null
    Write-Output ("BACKUP_KEY: " + $bak)
  }
}

# Hard delete to avoid overwrite prompt
foreach($p in @($Priv,$Pub)){
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    Remove-Item -LiteralPath $p -Force
    Write-Output ("REMOVED: " + $p)
  }
}

# Generate new UNENCRYPTED key (passphrase empty)
Write-Output ("RUN: ssh-keygen -t ed25519 -N """" -f " + $Priv)
$resG = Invoke-SshKeygenPSI -Argv @("-t","ed25519","-N","", "-f",$Priv,"-C","nfl-local") -TimeoutSeconds 60
if ($resG.Stdout) { Write-Output ("KEYGEN_STDOUT:`n" + $resG.Stdout) }
if ($resG.Stderr) { Write-Output ("KEYGEN_STDERR:`n" + $resG.Stderr) }

if (-not (Test-Path -LiteralPath $Priv -PathType Leaf)) { Die ("KEYGEN_MISSING_PRIV: " + $Priv) }
if (-not (Test-Path -LiteralPath $Pub  -PathType Leaf)) { Die ("KEYGEN_MISSING_PUB: " + $Pub) }

# Prove non-interactive access (must NOT hang)
Write-Output "RUN: ssh-keygen -y -f <priv> (prove non-interactive)"
$resY = Invoke-SshKeygenPSI -Argv @("-y","-f",$Priv) -TimeoutSeconds 10
$derived = $resY.Stdout.Trim()
if ([string]::IsNullOrWhiteSpace($derived)) { Die "DERIVE_PUB_EMPTY" }

$pubFile = (Get-Content -Raw -LiteralPath $Pub -Encoding UTF8).Trim()

Write-Output ("DERIVED_PUB: " + $derived)
Write-Output ("PUBFILE: " + $pubFile)

if ($derived -ne $pubFile) { Die "PUB_MISMATCH: derived != pubfile" }

Write-Output "OK: rotated NFL signing key to UNENCRYPTED repo-managed key (CANON v7)"
