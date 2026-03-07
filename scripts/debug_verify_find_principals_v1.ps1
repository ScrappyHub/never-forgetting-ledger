param(
  [Parameter(Mandatory=$true)][string]$File,
  [Parameter(Mandatory=$true)][string]$Sig,
  [Parameter(Mandatory=$true)][string]$Namespace,
  [Parameter()][int]$TimeoutSeconds = 60
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "_lib_neverlost_v1.ps1")
function Invoke-SshKeygen([string[]]$Argv,[int]$TimeoutSeconds){
  if ($TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }
  $ssh = (Get-Command ssh-keygen.exe -ErrorAction Stop).Source

  $quoted = New-Object System.Collections.Generic.List[string]
  foreach ($a in @(@($Argv))) {
    if ($null -eq $a) { $a = "" }
    if ($a -match '[\s"]') { [void]$quoted.Add('"' + ($a -replace '"','\"') + '"') } else { [void]$quoted.Add($a) }
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

  $outHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $e)
    if ($e.Data -ne $null) { [void]$sbOut.AppendLine($e.Data) }
  }
  $errHandler = [System.Diagnostics.DataReceivedEventHandler]{
    param($sender, $e)
    if ($e.Data -ne $null) { [void]$sbErr.AppendLine($e.Data) }
  }

  $p.add_OutputDataReceived($outHandler)
  $p.add_ErrorDataReceived($errHandler)

  if (-not $p.Start()) { throw "Failed to start ssh-keygen" }
  $p.BeginOutputReadLine()
  $p.BeginErrorReadLine()

  $ok = $p.WaitForExit($TimeoutSeconds * 1000)
  if (-not $ok) {
    try { $p.Kill() | Out-Null } catch { }
    throw ("ssh-keygen timeout after " + $TimeoutSeconds + "s: " + $argStr)
  }

  try { $p.WaitForExit() } catch { }

  $stdout = ($sbOut.ToString() -replace "
","
" -replace "","
").TrimEnd()
  $stderr = ($sbErr.ToString() -replace "
","
" -replace "","
").TrimEnd()

  if ($p.ExitCode -ne 0) {
    throw ("ssh-keygen failed (exit " + $p.ExitCode + "): " + $argStr + "
STDERR:
" + $stderr + "
STDOUT:
" + $stdout)
  }

  return $stdout
}

$Root = Get-RepoRoot
$Allowed = Join-Path $Root "proofs\trust\allowed_signers"

if (-not (Test-Path -LiteralPath $Allowed -PathType Leaf)) { throw ("Missing allowed_signers: " + $Allowed) }
if (-not (Test-Path -LiteralPath $File    -PathType Leaf)) { throw ("Missing file: " + $File) }
if (-not (Test-Path -LiteralPath $Sig     -PathType Leaf)) { throw ("Missing sig: " + $Sig) }
if ([string]::IsNullOrWhiteSpace($Namespace)) { throw "Namespace empty" }

Write-Output ("DEBUG: ssh-keygen=" + (Get-Command ssh-keygen.exe -ErrorAction Stop).Source)
Write-Output ("DEBUG: file sha256=" + (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant())
Write-Output ("DEBUG: sig  sha256=" + (Get-FileHash -LiteralPath $Sig  -Algorithm SHA256).Hash.ToLowerInvariant())

Write-Output "RUN: ssh-keygen -Y find-principals"
$out = Invoke-SshKeygen -Argv @("-Y","find-principals","-f",$Allowed,"-n",$Namespace,"-s",$Sig,$File) -TimeoutSeconds $TimeoutSeconds
if ([string]::IsNullOrWhiteSpace($out)) { throw "No principal matched." }

Write-Output "OK: find-principals output:"
Write-Output $out
