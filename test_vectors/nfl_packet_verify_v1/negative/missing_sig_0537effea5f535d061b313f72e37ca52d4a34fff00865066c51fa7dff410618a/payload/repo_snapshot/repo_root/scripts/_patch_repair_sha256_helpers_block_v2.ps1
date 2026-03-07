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
function ParseGateUtf8NoBom([string]$p){
  $t = ReadUtf8NoBom $p
  try { [ScriptBlock]::Create($t) | Out-Null } catch { Die ("PARSE_ERROR: " + $_.Exception.Message + " (file: " + $p + ")") }
}
if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) { Die ("MISSING_TARGET: " + $TargetPath) }
$src = ReadUtf8NoBom $TargetPath
$startMarker = "function Sha256HexBytes"
$startIdx = $src.IndexOf($startMarker, [System.StringComparison]::OrdinalIgnoreCase)
if ($startIdx -lt 0) { Die ("PATCH_ANCHOR_NOT_FOUND_START: " + $startMarker + " in " + $TargetPath) }
$endMarkers = @("function CanonJson","function ToCanonJson","function MakeManifest","function BuildManifest","function MakePacket","function BuildPacket")
$endIdx = -1
$endMarkerUsed = ""
foreach ($m in $endMarkers) {
  $i = $src.IndexOf($m, $startIdx + 1, [System.StringComparison]::OrdinalIgnoreCase)
  if ($i -ge 0) { $endIdx = $i; $endMarkerUsed = $m; break }
}
if ($endIdx -lt 0) {
  $i2 = $src.IndexOf("function ", $startIdx + 1, [System.StringComparison]::OrdinalIgnoreCase)
  if ($i2 -ge 0) { $endIdx = $i2; $endMarkerUsed = "function <next>" }
}
if ($endIdx -lt 0) { Die ("PATCH_ANCHOR_NOT_FOUND_END: could not locate end of sha helper region in " + $TargetPath) }
$before = $src.Substring(0, $startIdx)
$after  = $src.Substring($endIdx)
$fixed = @(
'# ---- SHA256 helpers (PS5.1-safe, no pipeline) ----'
'function BytesToHexLower([byte[]]$h){'
'  if ($null -eq $h) { throw "BYTESTOHEX_NULL" }'
'  $sb = New-Object System.Text.StringBuilder'
'  foreach ($x in $h) { [void]$sb.AppendFormat("{0:x2}", $x) }'
'  $sb.ToString()'
'}'
''
'function Sha256HexBytes([byte[]]$b){'
'  if ($null -eq $b) { throw "SHA256_NULL_BUFFER" }'
'  $sha = [System.Security.Cryptography.SHA256]::Create()'
'  $h = $sha.ComputeHash([byte[]]$b)'
'  BytesToHexLower $h'
'}'
''
'function Sha256HexFile([string]$Path){'
'  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ("MISSING_FILE: " + $Path) }'
'  $sha = [System.Security.Cryptography.SHA256]::Create()'
'  $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)'
'  try {'
'    $h = $sha.ComputeHash($fs)'
'  } finally { $fs.Dispose() }'
'  BytesToHexLower $h'
'}'
''
'function Sha256HexTextUtf8([string]$Text){'
'  if ($null -eq $Text) { $Text = "" }'
'  $enc = New-Object System.Text.UTF8Encoding($false)'
'  $b = $enc.GetBytes($Text)'
'  Sha256HexBytes $b'
'}'
'# ---- end SHA256 helpers ----'
) -join "`n"
$dst = $before + $fixed + "`n`n" + $after
WriteUtf8NoBomLf $TargetPath $dst
ParseGateUtf8NoBom $TargetPath
Write-Host ("PATCH_OK_SHA256_HELPERS_BLOCK_V2: " + $TargetPath + " (endMarker=" + $endMarkerUsed + ")") -ForegroundColor Green
