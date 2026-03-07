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
$patched = 0
$hits = New-Object System.Collections.Generic.List[int]

for($i=0;$i -lt $lines.Count;$i++){
  $ln = $lines[$i]

  # Detect an already-hardened block directly above to keep idempotence
  $prev1 = if(($out.Count-1) -ge 0){ $out[$out.Count-1] } else { "" }
  $prev2 = if(($out.Count-2) -ge 0){ $out[$out.Count-2] } else { "" }
  $prev3 = if(($out.Count-3) -ge 0){ $out[$out.Count-3] } else { "" }

  $already = (
    ($prev3.IndexOf("Hardened Copy-Item (v24)",[System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
    ($prev2.IndexOf("Hardened Copy-Item (v24)",[System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
    ($prev1.IndexOf("Hardened Copy-Item (v24)",[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  )

  $hasCopy = ($ln.IndexOf("Copy-Item",[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  $hasIt   = ($ln.IndexOf('$it.FullName',[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  $hasDest = ($ln.IndexOf("-Destination",[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  $hasTgt  = ($ln.IndexOf('$target',[System.StringComparison]::OrdinalIgnoreCase) -ge 0)

  $isCopyAnchor = ($hasCopy -and $hasIt -and $hasDest -and $hasTgt)

  if($isCopyAnchor -and (-not $already)){
    $indent = ""
    $m = [regex]::Match($ln,'^(\s*)')
    if($m.Success){ $indent = $m.Groups[1].Value }

    $next = if(($i+1) -lt $lines.Count){ $lines[$i+1] } else { "" }
    $consumeNextForce = ($next -match '^\s*-Force\s*$')

    [void]$out.Add(($indent + "# Hardened Copy-Item (v24): skip .bak_* and ensure destination parent exists"))
    [void]$out.Add(($indent + "if (`$it -and `$it.Name -and (`$it.Name -like '*.bak_*')) { continue }"))
    [void]$out.Add(($indent + "`$__parent = Split-Path -Parent `$target"))
    [void]$out.Add(($indent + "if (`$__parent) { [System.IO.Directory]::CreateDirectory(`$__parent) | Out-Null }"))
    [void]$out.Add(($indent + "Copy-Item -LiteralPath `$it.FullName -Destination `$target -Force"))

    if($consumeNextForce){ $i += 1 }

    $patched++
    [void]$hits.Add($i+1)
    continue
  }

  [void]$out.Add($ln)
}

if($patched -le 0){
  Die "PATCH_FAILED: no Copy-Item anchors found to harden (Copy-Item + `$it.FullName + -Destination + `$target)."
}

$dst = ($out -join "`n")
ParseGateUtf8NoBomText $dst $TargetPath

$bak = $TargetPath + ".bak_copyitem_harden_all_v24_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst

$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath

Write-Host ("PATCH_OK_COPYITEM_HARDEN_ALL_V24: " + $TargetPath + " patched=" + $patched) -ForegroundColor Green
Write-Host ("HIT_LINES: " + (($hits.ToArray() | ForEach-Object { $_.ToString() }) -join ",")) -ForegroundColor DarkGray
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
