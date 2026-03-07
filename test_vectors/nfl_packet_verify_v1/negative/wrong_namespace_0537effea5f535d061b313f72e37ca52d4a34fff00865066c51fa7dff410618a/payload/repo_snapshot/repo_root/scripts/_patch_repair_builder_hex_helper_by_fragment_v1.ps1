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
function ParseGateUtf8NoBomText([string]$text,[string]$path){
  try { [void][ScriptBlock]::Create($text) } catch { Die ("PARSE_ERROR: " + $_.Exception.Message + " (file: " + $path + ")") }
}

if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) { Die ("MISSING_TARGET: " + $TargetPath) }
$src = ReadUtf8NoBom $TargetPath

# Backup first
$bak = $TargetPath + ".bak." + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
if (-not (Test-Path -LiteralPath $bak -PathType Leaf)) { Die ("BACKUP_FAILED: " + $bak) }

# Find corrupted hex fragment (allow whitespace/newlines)
$rx = New-Object System.Text.RegularExpressions.Regex(
  'ToString\("x2"\)\s*\}\)\s*-join\s*""\s*\)\s*\)' ,
  [System.Text.RegularExpressions.RegexOptions]::Singleline
)
$m = $rx.Match($src)
if (-not $m.Success) { Die ("FRAGMENT_NOT_FOUND: expected corrupt ToString(""x2"") ... -join """" fragment in " + $TargetPath) }
$fragIdx = $m.Index

# Locate enclosing function by scanning backward to nearest "function "
$funcStart = $src.LastIndexOf("function ", $fragIdx, [System.StringComparison]::OrdinalIgnoreCase)
if ($funcStart -lt 0) { Die ("FUNC_START_NOT_FOUND: no ""function "" before fragment in " + $TargetPath) }

# Function end = next newline + "function " after fragment (or EOF)
$nextFunc = $src.IndexOf("`nfunction ", $fragIdx, [System.StringComparison]::OrdinalIgnoreCase)
if ($nextFunc -lt 0) { $nextFunc = $src.Length }

$funcBlock = $src.Substring($funcStart, $nextFunc - $funcStart)
$nameRx = New-Object System.Text.RegularExpressions.Regex(
  '(?im)^\s*function\s+([A-Za-z0-9_\-]+)\s*\('
)
$nm = $nameRx.Match($funcBlock)
if (-not $nm.Success) { Die ("FUNC_NAME_NOT_FOUND: could not parse function name for block containing fragment") }
$funcName = $nm.Groups[1].Value

$before = $src.Substring(0, $funcStart)
$after  = $src.Substring($nextFunc)

# Replacement: same function name, PS5.1-safe, no pipelines
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

# Must parse after repair
$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath
Write-Host ("PATCH_OK_FRAGMENT_HEX_HELPER: " + $TargetPath + "  func=" + $funcName) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
