param(
  [Parameter(Mandatory=$true)][string]$File,
  [Parameter(Mandatory=$true)][string]$Sig,
  [Parameter(Mandatory=$true)][string]$Namespace,
  [Parameter()][int]$TimeoutSeconds = 30
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "_lib_neverlost_v1.ps1")

$Root = Get-RepoRoot
$Allowed = Join-Path $Root "proofs\trust\allowed_signers"

if (-not (Test-Path -LiteralPath $Allowed)) { throw ("Missing allowed_signers: " + $Allowed) }
if (-not (Test-Path -LiteralPath $File))    { throw ("Missing file: " + $File) }
if (-not (Test-Path -LiteralPath $Sig))     { throw ("Missing sig: " + $Sig) }
if ([string]::IsNullOrWhiteSpace($Namespace)) { throw "Namespace empty" }

Write-Host "RUN: ssh-keygen -Y find-principals"
$out = Invoke-OpenSshKeygen -Argv @("-Y","find-principals","-f",$Allowed,"-n",$Namespace,"-s",$Sig,$File) -TimeoutSeconds $TimeoutSeconds
if ([string]::IsNullOrWhiteSpace($out)) {
  throw "find-principals returned empty output (signature likely does NOT match file+namespace)."
}
$out | Out-Host
"OK: find-principals produced principal(s)" | Out-Host
