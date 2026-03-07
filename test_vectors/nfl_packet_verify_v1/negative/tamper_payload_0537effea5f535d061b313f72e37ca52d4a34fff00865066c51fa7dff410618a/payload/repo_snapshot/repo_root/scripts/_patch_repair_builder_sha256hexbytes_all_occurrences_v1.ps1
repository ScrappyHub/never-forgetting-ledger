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
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Die ("PARSEGATE_MISSING: " + $p) }
  $raw = [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
  try { [void][ScriptBlock]::Create($raw) } catch { Die ("PARSE_ERROR: " + $_.Exception.Message + " (file: " + $p + ")") }
}

if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) { Die ("MISSING_TARGET: " + $TargetPath) }
$src = ReadUtf8NoBom $TargetPath

# Backup first (deterministic name next to target)
$bak = $TargetPath + ".bak." + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
if (-not (Test-Path -LiteralPath $bak -PathType Leaf)) { Die ("BACKUP_FAILED: " + $bak) }

# Replace ALL occurrences of: function Sha256HexBytes([byte[]]$b){ ... }
# using anchor scan: start at marker, end at next "function " marker (or EOF).
$startMarker = "function Sha256HexBytes"
$dst = $src
$count = 0
$scanIdx = 0
while ($true) {
  $s = $dst.IndexOf($startMarker, $scanIdx, [System.StringComparison]::OrdinalIgnoreCase)
  if ($s -lt 0) { break }

  $nextFunc = $dst.IndexOf("function ", $s + 1, [System.StringComparison]::OrdinalIgnoreCase)
  if ($nextFunc -lt 0) { $nextFunc = $dst.Length }

  $before = $dst.Substring(0, $s)
  $after  = $dst.Substring($nextFunc)

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
  $count++

  # continue scanning after the inserted fixed block
  $scanIdx = ($before.Length + $fixed.Length)
}

if ($count -lt 1) { Die ("PATCH_FAILED: no occurrences of " + $startMarker + " found in " + $TargetPath) }

WriteUtf8NoBomLf $TargetPath $dst

# Must succeed after repair (builder must parse in host)
ParseGateUtf8NoBom $TargetPath
Write-Host ("PATCH_OK: replaced " + $count + " Sha256HexBytes block(s) in " + $TargetPath) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
