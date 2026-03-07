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

$anchorA = "function Sha256HexBytes"
$anchorB = "function Sha256HexFile"
$i = $src.IndexOf($anchorA, [System.StringComparison]::Ordinal)
if ($i -lt 0) { Die ("ANCHOR_NOT_FOUND: " + $anchorA) }
$j = $src.IndexOf($anchorB, $i + 1, [System.StringComparison]::Ordinal)
if ($j -lt 0) { Die ("ANCHOR_NOT_FOUND_AFTER_A: " + $anchorB) }

# Replace EVERYTHING from Sha256HexBytes up to (but not including) Sha256HexFile
$before = $src.Substring(0, $i)
$after  = $src.Substring($j)

$fixed = @(
'function Sha256HexBytes([byte[]]$b){'
'  if ($null -eq $b) { throw "SHA256_NULL_BUFFER" }'
'  $sha = [System.Security.Cryptography.SHA256]::Create()'
'  $h = $sha.ComputeHash([byte[]]$b)'
'  $sb = New-Object System.Text.StringBuilder'
'  foreach ($x in $h) { [void]$sb.AppendFormat("{0:x2}", $x) }'
'  $sb.ToString()'
'}'
'
) -join "`n"

$dst = $before + $fixed + $after
WriteUtf8NoBomLf $TargetPath $dst

# Now parse-gate the repaired target (must succeed)
ParseGate $TargetPath
Write-Host ("PATCH_OK_REPAIRED_SHA256HEXBYTES: " + $TargetPath) -ForegroundColor Green
