param([Parameter(Mandatory=$true)][string]$TargetPath)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function ReadUtf8NoBom([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw ("MISSING_FILE: " + $Path) }
  $enc = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::ReadAllText($Path,$enc)
}
function WriteUtf8NoBomLf([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $t = $Text.Replace("`r`n","`n").Replace("`r","`n")
  if (-not $t.EndsWith("`n")) { $t += "`n" }
  [System.IO.File]::WriteAllBytes($Path, $enc.GetBytes($t))
}
function ParseGateText([string]$Text,[string]$Path){
  [void][ScriptBlock]::Create($Text)
}

$src = ReadUtf8NoBom $TargetPath

# Patch the Copy-Item site:
# - Skip backup files (*.bak_*)
# - Ensure parent directory exists before Copy-Item
#
# We patch by replacing the exact Copy-Item statement line (first occurrence).

$rx = '(?im)^\s*Copy-Item\s+-LiteralPath\s+\$it\.FullName\s+-Destination\s+\$target\s+-Force\s*$'
$m = [regex]::Match($src,$rx)
if (-not $m.Success) { throw "PATCH_FAILED: could not find Copy-Item -LiteralPath `$it.FullName -Destination `$target -Force" }

$ins = @()
$ins += '      if ($it -and $it.Name -and ($it.Name -match ''\.bak_'')) {'
$ins += '        Write-Host ("SKIP_BACKUP_FILE: " + $it.Name) -ForegroundColor DarkGray'
$ins += '        continue'
$ins += '      }'
$ins += '      $parent = Split-Path -Parent $target'
$ins += '      if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {'
$ins += '        New-Item -ItemType Directory -Force -Path $parent | Out-Null'
$ins += '      }'
$ins += '      Copy-Item -LiteralPath $it.FullName -Destination $target -Force'

$replacement = ($ins -join "`n")

$dst = $src.Substring(0,$m.Index) + $replacement + $src.Substring($m.Index + $m.Length)

ParseGateText $dst $TargetPath

$bak = $TargetPath + ".bak_copyitem_parent_v11_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst

$check = ReadUtf8NoBom $TargetPath
ParseGateText $check $TargetPath

Write-Host ("PATCH_OK_COPYITEM_PARENT_V11: " + $TargetPath) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
