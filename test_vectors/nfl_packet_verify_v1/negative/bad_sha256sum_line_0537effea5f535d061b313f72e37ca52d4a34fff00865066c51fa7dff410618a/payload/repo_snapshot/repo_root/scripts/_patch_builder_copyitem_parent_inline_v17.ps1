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
$out   = New-Object System.Collections.Generic.List[string]

$did = $false

for($i=0;$i -lt $lines.Count;$i++){
  if($did){
    [void]$out.Add($lines[$i])
    continue
  }

  # Build a 1-4 line window to match split Copy-Item statements
  $w1 = $lines[$i]
  $w2 = if(($i+1) -lt $lines.Count){ $lines[$i+1] } else { "" }
  $w3 = if(($i+2) -lt $lines.Count){ $lines[$i+2] } else { "" }
  $w4 = if(($i+3) -lt $lines.Count){ $lines[$i+3] } else { "" }

  $window = ($w1 + "`n" + $w2 + "`n" + $w3 + "`n" + $w4)

  $looksLikeCopyItem = (
    ($window -match 'Copy-Item') -and
    ($window -match '\$it\.FullName') -and
    ($window -match '-Destination') -and
    ($window -match '\$target')
  )

  if($looksLikeCopyItem){
    $indent = ""
    $m = [regex]::Match($w1,'^(\s*)')
    if($m.Success){ $indent = $m.Groups[1].Value }

    # Insert parent creation BEFORE the statement begins (idempotent-ish: only once per file)
    [void]$out.Add(($indent + '$__parent = Split-Path -Parent $target'))
    [void]$out.Add(($indent + 'if ($__parent) { [System.IO.Directory]::CreateDirectory($__parent) | Out-Null }'))

    # Copy original line, then proceed normally (do NOT skip lines; just let loop continue)
    [void]$out.Add($w1)
    $did = $true
    continue
  }

  [void]$out.Add($w1)
}

if(-not $did){
  Die 'PATCH_FAILED: could not locate Copy-Item statement window containing: Copy-Item + $it.FullName + -Destination + $target'
}

$dst = ($out -join "`n")
ParseGateUtf8NoBomText $dst $TargetPath

$bak = $TargetPath + ".bak_copyitem_parent_inline_v17_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst

$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath

Write-Host ("PATCH_OK_COPYITEM_PARENT_INLINE_V17: " + $TargetPath) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
