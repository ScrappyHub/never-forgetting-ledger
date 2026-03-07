param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }

function ReadTextUtf8([string]$Path){
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return "" }
  return (Get-Content -Raw -LiteralPath $Path -Encoding UTF8)
}

function Quote-Arg([string]$x){
  # Quote for a single ProcessStartInfo.Arguments string
  if ($null -eq $x) { return '""' }
  if ($x -eq "")    { return '""' }
  if ($x -match '[\s"]') { return '"' + ($x -replace '"','\"') + '"' }
  return $x
}

function Invoke-SshKeygenPSI([string[]]$Argv,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { Die "TimeoutSeconds must be >= 1" }
  $ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source

  # Build a single argument string (PSI.Arguments), preserving empty args as ""
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

  if (-not $p.Start()) { Die "Failed to start ssh-keygen" }
  $p.BeginOutputReadLine()
  $p.BeginErrorReadLine()

  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) {
    try { $p.Kill() | Out-Null } catch { }
    Die ("ssh-keygen timeout after " + $TimeoutSeconds + "s`nARGS: " + $argStr)
  }

  try { $p.WaitForExit() } catch { }

  $stdout = ($sbOut.ToString() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  $stderr = ($sbErr.ToString() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

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
# We can safely express -N "" here because PSI.Arguments is a single string.
Write-Output 'RUN: ssh-keygen -t ed25519 -N "" -f proofs\keys\nfl-local_ed25519'
[void](Invoke-SshKeygenPSI -Argv @("-t","ed25519","-N","", "-f",$Priv,"-C","nfl-local") -TimeoutSeconds 60)

if (-not (Test-Path -LiteralPath $Priv -PathType Leaf)) { Die ("KEYGEN_MISSING_PRIV: " + $Priv) }
if (-not (Test-Path -LiteralPath $Pub  -PathType Leaf)) { Die ("KEYGEN_MISSING_PUB: " + $Pub) }

# Prove non-interactive access (must NOT hang)
Write-Output "RUN: ssh-keygen -y -f <priv> (prove non-interactive)"
$resY = Invoke-SshKeygenPSI -Argv @("-y","-f",$Priv) -TimeoutSeconds 10
$derived = $resY.Stdout.Trim()
if ([string]::IsNullOrWhiteSpace($derived)) { Die "DERIVE_PUB_EMPTY" }

Write-Output ("DERIVED_PUB: " + $derived)
Write-Output ("PUBFILE: " + ((Get-Content -Raw -LiteralPath $Pub -Encoding UTF8).Trim()))
Write-Output "OK: rotated NFL signing key to UNENCRYPTED repo-managed key"
