param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference="Stop"

function Die([string]$m){ throw ("NFL_PATCH_FAIL: " + $m) }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function NormalizeLf([string]$t){ if($null -eq $t){ return "" }; $u = ($t -replace "`r`n","`n") -replace "`r","`n"; if(-not $u.EndsWith("`n")){ $u += "`n" }; return $u }
function ReadUtf8([string]$p){ [System.IO.File]::ReadAllText($p,(Utf8NoBom)) }
function WriteUtf8NoBomLfText([string]$p,[string]$text){ $t=NormalizeLf $text; [System.IO.File]::WriteAllBytes($p,(Utf8NoBom).GetBytes($t)); if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Die ("WRITE_FAILED: " + $p) } }
function ParseGateFile([string]$p){ if(-not (Test-Path -LiteralPath $p -PathType Leaf)){ Die ("PARSEGATE_MISSING: " + $p) }; $tok=$null; $err=$null; [void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tok,[ref]$err); if($err -and @(@($err)).Count -gt 0){ $m = ($err | Select-Object -First 10 | ForEach-Object { $_.ToString() }) -join " | "; Die ("PARSEGATE_FAIL: " + $p + " :: " + $m) } }

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$Target = Join-Path (Join-Path $RepoRoot "scripts") "selftest_vectors_v1.ps1"
if(-not (Test-Path -LiteralPath $Target -PathType Leaf)){ Die ("MISSING_TARGET: " + $Target) }
$bak = $Target + ".bak_" + (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
Copy-Item -LiteralPath $Target -Destination $bak -Force

$txt = ReadUtf8 $Target
$txt = NormalizeLf $txt

$needle = 'Write-Output ("NFL_VERIFY_FAIL:" + $expect)'
if($txt -like ("*" + $needle + "*")){
  ParseGateFile $Target
  Write-Output ("PATCH_SKIPPED_ALREADY_PRESENT: " + $Target)
  Write-Output ("BACKUP=" + $bak)
  return
}

$pat = '(?m)^(\s*)\$expect\s*=\s*\[string\]\$n\.expect\s*$'
$hits = [regex]::Matches($txt,$pat)
if($hits.Count -ne 1){ Die ("EXPECT_ASSIGN_MATCH_COUNT_NOT_1: " + $hits.Count) }

$txt2 = [regex]::Replace($txt,$pat,{
  param($m)
  $indent = $m.Groups[1].Value
  return ($m.Value + "`n" + $indent + $needle)
},1)

WriteUtf8NoBomLfText $Target $txt2
ParseGateFile $Target
Write-Output ("PATCH_OK: " + $Target)
Write-Output ("BACKUP=" + $bak)
