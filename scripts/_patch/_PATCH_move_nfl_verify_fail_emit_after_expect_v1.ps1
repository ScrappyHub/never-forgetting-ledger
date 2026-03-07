param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Die([string]$m){ throw ("NFL_PATCH_MOVE_TAXONOMY_FAIL: " + $m) }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeLf([string]$t){ if($null -eq $t){ return "" }; $u = ($t -replace "`r`n","`n") -replace "`r","`n"; if(-not $u.EndsWith("`n")){ $u += "`n" }; return $u }
function ReadUtf8([string]$p){ [System.IO.File]::ReadAllText($p,(Utf8NoBom)) }
function WriteUtf8NoBomLfText([string]$p,[string]$text){ $u=NormalizeLf $text; [System.IO.File]::WriteAllBytes($p,(Utf8NoBom).GetBytes($u)); if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Die ("WRITE_FAILED: " + $p) } }
function ParseGateFile([string]$Path){ if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("PARSEGATE_MISSING: " + $Path) }; $tok=$null; $err=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tok,[ref]$err); if($err -and @(@($err)).Count -gt 0){ $m = ($err | Select-Object -First 10 | ForEach-Object { $_.ToString() }) -join " | "; Die ("PARSEGATE_FAIL: " + $Path + " :: " + $m) } }

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$Target = Join-Path (Join-Path $RepoRoot "scripts") "selftest_vectors_v1.ps1"
if(-not (Test-Path -LiteralPath $Target -PathType Leaf)){ Die ("MISSING_TARGET: " + $Target) }
$bak = $Target + ".bak_" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
Copy-Item -LiteralPath $Target -Destination $bak -Force

$txt = NormalizeLf (ReadUtf8 $Target)

$emit = '  Write-Output ("NFL_VERIFY_FAIL:" + $expect)'
$expectHost = '  Write-Host ("  EXPECT: " + $expect)'

# remove any existing taxonomy emit lines anywhere
$txt1 = [regex]::Replace($txt,'(?m)^[ \t]*Write-Output \("NFL_VERIFY_FAIL:" \+ \$expect\)\s*$' ,'' )
$txt1 = NormalizeLf $txt1

# insert exactly once after EXPECT host line
$hits = [regex]::Matches($txt1,'(?m)^[ \t]*Write-Host \("  EXPECT: " \+ \$expect\)\s*$')
if($hits.Count -ne 1){ Die ("EXPECT_HOST_MATCH_COUNT_NOT_1: " + $hits.Count) }
$txt2 = [regex]::Replace($txt1,'(?m)^([ \t]*Write-Host \("  EXPECT: " \+ \$expect\))\s*$','$1`n' + $emit,1)

# prove exactly one emit remains
$emitHits = [regex]::Matches($txt2,'(?m)^[ \t]*Write-Output \("NFL_VERIFY_FAIL:" \+ \$expect\)\s*$')
if($emitHits.Count -ne 1){ Die ("EMIT_LINE_COUNT_NOT_1: " + $emitHits.Count) }

WriteUtf8NoBomLfText $Target $txt2
ParseGateFile $Target
Write-Output ("PATCH_OK: " + $Target)
Write-Output ("BACKUP=" + $bak)
