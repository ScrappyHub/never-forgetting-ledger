param(
  [Parameter(Mandatory=$true)][string]$TargetPath
)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }
function ReadUtf8NoBom([string]$p){
  $b = [System.IO.File]::ReadAllBytes($p)
  if($b.Length -ge 3 -and $b[0]-eq 0xEF -and $b[1]-eq 0xBB -and $b[2]-eq 0xBF){ $b = $b[3..($b.Length-1)] }
  $u = New-Object System.Text.UTF8Encoding($false,$true)
  $u.GetString($b)
}
function WriteUtf8NoBomLf([string]$p,[string]$t){
  $t2 = ($t -replace "`r`n","`n") -replace "`r","`n"
  if(-not $t2.EndsWith("`n")){ $t2 += "`n" }
  $u = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllBytes($p, $u.GetBytes($t2))
}
function ParseGateUtf8NoBomText([string]$text,[string]$label){
  try { [void][ScriptBlock]::Create($text) } catch { throw ("PARSE_GATE_FAIL: " + $label + "`n" + $_.Exception.Message) }
}

if(-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)){ Die ("Target missing: " + $TargetPath) }
$src = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $src $TargetPath

$lines = @(@($src -replace "`r`n","`n" -replace "`r","`n").Split(@("`n"), [System.StringSplitOptions]::None))
$out   = New-Object System.Collections.Generic.List[string]

$did = $false

for($i=0;$i -lt $lines.Count;$i++){
  $ln = $lines[$i]

  # Replace any prior ensure-parent line that uses New-Item with CreateDirectory
  if($ln -match '^\s*if\s*\(\s*\$__parent\s+-and\s+-not\s+\(Test-Path\s+-LiteralPath\s+\$__parent\s+-PathType\s+Container\)\s*\)\s*\{\s*New-Item\s+-ItemType\s+Directory\s+-Path\s+\$__parent\s+-Force\s*\|\s*Out-Null\s*\}\s*$'){
    $indent = ""
    $m = [regex]::Match($ln,'^(\s*)')
    if($m.Success){ $indent = $m.Groups[1].Value }
    [void]$out.Add(($indent + 'if ($__parent) { [System.IO.Directory]::CreateDirectory($__parent) | Out-Null }'))
    $did = $true
    continue
  }

  # If we see the $__parent assignment but no CreateDirectory next line, inject it (idempotent)
  if($ln -match '^\s*\$__parent\s*=\s*Split-Path\s+-Parent\s+\$target\s*$'){
    [void]$out.Add($ln)
    $next = $null
    if(($i + 1) -lt $lines.Count){ $next = $lines[$i+1] }
    if($null -eq $next -or $next -notmatch 'CreateDirectory\(\$__parent\)'){
      $indent = ""
      $m = [regex]::Match($ln,'^(\s*)')
      if($m.Success){ $indent = $m.Groups[1].Value }
      [void]$out.Add(($indent + 'if ($__parent) { [System.IO.Directory]::CreateDirectory($__parent) | Out-Null }'))
      $did = $true
    }
    continue
  }

  [void]$out.Add($ln)
}

if(-not $did){ Die "PATCH_FAILED: no ensure-parent blocks found to upgrade to CreateDirectory (or already upgraded)." }

$dst = ($out -join "`n")
ParseGateUtf8NoBomText $dst $TargetPath

$bak = $TargetPath + ".bak_copyitem_ensure_parent_v14_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst

$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath

Write-Host ("PATCH_OK_COPYITEM_ENSURE_PARENT_V14: " + $TargetPath) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
