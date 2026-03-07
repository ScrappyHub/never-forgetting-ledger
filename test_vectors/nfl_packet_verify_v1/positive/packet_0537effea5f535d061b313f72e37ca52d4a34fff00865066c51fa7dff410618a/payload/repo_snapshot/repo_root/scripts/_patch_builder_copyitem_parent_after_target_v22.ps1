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
$copyHit  = -1
$targetAssignHit = -1

for($i=0;$i -lt $lines.Count;$i++){
  $ln = $lines[$i]

  # Token match the failing Copy-Item line (same as before)
  $hasCopy = ($ln.IndexOf("Copy-Item",[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  $hasIt   = ($ln.IndexOf('$it.FullName',[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  $hasDest = ($ln.IndexOf("-Destination",[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  $hasTgt  = ($ln.IndexOf('$target',[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  $isTargetCopyLine = ($hasCopy -and $hasIt -and $hasDest -and $hasTgt)

  if($isTargetCopyLine -and $copyHit -lt 0){
    $copyHit = $i

    # Search backward for the closest "$target = ..." assignment
    $scanMax = 25
    $start = [Math]::Max(0, $out.Count - $scanMax)
    $assignIndexInOut = -1
    for($k=($out.Count-1); $k -ge $start; $k--){
      $cand = $out[$k]
      # simple, tolerant: line contains "$target" and "=" and looks like assignment
      if($cand -match '^\s*\$target\s*='){
        $assignIndexInOut = $k
        break
      }
    }

    if($assignIndexInOut -lt 0){
      Die "PATCH_FAILED: found Copy-Item line (source line $($i+1)) but could not find a preceding '\$target =' assignment within $scanMax lines."
    }

    $targetAssignHit = $assignIndexInOut

    # Idempotent: if guard already immediately follows the assignment, do nothing; else insert right after assignment.
    $next1 = if(($assignIndexInOut+1) -lt $out.Count){ $out[$assignIndexInOut+1] } else { "" }
    $next2 = if(($assignIndexInOut+2) -lt $out.Count){ $out[$assignIndexInOut+2] } else { "" }

    $already = (
      ($next1.IndexOf('$__parent = Split-Path -Parent $target',[System.StringComparison]::OrdinalIgnoreCase) -ge 0) -and
      ($next2.IndexOf('[System.IO.Directory]::CreateDirectory($__parent)',[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    )

    if(-not $already){
      # Preserve indentation of the assignment line
      $indent = ""
      $m = [regex]::Match($out[$assignIndexInOut],'^(\s*)')
      if($m.Success){ $indent = $m.Groups[1].Value }

      $g1 = ($indent + '$__parent = Split-Path -Parent $target')
      $g2 = ($indent + 'if ($__parent) { [System.IO.Directory]::CreateDirectory($__parent) | Out-Null }')

      # Insert into $out at assignIndex+1 (must shift subsequent indexes)
      $tmp = New-Object System.Collections.Generic.List[string]
      for($z=0;$z -le $assignIndexInOut;$z++){ [void]$tmp.Add($out[$z]) }
      [void]$tmp.Add($g1)
      [void]$tmp.Add($g2)
      for($z=($assignIndexInOut+1);$z -lt $out.Count;$z++){ [void]$tmp.Add($out[$z]) }
      $out = $tmp

      $inserted++
    }
  }

  [void]$out.Add($ln)
}

if($copyHit -lt 0){
  Die "PATCH_FAILED: could not find Copy-Item line containing Copy-Item + `$it.FullName + -Destination + `$target."
}

$dst = ($out -join "`n")
ParseGateUtf8NoBomText $dst $TargetPath

$bak = $TargetPath + ".bak_copyitem_parent_after_target_v22_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst

$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath

Write-Host ("PATCH_OK_COPYITEM_PARENT_AFTER_TARGET_V22: " + $TargetPath + " inserted=" + $inserted + " copy_line=" + ($copyHit+1)) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
