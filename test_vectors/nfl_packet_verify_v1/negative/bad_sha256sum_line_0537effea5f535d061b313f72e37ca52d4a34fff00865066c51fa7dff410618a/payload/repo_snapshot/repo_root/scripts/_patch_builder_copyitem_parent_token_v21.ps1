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
$hitIndex = -1

for($i=0;$i -lt $lines.Count;$i++){
  $ln = $lines[$i]

  # token-based match (case-insensitive in PowerShell comparisons via .IndexOf + OrdinalIgnoreCase)
  $hasCopy = ($ln.IndexOf("Copy-Item",[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  $hasIt   = ($ln.IndexOf('$it.FullName',[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  $hasDest = ($ln.IndexOf("-Destination",[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  $hasTgt  = ($ln.IndexOf('$target',[System.StringComparison]::OrdinalIgnoreCase) -ge 0)

  $isTargetCopyLine = ($hasCopy -and $hasIt -and $hasDest -and $hasTgt)

  if($isTargetCopyLine){
    $hitIndex = $i

    # idempotent: if guard already directly above, don't insert again
    $prev1 = if(($out.Count-1) -ge 0){ $out[$out.Count-1] } else { "" }
    $prev2 = if(($out.Count-2) -ge 0){ $out[$out.Count-2] } else { "" }
    $already = (
      ($prev2.IndexOf('$__parent = Split-Path -Parent $target',[System.StringComparison]::OrdinalIgnoreCase) -ge 0) -and
      ($prev1.IndexOf('[System.IO.Directory]::CreateDirectory($__parent)',[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    )

    if(-not $already){
      # preserve indentation of the Copy-Item line
      $indent = ""
      $m = [regex]::Match($ln,'^(\s*)')
      if($m.Success){ $indent = $m.Groups[1].Value }

      [void]$out.Add(($indent + '$__parent = Split-Path -Parent $target'))
      [void]$out.Add(($indent + 'if ($__parent) { [System.IO.Directory]::CreateDirectory($__parent) | Out-Null }'))
      $inserted++
    }

    # patch ONLY the first matching Copy-Item line (the one that’s actually failing)
    # if you later discover multiple loops, we can broaden safely.
  }

  [void]$out.Add($ln)
}

if($hitIndex -lt 0){
  Die "PATCH_FAILED: could not find Copy-Item line containing tokens: Copy-Item + `$it.FullName + -Destination + `$target."
}
if($inserted -le 0){
  Die ("PATCH_NOOP_OR_ALREADY_FIXED: matched at line " + ($hitIndex+1) + " but guard already present.")
}

$dst = ($out -join "`n")
ParseGateUtf8NoBomText $dst $TargetPath

$bak = $TargetPath + ".bak_copyitem_parent_token_v21_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst

$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath

Write-Host ("PATCH_OK_COPYITEM_PARENT_TOKEN_V21: " + $TargetPath + "  inserted=" + $inserted + "  at_line=" + ($hitIndex+1)) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
