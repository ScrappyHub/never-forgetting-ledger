param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Write-Utf8NoBom([string]$Path,[string]$Text) {
  $enc = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

$Root = $RepoRoot
if (-not (Test-Path -LiteralPath $Root)) { throw ("Missing repo root: " + $Root) }

$Scripts = Join-Path $Root "scripts"
$Lib     = Join-Path $Scripts "_lib_neverlost_v1.ps1"
$Ver     = Join-Path $Scripts "verify_sig_v1.ps1"
$Dbg     = Join-Path $Scripts "debug_verify_find_principals_v1.ps1"

foreach ($p in @($Scripts,$Lib)) { if (-not (Test-Path -LiteralPath $p)) { throw ("Missing: " + $p) } }

$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

# ---- verify_sig_v1.ps1 ----
$verText = @'
param(
  [Parameter(Mandatory=$true)][string]$File,
  [Parameter(Mandatory=$true)][string]$Sig,
  [Parameter(Mandatory=$true)][string]$Namespace,
  [Parameter()][int]$TimeoutSeconds = 30,
  [Parameter()][switch]$DebugFindPrincipals
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot "_lib_neverlost_v1.ps1")

$Root = Get-RepoRoot
$Allowed   = Join-Path $Root "proofs\trust\allowed_signers"
$Principal = "single-tenant/local/authority/nfl"

if (-not (Test-Path -LiteralPath $Allowed)) { throw ("Missing allowed_signers: " + $Allowed) }
if (-not (Test-Path -LiteralPath $File))    { throw ("Missing file: " + $File) }
if (-not (Test-Path -LiteralPath $Sig))     { throw ("Missing sig: " + $Sig) }
if ([string]::IsNullOrWhiteSpace($Namespace)) { throw "Namespace empty" }
if ($TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }

if ($DebugFindPrincipals) {
  Write-Host "DEBUG: ssh-keygen -Y find-principals"
  $out = Invoke-OpenSshKeygen -Argv @("-Y","find-principals","-f",$Allowed,"-n",$Namespace,"-s",$Sig,$File) -TimeoutSeconds $TimeoutSeconds
  if (-not [string]::IsNullOrWhiteSpace($out)) { $out | Out-Host }
}

Invoke-OpenSshKeygen -Argv @("-Y","verify","-f",$Allowed,"-I",$Principal,"-n",$Namespace,"-s",$Sig,"-r","NUL",$File) -TimeoutSeconds $TimeoutSeconds | Out-Null

"OK: verified"
