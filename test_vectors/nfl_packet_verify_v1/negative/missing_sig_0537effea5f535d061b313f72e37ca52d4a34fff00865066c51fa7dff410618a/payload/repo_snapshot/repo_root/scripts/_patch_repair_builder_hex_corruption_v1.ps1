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
function ParseGateUtf8NoBomText([string]$t,[string]$label){
  try { [ScriptBlock]::Create($t) | Out-Null } catch { Die ("PARSE_ERROR: " + $_.Exception.Message + " (file: " + $label + ")") }
}

if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) { Die ("MISSING_TARGET: " + $TargetPath) }
$src = ReadUtf8NoBom $TargetPath

# Anchor on the known corruption fragment (do NOT require parsing first)
$frag = '.ToString("x2") }) -join "")'
$fragIdx = $src.IndexOf($frag, [System.StringComparison]::Ordinal)
if ($fragIdx -lt 0) { Die ("FRAGMENT_NOT_FOUND: " + $frag + " in " + $TargetPath) }

# Find the containing function block by scanning to the nearest "function " above, then next "function " below
$funcTok = "function "
$funcStart = $src.LastIndexOf($funcTok, $fragIdx, [System.StringComparison]::OrdinalIgnoreCase)
if ($funcStart -lt 0) { Die ("FUNC_START_NOT_FOUND: could not locate function start above corruption in " + $TargetPath) }
$nextFunc = $src.IndexOf($funcTok, $fragIdx + 1, [System.StringComparison]::OrdinalIgnoreCase)
if ($nextFunc -lt 0) { $nextFunc = $src.Length }

$funcBlock = $src.Substring($funcStart, ($nextFunc - $funcStart))
# Extract function name
$nameRx = New-Object System.Text.RegularExpressions.Regex('(?m)^\s*function\s+([A-Za-z0-9_\-]+)\s*\(')
$m = $nameRx.Match($funcBlock)
if (-not $m.Success) { Die ("FUNC_NAME_NOT_FOUND: could not parse function name for corrupted block in " + $TargetPath) }
$funcName = $m.Groups[1].Value

# Backup once, deterministically named
$bak = $TargetPath + ".bak_hexfix_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
[System.IO.File]::WriteAllText($bak, $src, (New-Object System.Text.UTF8Encoding($false)))

$before = $src.Substring(0, $funcStart)
$after  = $src.Substring($nextFunc)

# Replacement: same function name; accept [byte[]] and return lowercase hex; no pipelines; PS5.1-safe
$fixed = @(
  ("function " + $funcName + "([byte[]]$Bytes){")
  '  if ($null -eq $Bytes) { $Bytes = @() }'
  '  $sb = New-Object System.Text.StringBuilder'
  '  foreach ($b in $Bytes) { [void]$sb.AppendFormat("{0:x2}", $b) }'
  '  $sb.ToString()'
  '}'
) -join "`n"

$dst = $before + $fixed + "`n`n" + $after
WriteUtf8NoBomLf $TargetPath $dst

# Must parse after repair (in this host)
$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath
Write-Host ("PATCH_OK_BUILDER_HEX_CORRUPTION_FIXED: " + $TargetPath + "  func=" + $funcName) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
