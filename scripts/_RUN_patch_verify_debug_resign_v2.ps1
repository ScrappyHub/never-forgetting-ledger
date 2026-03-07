param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Write-Utf8NoBom([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path

$Ver  = Join-Path $Root "scripts\verify_sig_v1.ps1"
$Lib  = Join-Path $Root "scripts\_lib_neverlost_v1.ps1"
$Sign = Join-Path $Root "scripts\sign_file_v1.ps1"
$Dbg  = Join-Path $Root "scripts\debug_verify_find_principals_v1.ps1"

foreach($p in @($Lib,$Sign)){
  if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ throw ("Missing required script: " + $p) }
}

$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
if (Test-Path -LiteralPath $Ver -PathType Leaf) {
  Copy-Item -LiteralPath $Ver -Destination ($Ver + ".bak_" + $stamp) -Force | Out-Null
  ("BACKUP_VERIFY: " + $Ver + ".bak_" + $stamp) | Out-Host
}

# --- Rewrite verify_sig_v1.ps1 (real empty revocation file, optional DebugFindPrincipals) ---
$verText = @"
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

if (-not (Test-Path -LiteralPath $Allowed -PathType Leaf)) { throw ("Missing allowed_signers: " + $Allowed) }
if (-not (Test-Path -LiteralPath $File -PathType Leaf))    { throw ("Missing file: " + $File) }
if (-not (Test-Path -LiteralPath $Sig  -PathType Leaf))    { throw ("Missing sig: " + $Sig) }
if ([string]::IsNullOrWhiteSpace($Namespace)) { throw "Namespace empty" }
if ($TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }

if ($DebugFindPrincipals) {
  Write-Host "DEBUG: ssh-keygen -Y find-principals"
  $out = Invoke-OpenSshKeygen -Argv @("-Y","find-principals","-f",$Allowed,"-n",$Namespace,"-s",$Sig,$File) -TimeoutSeconds $TimeoutSeconds
  if (-not [string]::IsNullOrWhiteSpace($out)) { $out | Out-Host }
}

# Deterministic revocation file: real empty temp file
$rev = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("neverlost_rev_" + [Guid]::NewGuid().ToString("N") + ".txt"))
try {
  [System.IO.File]::WriteAllText($rev, "", (New-Object System.Text.UTF8Encoding($false)))
  Invoke-OpenSshKeygen -Argv @("-Y","verify","-f",$Allowed,"-I",$Principal,"-n",$Namespace,"-s",$Sig,"-r",$rev,$File) -TimeoutSeconds $TimeoutSeconds | Out-Null
  "OK: verified"
} finally {
  Remove-Item -LiteralPath $rev -Force -ErrorAction SilentlyContinue
}
