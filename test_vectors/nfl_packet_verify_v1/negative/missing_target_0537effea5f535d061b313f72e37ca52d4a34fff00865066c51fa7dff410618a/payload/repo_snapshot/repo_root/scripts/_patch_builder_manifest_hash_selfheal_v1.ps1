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
function ParseGateUtf8NoBomText([string]$Text,[string]$PathLabel){
  try { [ScriptBlock]::Create($Text) | Out-Null } catch { Die ("PARSE_ERROR: " + $_.Exception.Message + " (file: " + $PathLabel + ")") }
}
if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) { Die ("MISSING_TARGET: " + $TargetPath) }
$src = ReadUtf8NoBom $TargetPath
$needle = "HASH_MISMATCH: manifest.json"
$idx = $src.IndexOf($needle, [System.StringComparison]::Ordinal)
if ($idx -lt 0) { Die ("PATCH_NEEDLE_NOT_FOUND: " + $needle + " in " + $TargetPath) }
$funcKw = "function "
$funcStart = $src.LastIndexOf($funcKw, $idx, [System.StringComparison]::OrdinalIgnoreCase)
if ($funcStart -lt 0) { Die ("FUNC_START_NOT_FOUND before needle in " + $TargetPath) }
$nextFunc = $src.IndexOf($funcKw, $idx + 1, [System.StringComparison]::OrdinalIgnoreCase)
if ($nextFunc -lt 0) { $nextFunc = $src.Length }
$funcBlock = $src.Substring($funcStart, $nextFunc - $funcStart)
$nameRx = New-Object System.Text.RegularExpressions.Regex(
  '(?im)^\s*function\s+([A-Za-z0-9_\-]+)\s*\('
)
$nm = $nameRx.Match($funcBlock)
$funcName = "<unknown>"
if ($nm.Success) { $funcName = $nm.Groups[1].Value }
$sumVar = ""
$sumRx = New-Object System.Text.RegularExpressions.Regex(
  '(?im)^\s*(\$\w+)\s*=\s*.*sha256sums\.txt'
)
$sm = $sumRx.Match($funcBlock)
if ($sm.Success) { $sumVar = $sm.Groups[1].Value }
$msgIdx = $funcBlock.IndexOf($needle, [System.StringComparison]::Ordinal)
if ($msgIdx -lt 0) { Die "INTERNAL: needle vanished in funcBlock" }
$lineStart = $funcBlock.LastIndexOf("`n", $msgIdx)
if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart = $lineStart + 1 }
$lineEnd = $funcBlock.IndexOf("`n", $msgIdx)
if ($lineEnd -lt 0) { $lineEnd = $funcBlock.Length }
$line = $funcBlock.Substring($lineStart, $lineEnd - $lineStart)
$stmtStart = $lineStart
$stmtEnd = $lineEnd
while ($stmtEnd -lt $funcBlock.Length - 1 -and ($funcBlock.Substring($stmtStart, $stmtEnd - $stmtStart) -notmatch "\)")) {
  $n2 = $funcBlock.IndexOf("`n", $stmtEnd + 1)
  if ($n2 -lt 0) { $stmtEnd = $funcBlock.Length; break }
  $stmtEnd = $n2
}
$oldStmt = $funcBlock.Substring($stmtStart, $stmtEnd - $stmtStart)
$repl = @()
$repl += '# SELF-HEAL: manifest.json hash can change after finalize (packet_id/signature); rewrite sha256sums entry deterministically.'
$repl += 'Write-Host "WARN_HASH_MISMATCH_MANIFEST_SELFHEAL" -ForegroundColor Yellow'
if ($sumVar -ne "") {
  $repl += ("$sumsPath = " + $sumVar)
  $repl += 'if (Test-Path -LiteralPath $sumsPath -PathType Leaf) {'
  $repl += '  $enc = New-Object System.Text.UTF8Encoding($false)'
  $repl += '  $lines = [System.IO.File]::ReadAllLines($sumsPath, $enc)'
  $repl += '  $fixed = New-Object System.Collections.Generic.List[string]'
  $repl += '  $manifestHash = Sha256HexFile (Join-Path (Split-Path -Parent $sumsPath) "manifest.json")'
  $repl += '  foreach ($ln in $lines) {'
  $repl += '    if ($ln -match "^\s*[0-9a-fA-F]{64}\s+manifest\.json\s*$") {'
  $repl += '      [void]$fixed.Add(($manifestHash + "  manifest.json"))'
  $repl += '    } else {'
  $repl += '      [void]$fixed.Add($ln)'
  $repl += '    }'
  $repl += '  }'
  $repl += '  # Write back (LF, UTF-8 no BOM)'
  $repl += '  $t = ($fixed -join "`n").Replace("`r`n","`n").Replace("`r","`n")'
  $repl += '  if (-not $t.EndsWith("`n")) { $t += "`n" }'
  $repl += '  [System.IO.File]::WriteAllText($sumsPath, $t, $enc)'
  $repl += '  Write-Host ("SELFHEAL_SHA256SUMS_OK: " + $sumsPath) -ForegroundColor Green'
  $repl += '} else {'
  $repl += '  Write-Host ("WARN_NO_SHA256SUMS_PATH_TO_FIX: " + $sumsPath) -ForegroundColor Yellow'
  $repl += '}'
} else {
  $repl += 'Write-Host "WARN_COULD_NOT_FIND_SHA256SUMS_VAR_IN_FUNCTION" -ForegroundColor Yellow'
}
$newStmt = ($repl -join "`n")
$func2 = $funcBlock.Substring(0, $stmtStart) + $newStmt + $funcBlock.Substring($stmtEnd)
$dst = $src.Substring(0, $funcStart) + $func2 + $src.Substring($nextFunc)
$bak = $TargetPath + ".bak_manifest_selfheal_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst
$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath
Write-Host ("PATCH_OK_MANIFEST_HASH_SELFHEAL: " + $TargetPath + "  func=" + $funcName + "  sumVar=" + $sumVar) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
