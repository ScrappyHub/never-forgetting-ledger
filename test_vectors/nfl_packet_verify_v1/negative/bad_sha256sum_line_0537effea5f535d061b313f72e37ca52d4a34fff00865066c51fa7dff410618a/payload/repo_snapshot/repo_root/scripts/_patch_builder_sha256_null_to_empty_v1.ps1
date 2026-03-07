param([Parameter(Mandatory=$true)][string]$TargetPath)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function ReadUtf8NoBom([string]$p){
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Die ("MISSING_FILE: " + $p) }
  [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
}
function WriteUtf8NoBomLf([string]$p, [string]$t){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $t = $t.Replace("`r`n","`n").Replace("`r","`n")
  if (-not $t.EndsWith("`n")) { $t += "`n" }
  [System.IO.File]::WriteAllText($p, $t, $enc)
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Die ("WRITE_FAILED: " + $p) }
}
function ParseGateUtf8([string]$p){
  $txt = ReadUtf8NoBom $p
  try { [void][ScriptBlock]::Create($txt) } catch { Die ("PARSE_ERROR: " + $_.Exception.Message + " (file: " + $p + ")") }
}

if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) { Die ("MISSING_TARGET: " + $TargetPath) }
$src = ReadUtf8NoBom $TargetPath

# Anchor-based replace: Sha256HexBytes(...) function block -> next function marker
$startMarker = "function Sha256HexBytes"
$startIdx = $src.IndexOf($startMarker, [System.StringComparison]::OrdinalIgnoreCase)
if ($startIdx -lt 0) { Die ("PATCH_ANCHOR_NOT_FOUND_START: " + $startMarker + " in " + $TargetPath) }

$endMarkers = @("function Sha256HexFile","function Sha256HexTextUtf8","function Sha256HexText","function Sha256HexString","function CanonJson","function ToCanonJson")
$endIdx = -1
$endMarkerUsed = ""
foreach ($m in $endMarkers) {
  $i = $src.IndexOf($m, $startIdx + 1, [System.StringComparison]::OrdinalIgnoreCase)
  if ($i -ge 0) { $endIdx = $i; $endMarkerUsed = $m; break }
}
if ($endIdx -lt 0) { Die ("PATCH_ANCHOR_NOT_FOUND_END: no end marker found after Sha256HexBytes in " + $TargetPath) }

$before = $src.Substring(0, $startIdx)
$after  = $src.Substring($endIdx)

# Replacement: total function; null -> empty; PS5.1-safe; no pipelines; deterministic hex lower
$fixed = @(
'function Sha256HexBytes([byte[]]$b){'
'  if ($null -eq $b) { $b = @() }'
'  $sha = [System.Security.Cryptography.SHA256]::Create()'
'  $h = $sha.ComputeHash([byte[]]$b)'
'  $sb = New-Object System.Text.StringBuilder'
'  foreach ($x in $h) { [void]$sb.AppendFormat("{0:x2}", $x) }'
'  $sb.ToString()'
'}'
) -join "`n"

# Backup + write
$bak = $TargetPath + ".bak_sha256null_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
[System.IO.File]::Copy($TargetPath, $bak, $true)
$dst = $before + $fixed + "`n`n" + $after
WriteUtf8NoBomLf $TargetPath $dst

# Must parse after patch
ParseGateUtf8 $TargetPath
Write-Host ("PATCH_OK_SHA256_NULL_TO_EMPTY: " + $TargetPath + " (endMarker=" + $endMarkerUsed + ")") -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
