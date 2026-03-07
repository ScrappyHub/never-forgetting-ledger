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
function ParseGate([string]$p){
  $tk=$null; $er=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($p,[ref]$tk,[ref]$er)
  $errs = @(@($er))
  if ($errs.Count -gt 0) { Die ("PARSE_ERROR: " + $errs[0].Message + " (file: " + $p + ")") }
}
if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) { Die ("MISSING_TARGET: " + $TargetPath) }
$src = ReadUtf8NoBom $TargetPath
$pattern = '(?s)function\s+Sha256HexBytes\s*\(\s*\[byte\[\]\]\$b\s*\)\s*\{.*?\n\}'
$replacement = @(
'function Sha256HexBytes([byte[]]$b){'
'  if ($null -eq $b) { throw "SHA256_NULL_BUFFER" }'
'  $sha = [System.Security.Cryptography.SHA256]::Create()'
'  $h = $sha.ComputeHash([byte[]]$b)'
'  $sb = New-Object System.Text.StringBuilder'
'  foreach ($x in $h) { [void]$sb.AppendFormat("{0:x2}", $x) }'
'  $sb.ToString()'
'}'
) -join "`n"
$dst = [System.Text.RegularExpressions.Regex]::Replace($src, $pattern, $replacement)
if ($dst -eq $src) { Die ("PATCH_PATTERN_NOT_FOUND: Sha256HexBytes not found in " + $TargetPath) }
WriteUtf8NoBomLf $TargetPath $dst
ParseGate $TargetPath
Write-Host ("PATCH_OK_SHA256_NO_PIPELINE: " + $TargetPath) -ForegroundColor Green
