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

  # Anchor: the actual failing copy call
  if($ln -match '^\s*Copy-Item\s+-LiteralPath\s+\$it\.FullName\s+-Destination\s+\$target\s+-Force\s*$'){
    $indent = ""
    $m = [regex]::Match($ln,'^(\s*)')
    if($m.Success){ $indent = $m.Groups[1].Value }

    # Avoid double-injection if already present in the immediately preceding line
    $prev = $null
    if($out.Count -gt 0){ $prev = $out[$out.Count-1] }

    if($null -eq $prev -or $prev -notmatch 'CreateDirectory\(\$__parent\)'){
      [void]$out.Add(($indent + '$__parent = Split-Path -Parent $target'))
      [void]$out.Add(($indent + 'if ($__parent) { [System.IO.Directory]::CreateDirectory($__parent) | Out-Null }'))
      $did = $true
    }

    [void]$out.Add($ln)
    continue
  }

  [void]$out.Add($ln)
}

if(-not $did){
  Die "PATCH_FAILED: did not find the Copy-Item line 'Copy-Item -LiteralPath $it.FullName -Destination $target -Force' to anchor the fix."
}

$dst = ($out -join "`n")
ParseGateUtf8NoBomText $dst $TargetPath

$bak = $TargetPath + ".bak_copyitem_parent_inline_v15_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst

$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath

Write-Host ("PATCH_OK_COPYITEM_PARENT_INLINE_V15: " + $TargetPath) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
