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

$norm  = ($src -replace "`r`n","`n") -replace "`r","`n"
$lines = @(@($norm.Split(@("`n"), [System.StringSplitOptions]::None)))

$out = New-Object System.Collections.Generic.List[string]
$inserted = 0

# exact failing anchor:
#   Copy-Item -LiteralPath $it.FullName -Destination $target
#   -Force
$rx1 = '^\s*Copy-Item\s+-LiteralPath\s+\$it\.FullName\s+-Destination\s+\$target\s*$'
$rx2 = '^\s*-Force\s*$'

for($i=0;$i -lt $lines.Count;$i++){
  $ln = $lines[$i]

  $isAnchor = $false
  if(($ln -match $rx1) -and (($i+1) -lt $lines.Count) -and ($lines[$i+1] -match $rx2)){
    $isAnchor = $true
  }

  if($isAnchor){
    # idempotent: if guard already present immediately above, don't insert again
    $prev1 = if(($out.Count-1) -ge 0){ $out[$out.Count-1] } else { "" }
    $prev2 = if(($out.Count-2) -ge 0){ $out[$out.Count-2] } else { "" }
    $already = (($prev2 -match '\$__parent\s*=\s*Split-Path\s+-Parent\s+\$target') -and
                ($prev1 -match '\[System\.IO\.Directory\]::CreateDirectory\(\$__parent\)'))

    if(-not $already){
      $indent = ""
      $m = [regex]::Match($ln,'^(\s*)')
      if($m.Success){ $indent = $m.Groups[1].Value }

      [void]$out.Add(($indent + '$__parent = Split-Path -Parent $target'))
      [void]$out.Add(($indent + 'if ($__parent) { [System.IO.Directory]::CreateDirectory($__parent) | Out-Null }'))
      $inserted++
    }
  }

  [void]$out.Add($ln)
}

if($inserted -le 0){
  Die "PATCH_FAILED: did not find the 2-line Copy-Item anchor (Copy-Item ... `$it.FullName ... -Destination `$target + next line -Force)."
}

$dst = ($out -join "`n")
ParseGateUtf8NoBomText $dst $TargetPath

$bak = $TargetPath + ".bak_copyitem_parent_inline_v20_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst

$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath

Write-Host ("PATCH_OK_COPYITEM_PARENT_INLINE_V20: " + $TargetPath + "  inserted=" + $inserted) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
