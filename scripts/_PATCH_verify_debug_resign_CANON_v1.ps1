param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source

function Write-Utf8NoBom([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function ParseGateFile([string]$Path){
  $tk=$null; $er=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tk,[ref]$er)
  $errs = @(@($er))
  if ($errs.Count -gt 0) { throw ("PARSE ERROR: " + $errs[0].Message + " (file: " + $Path + ")") }
}

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$Scripts = Join-Path $Root "scripts"

$Lib  = Join-Path $Scripts "_lib_neverlost_v1.ps1"
$Sign = Join-Path $Scripts "sign_file_v1.ps1"
$Ver  = Join-Path $Scripts "verify_sig_v1.ps1"
$Dbg  = Join-Path $Scripts "debug_verify_find_principals_v1.ps1"

foreach($p in @($Lib,$Sign)){
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw ("Missing required script: " + $p) }
}

$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

# ----------------------------
# 1) Rewrite verify_sig_v1.ps1
# ----------------------------
if (Test-Path -LiteralPath $Ver -PathType Leaf) {
  $bak = $Ver + ".bak_" + $stamp
  Copy-Item -LiteralPath $Ver -Destination $bak -Force | Out-Null
  ("BACKUP_VERIFY: " + $bak) | Out-Host
}

$verifyBody = @"
param(
  [Parameter(Mandatory=`$true)][string]`$File,
  [Parameter(Mandatory=`$true)][string]`$Sig,
  [Parameter(Mandatory=`$true)][string]`$Namespace,
  [Parameter()][int]`$TimeoutSeconds = 30,
  [Parameter()][switch]`$DebugFindPrincipals
)

`$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

. (Join-Path `$PSScriptRoot "_lib_neverlost_v1.ps1")

`$Root = Get-RepoRoot
`$Allowed   = Join-Path `$Root "proofs\trust\allowed_signers"
`$Principal = "single-tenant/local/authority/nfl"

if (-not (Test-Path -LiteralPath `$Allowed -PathType Leaf)) { throw ("Missing allowed_signers: " + `$Allowed) }
if (-not (Test-Path -LiteralPath `$File    -PathType Leaf)) { throw ("Missing file: " + `$File) }
if (-not (Test-Path -LiteralPath `$Sig     -PathType Leaf)) { throw ("Missing sig: " + `$Sig) }
if ([string]::IsNullOrWhiteSpace(`$Namespace)) { throw "Namespace empty" }
if (`$TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }

if (`$DebugFindPrincipals) {
  Write-Host "DEBUG: ssh-keygen -Y find-principals"
  `$out = Invoke-OpenSshKeygen -Argv @("-Y","find-principals","-f",`$Allowed,"-n",`$Namespace,"-s",`$Sig,`$File) -TimeoutSeconds `$TimeoutSeconds
  if (-not [string]::IsNullOrWhiteSpace(`$out)) { `$out | Out-Host }
}

# Real empty revocation file (no NUL device)
`$rev = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ("neverlost_rev_" + [Guid]::NewGuid().ToString("N") + ".txt"))
try {
  [System.IO.File]::WriteAllText(`$rev, "", (New-Object System.Text.UTF8Encoding(`$false)))
  Invoke-OpenSshKeygen -Argv @("-Y","verify","-f",`$Allowed,"-I",`$Principal,"-n",`$Namespace,"-s",`$Sig,"-r",`$rev,`$File) -TimeoutSeconds `$TimeoutSeconds | Out-Null
  "OK: verified" | Out-Host
} finally {
  Remove-Item -LiteralPath `$rev -Force -ErrorAction SilentlyContinue
}
"@

Write-Utf8NoBom -Path $Ver -Text (($verifyBody.TrimEnd()) + "`r`n")
ParseGateFile $Ver
("WROTE: " + $Ver) | Out-Host

# ----------------------------
# 2) Rewrite debug_verify_find_principals_v1.ps1
# ----------------------------
if (Test-Path -LiteralPath $Dbg -PathType Leaf) {
  $bak2 = $Dbg + ".bak_" + $stamp
  Copy-Item -LiteralPath $Dbg -Destination $bak2 -Force | Out-Null
  ("BACKUP_DEBUG: " + $bak2) | Out-Host
}

$dbgBody = @"
param(
  [Parameter(Mandatory=`$true)][string]`$File,
  [Parameter(Mandatory=`$true)][string]`$Sig,
  [Parameter(Mandatory=`$true)][string]`$Namespace,
  [Parameter()][int]`$TimeoutSeconds = 30
)

`$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

. (Join-Path `$PSScriptRoot "_lib_neverlost_v1.ps1")

`$Root = Get-RepoRoot
`$Allowed = Join-Path `$Root "proofs\trust\allowed_signers"

if (-not (Test-Path -LiteralPath `$Allowed -PathType Leaf)) { throw ("Missing allowed_signers: " + `$Allowed) }
if (-not (Test-Path -LiteralPath `$File    -PathType Leaf)) { throw ("Missing file: " + `$File) }
if (-not (Test-Path -LiteralPath `$Sig     -PathType Leaf)) { throw ("Missing sig: " + `$Sig) }
if ([string]::IsNullOrWhiteSpace(`$Namespace)) { throw "Namespace empty" }
if (`$TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }

Write-Host "RUN: ssh-keygen -Y find-principals"
`$out = Invoke-OpenSshKeygen -Argv @("-Y","find-principals","-f",`$Allowed,"-n",`$Namespace,"-s",`$Sig,`$File) -TimeoutSeconds `$TimeoutSeconds
if ([string]::IsNullOrWhiteSpace(`$out)) { throw "No principal matched." }
`$out | Out-Host
"OK: find-principals produced principal(s)" | Out-Host
"@

Write-Utf8NoBom -Path $Dbg -Text (($dbgBody.TrimEnd()) + "`r`n")
ParseGateFile $Dbg
("WROTE: " + $Dbg) | Out-Host

# ----------------------------
# 3) Re-sign + verify (deterministic)
# ----------------------------
$Tb  = Join-Path $Root "proofs\trust\trust_bundle.json"
$Sig = $Tb + ".sig"

if (-not (Test-Path -LiteralPath $Tb -PathType Leaf)) { throw ("Missing: " + $Tb) }
if (Test-Path -LiteralPath $Sig -PathType Leaf) { Remove-Item -LiteralPath $Sig -Force }

& $PSExe -NoProfile -ExecutionPolicy Bypass -File $Sign -File $Tb -Namespace "nfl/ingest-receipt" -TimeoutSeconds 20 | Out-Host
& $PSExe -NoProfile -ExecutionPolicy Bypass -File $Dbg  -File $Tb -Sig $Sig -Namespace "nfl/ingest-receipt" -TimeoutSeconds 20 | Out-Host
& $PSExe -NoProfile -ExecutionPolicy Bypass -File $Ver  -File $Tb -Sig $Sig -Namespace "nfl/ingest-receipt" -TimeoutSeconds 20 -DebugFindPrincipals | Out-Host

"OK: patch + resign + verify complete" | Out-Host
