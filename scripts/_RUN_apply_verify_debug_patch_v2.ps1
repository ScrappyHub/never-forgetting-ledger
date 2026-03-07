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

# ----------------------------
# scripts/verify_sig_v1.ps1
# ----------------------------
$verLines = @()
$verLines += 'param('
$verLines += 'Invoke-OpenSshKeygen -Argv @("-Y","verify","-f",$Allowed,"-I",$Principal,"-n",$Namespace,"-s",$Sig,"-r","NUL",$File) -TimeoutSeconds $TimeoutSeconds | Out-Null'
$verLines += ''
$verLines += '"OK: verified"'

if (Test-Path -LiteralPath $Ver) {
  Copy-Item -LiteralPath $Ver -Destination ($Ver + ".bak_" + $stamp) -Force | Out-Null
  ("BACKUP_VERIFY: " + $Ver + ".bak_" + $stamp) | Out-Host
}
$verText = ($verLines -join "`r`n") + "`r`n"
Write-Utf8NoBom -Path $Ver -Text $verText
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $Ver)) | Out-Null
("WROTE: " + $Ver) | Out-Host

# ----------------------------
# scripts/debug_verify_find_principals_v1.ps1
# ----------------------------
$dbgLines = @()
$dbgLines += 'param('
$dbgLines += ')'
$dbgLines += ''
$dbgLines += '$ErrorActionPreference="Stop"'
$dbgLines += 'Set-StrictMode -Version Latest'
$dbgLines += ''
$dbgLines += '. (Join-Path $PSScriptRoot "_lib_neverlost_v1.ps1")'
$dbgLines += ''
$dbgLines += '$Root = Get-RepoRoot'
$dbgLines += '$Allowed = Join-Path $Root "proofs\trust\allowed_signers"'
$dbgLines += ''
$dbgLines += 'if (-not (Test-Path -LiteralPath $Allowed)) { throw ("Missing allowed_signers: " + $Allowed) }'
$dbgLines += 'if (-not (Test-Path -LiteralPath $File))    { throw ("Missing file: " + $File) }'
$dbgLines += 'if (-not (Test-Path -LiteralPath $Sig))     { throw ("Missing sig: " + $Sig) }'
$dbgLines += 'if ([string]::IsNullOrWhiteSpace($Namespace)) { throw "Namespace empty" }'
$dbgLines += 'if ($TimeoutSeconds -lt 1) { throw "TimeoutSeconds must be >= 1" }'
$dbgLines += ''
$dbgLines += 'Write-Host "RUN: ssh-keygen -Y find-principals"'
$dbgLines += '$out = Invoke-OpenSshKeygen -Argv @("-Y","find-principals","-f",$Allowed,"-n",$Namespace,"-s",$Sig,$File) -TimeoutSeconds $TimeoutSeconds'
$dbgLines += ''
$dbgLines += 'if ([string]::IsNullOrWhiteSpace($out)) {'
$dbgLines += '  throw "find-principals returned empty output (signature likely does NOT match file+namespace)."'
$dbgLines += '}'
$dbgLines += ''
$dbgLines += '$out | Out-Host'
$dbgLines += '"OK: find-principals produced principal(s)" | Out-Host'

if (Test-Path -LiteralPath $Dbg) {
  Copy-Item -LiteralPath $Dbg -Destination ($Dbg + ".bak_" + $stamp) -Force | Out-Null
  ("BACKUP_DEBUG: " + $Dbg + ".bak_" + $stamp) | Out-Host
}
$dbgText = ($dbgLines -join "`r`n") + "`r`n"
Write-Utf8NoBom -Path $Dbg -Text $dbgText
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $Dbg)) | Out-Null
("WROTE: " + $Dbg) | Out-Host

"OK: runner patch applied" | Out-Host
