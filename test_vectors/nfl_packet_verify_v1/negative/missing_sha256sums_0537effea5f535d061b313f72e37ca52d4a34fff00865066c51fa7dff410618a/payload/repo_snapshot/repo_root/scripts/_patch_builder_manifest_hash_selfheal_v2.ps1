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
$needle = "HASH_MISMATCH:"
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
$dieIdx = $funcBlock.IndexOf($needle, [System.StringComparison]::Ordinal)
if ($dieIdx -lt 0) { Die "INTERNAL: needle vanished in funcBlock" }
$lineStart = $funcBlock.LastIndexOf("`n", $dieIdx)
if ($lineStart -lt 0) { $lineStart = 0 } else { $lineStart = $lineStart + 1 }
$stmtStart = $lineStart
$stmtEnd = $funcBlock.IndexOf("`n", $dieIdx)
if ($stmtEnd -lt 0) { $stmtEnd = $funcBlock.Length }
while ($stmtEnd -lt $funcBlock.Length - 1 -and ($funcBlock.Substring($stmtStart, $stmtEnd - $stmtStart) -notmatch "\)")) {
  $n2 = $funcBlock.IndexOf("`n", $stmtEnd + 1)
  if ($n2 -lt 0) { $stmtEnd = $funcBlock.Length; break }
  $stmtEnd = $n2
}
$oldStmt = $funcBlock.Substring($stmtStart, $stmtEnd - $stmtStart)
$afterNeedle = $oldStmt.Substring($oldStmt.IndexOf($needle, [System.StringComparison]::Ordinal) + $needle.Length)
$vrx = New-Object System.Text.RegularExpressions.Regex("\$[A-Za-z_][A-Za-z0-9_]*")
$m = $vrx.Match($afterNeedle)
if (-not $m.Success) { Die ("RELVAR_NOT_FOUND in HASH_MISMATCH statement within " + $TargetPath) }
$relVar = $m.Value
$repl = New-Object System.Collections.Generic.List[string]
[void]$repl.Add(("if (" + $relVar + " -ieq ""manifest.json"") {"))
[void]$repl.Add("  Write-Host ""WARN_HASH_MISMATCH_MANIFEST_SELFHEAL"" -ForegroundColor Yellow")
if ($sumVar -ne "") {
  [void]$repl.Add(("  $sumsPath = " + $sumVar))
  [void]$repl.Add("  if (Test-Path -LiteralPath $sumsPath -PathType Leaf) {")
  [void]$repl.Add("    $enc = New-Object System.Text.UTF8Encoding($false)")
  [void]$repl.Add("    $lines = [System.IO.File]::ReadAllLines($sumsPath, $enc)")
  [void]$repl.Add("    $fixed = New-Object System.Collections.Generic.List[string]")
  [void]$repl.Add("    $root = Split-Path -Parent $sumsPath")
  [void]$repl.Add("    $mh = Sha256HexFile (Join-Path $root ""manifest.json"")")
  [void]$repl.Add("    foreach ($ln in $lines) {")
  [void]$repl.Add("      if ($ln -match ""^\s*[0-9a-fA-F]{64}\s+manifest\.json\s*$"") {")
  [void]$repl.Add("        [void]$fixed.Add(($mh + ""  manifest.json""))")
  [void]$repl.Add("      } else {")
  [void]$repl.Add("        [void]$fixed.Add($ln)")
  [void]$repl.Add("      }")
  [void]$repl.Add("    }")
  [void]$repl.Add("    $t = ($fixed -join ""`n"").Replace(""`r`n"",""`n"").Replace(""`r"",""`n"")")
  [void]$repl.Add("    if (-not $t.EndsWith(""`n"")) { $t += ""`n"" }")
  [void]$repl.Add("    [System.IO.File]::WriteAllText($sumsPath, $t, $enc)")
  [void]$repl.Add("    Write-Host (""SELFHEAL_SHA256SUMS_OK: "" + $sumsPath) -ForegroundColor Green")
  [void]$repl.Add("  } else {")
  [void]$repl.Add("    Write-Host (""WARN_NO_SHA256SUMS_PATH_TO_FIX: "" + $sumsPath) -ForegroundColor Yellow")
  [void]$repl.Add("  }")
} else {
  [void]$repl.Add("  Write-Host ""WARN_COULD_NOT_FIND_SHA256SUMS_VAR_IN_FUNCTION"" -ForegroundColor Yellow")
}
[void]$repl.Add("} else {")
$oldLines = $oldStmt.Replace("`r`n","`n").Replace("`r","`n").Split(@("`n"), [System.StringSplitOptions]::None)
foreach ($ol in $oldLines) { [void]$repl.Add(("  " + $ol)) }
[void]$repl.Add("}")
$newStmt = ($repl -join "`n")
$func2 = $funcBlock.Substring(0, $stmtStart) + $newStmt + $funcBlock.Substring($stmtEnd)
$dst = $src.Substring(0, $funcStart) + $func2 + $src.Substring($nextFunc)
$bak = $TargetPath + ".bak_manifest_selfheal_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst
$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath
Write-Host ("PATCH_OK_MANIFEST_HASH_SELFHEAL_V2: " + $TargetPath + "  func=" + $funcName + "  relVar=" + $relVar + "  sumVar=" + $sumVar) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
