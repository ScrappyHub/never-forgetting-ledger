param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"
function Die([string]$m){ throw ("NFL_PATCH_TAX_ASSERTS_FAIL: " + $m) }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function ReadUtf8([string]$p){ [System.IO.File]::ReadAllText($p,(Utf8NoBom)) }
function WriteUtf8NoBomLfText([string]$p,[string]$t){ $dir=Split-Path -Parent $p; if($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)){ New-Item -ItemType Directory -Force -Path $dir | Out-Null }; $u=$t.Replace("`r`n","`n").Replace("`r","`n"); if(-not $u.EndsWith("`n")){ $u += "`n" }; [System.IO.File]::WriteAllBytes($p,(Utf8NoBom).GetBytes($u)); if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Die ("WRITE_FAILED: " + $p) } }
function ParseGateFile([string]$Path){ if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("PARSEGATE_MISSING: " + $Path) }; $tok=$null; $err=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err); if($err -and @(@($err)).Count -gt 0){ $m = ($err | Select-Object -First 10 | ForEach-Object { $_.ToString() }) -join " | "; Die ("PARSEGATE_FAIL: " + $Path + " :: " + $m) } }

$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
$Runner = Join-Path (Join-Path $RepoRoot "scripts") "_selftest_nfl_tier0_v2.ps1"
if(-not (Test-Path -LiteralPath $Runner -PathType Leaf)){ Die ("MISSING_RUNNER: " + $Runner) }
$txt = ReadUtf8 $Runner
$bak = $Runner + ".bak_" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
Copy-Item -LiteralPath $Runner -Destination $bak -Force

# Replace the TEMP block (NEG_OK asserts) with taxonomy asserts on NFL_VERIFY_FAIL:<Expect>
$old = 'AssertContains $r2.stdout "VECTOR_SELFTEST_OK" "ERROR_TAXONOMY_NOT_EMITTED"
AssertContains $r2.stdout "NEG_OK: tamper_payload" "ERROR_TAXONOMY_NOT_EMITTED"
AssertContains $r2.stdout "NEG_OK: missing_sig" "ERROR_TAXONOMY_NOT_EMITTED"
AssertContains $r2.stdout "NEG_OK: wrong_namespace" "ERROR_TAXONOMY_NOT_EMITTED"'
$new = '$expected=@("NFL_VERIFY_FAIL:SHA256_MISMATCH","NFL_VERIFY_FAIL:MISSING_SIG","NFL_VERIFY_FAIL:SIG_VERIFY_FAIL")
AssertAnyTokenExact $r2.stdout $expected "ERROR_TAXONOMY_NOT_EMITTED"'
if($txt -notlike ("*" + $old + "*")){ Die "PATCH_FAIL: old taxonomy block not found (runner drift)" }
$txt2 = $txt.Replace($old,$new)
WriteUtf8NoBomLfText $Runner $txt2
ParseGateFile $Runner
Write-Output ("PATCH_OK: " + $Runner)
Write-Output ("BACKUP=" + $bak)
