param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }

function Write-Utf8NoBom([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function Invoke-SshKeygenResult([string[]]$Argv,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { Die "TimeoutSeconds must be >= 1" }
  $ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source

  $quoted = New-Object System.Collections.Generic.List[string]
  foreach ($a in @(@($Argv))) {
    $x = $a
    if ($null -eq $x) { $x = "" }
    if ($x -match '[\s"]') { [void]$quoted.Add('"' + ($x -replace '"','\"') + '"') } else { [void]$quoted.Add($x) }
  }
  $argStr = ($quoted.ToArray() -join " ")

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

  $outHandler = [System.Diagnostics.DataReceivedEventHandler]{ param($s,$e) if ($e.Data -ne $null) { [void]$sbOut.AppendLine($e.Data) } }
  $errHandler = [System.Diagnostics.DataReceivedEventHandler]{ param($s,$e) if ($e.Data -ne $null) { [void]$sbErr.AppendLine($e.Data) } }

  $p.add_OutputDataReceived($outHandler)
  $p.add_ErrorDataReceived($errHandler)

  if (-not $p.Start()) { Die "Failed to start ssh-keygen" }
  $p.BeginOutputReadLine()
  $p.BeginErrorReadLine()

  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) {
    try { $p.Kill() | Out-Null } catch { }
    Die ("ssh-keygen timeout after " + $TimeoutSeconds + "s: " + $argStr)
  }
  try { $p.WaitForExit() } catch { }

  $stdout = ($sbOut.ToString() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()
  $stderr = ($sbErr.ToString() -replace "`r`n","`n" -replace "`r","`n").TrimEnd()

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

$Priv = Join-Path $KeysDir "nfl-local_ed25519"
$Pub  = $Priv + ".pub"
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

# Backup existing key material (if present)
foreach($p in @($Priv,$Pub)){
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    $bak = $p + ".bak_" + $stamp
    Copy-Item -LiteralPath $p -Destination $bak -Force | Out-Null
    Write-Output ("BACKUP_KEY: " + $bak)
  }
}

# Generate new UNENCRYPTED key (no prompts; deterministic)
# -N "" => empty passphrase
# -C is comment only; safe
Write-Output "RUN: ssh-keygen -t ed25519 -N '' -f proofs\keys\nfl-local_ed25519"
$resGen = Invoke-SshKeygenResult -Argv @("-t","ed25519","-N","","-f",$Priv,"-C","nfl-local") -TimeoutSeconds 60
if ($resGen.ExitCode -ne 0) {
  Die ("KEYGEN_FAIL: " + $resGen.Args + "`nSTDERR:`n" + $resGen.Stderr + "`nSTDOUT:`n" + $resGen.Stdout)
}

if (-not (Test-Path -LiteralPath $Priv -PathType Leaf)) { Die ("KEYGEN_MISSING_PRIV: " + $Priv) }
if (-not (Test-Path -LiteralPath $Pub  -PathType Leaf)) { Die ("KEYGEN_MISSING_PUB: " + $Pub) }

# Prove non-interactive access (this is where you were hanging)
Write-Output "RUN: ssh-keygen -y -f <priv> (prove non-interactive)"
$resY = Invoke-SshKeygenResult -Argv @("-y","-f",$Priv) -TimeoutSeconds 10
if ($resY.ExitCode -ne 0) {
  Die ("DERIVE_PUB_FAIL: " + $resY.Args + "`nSTDERR:`n" + $resY.Stderr + "`nSTDOUT:`n" + $resY.Stdout)
}
$derived = $resY.Stdout.Trim()
if ([string]::IsNullOrWhiteSpace($derived)) { Die "DERIVE_PUB_EMPTY" }

Write-Output ("DERIVED_PUB: " + $derived)
Write-Output ("PUBFILE: " + ((Get-Content -Raw -LiteralPath $Pub -Encoding UTF8).Trim()))
Write-Output "OK: rotated NFL signing key to unencrypted repo-managed key (next: update allowed_signers/trust_bundle + resign)"
