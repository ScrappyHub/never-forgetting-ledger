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
$hitLine = -1

for($i=0;$i -lt $lines.Count;$i++){
  $ln = $lines[$i]

  # Token match for the exact failing Copy-Item call site
  $hasCopy = ($ln.IndexOf("Copy-Item",[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  $hasIt   = ($ln.IndexOf('$it.FullName',[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  $hasDest = ($ln.IndexOf("-Destination",[System.StringComparison]::OrdinalIgnoreCase) -ge 0)
  $hasTgt  = ($ln.IndexOf('$target',[System.StringComparison]::OrdinalIgnoreCase) -ge 0)

  $isCopyAnchor = ($hasCopy -and $hasIt -and $hasDest -and $hasTgt)

  if($isCopyAnchor -and $patched -eq 0){
    $hitLine = $i

    # Preserve indentation from the Copy-Item line
    $indent = ""
    $m = [regex]::Match($ln,'^(\s*)')
    if($m.Success){ $indent = $m.Groups[1].Value }

    # Replace the Copy-Item invocation with a hardened block.
    # Also consume a following "-Force" line if present so we don't duplicate.
    $next = if(($i+1) -lt $lines.Count){ $lines[$i+1] } else { "" }
    $consumeNextForce = ($next -match '^\s*-Force\s*$')

    [void]$out.Add(($indent + "# Hardened Copy-Item (v23): skip .bak_* and ensure destination parent exists"))
    [void]$out.Add(($indent + "if (`$it -and `$it.Name -and (`$it.Name -like '*.bak_*')) { continue }"))
    [void]$out.Add(($indent + "`$__parent = Split-Path -Parent `$target"))
    [void]$out.Add(($indent + "if (`$__parent) { [System.IO.Directory]::CreateDirectory(`$__parent) | Out-Null }"))
    [void]$out.Add(($indent + "Copy-Item -LiteralPath `$it.FullName -Destination `$target -Force"))

    if($consumeNextForce){
      $i += 1
    }

    $patched = 1
    continue
  }

  [void]$out.Add($ln)
}

if($patched -ne 1){
  Die "PATCH_FAILED: Copy-Item anchor not found (Copy-Item + `$it.FullName + -Destination + `$target)."
}

$dst = ($out -join "`n")
ParseGateUtf8NoBomText $dst $TargetPath

$bak = $TargetPath + ".bak_copyitem_harden_v23_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst

$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath

Write-Host ("PATCH_OK_COPYITEM_HARDEN_V23: " + $TargetPath + " at_line=" + ($hitLine+1)) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
