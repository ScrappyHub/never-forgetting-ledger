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
$startMarker = "function Sha256HexBytes"
$startIdx = $src.IndexOf($startMarker, [System.StringComparison]::OrdinalIgnoreCase)
if ($startIdx -lt 0) { Die ("PATCH_ANCHOR_NOT_FOUND_START: " + $startMarker + " in " + $TargetPath) }
$endMarkers = @("function Sha256HexFile","function Sha256HexText","function Sha256HexString","function CanonJson","function ToCanonJson")
$endIdx = -1
$endMarkerUsed = ""
foreach ($m in $endMarkers) {
  $i = $src.IndexOf($m, $startIdx + 1, [System.StringComparison]::OrdinalIgnoreCase)
  if ($i -ge 0) { $endIdx = $i; $endMarkerUsed = $m; break }
}
if ($endIdx -lt 0) { Die ("PATCH_ANCHOR_NOT_FOUND_END: none of end markers found after Sha256HexBytes in " + $TargetPath) }
$before = $src.Substring(0, $startIdx)
$after  = $src.Substring($endIdx)
$fixed = @(
'function Sha256HexBytes([byte[]]$b){'
'  if ($null -eq $b) { throw "SHA256_NULL_BUFFER" }'
'  $sha = [System.Security.Cryptography.SHA256]::Create()'
'  $h = $sha.ComputeHash([byte[]]$b)'
'  $sb = New-Object System.Text.StringBuilder'
'  foreach ($x in $h) { [void]$sb.AppendFormat("{0:x2}", $x) }'
'  $sb.ToString()'
'}'
) -join "`n"
$dst = $before + $fixed + "`n`n" + $after
WriteUtf8NoBomLf $TargetPath $dst
ParseGate $TargetPath
Write-Host ("PATCH_OK_REPAIRED_SHA256HEXBYTES_REGION: " + $TargetPath + " (endMarker=" + $endMarkerUsed + ")") -ForegroundColor Green
