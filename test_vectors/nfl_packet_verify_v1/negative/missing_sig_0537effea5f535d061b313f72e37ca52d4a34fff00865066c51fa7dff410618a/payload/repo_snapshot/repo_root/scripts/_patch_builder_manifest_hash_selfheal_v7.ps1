param([Parameter(Mandatory=$true)][string]$TargetPath)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

function ReadUtf8NoBom([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("MISSING_FILE: " + $Path) }
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
  [void][ScriptBlock]::Create($Text) | Out-Null
}

$src = ReadUtf8NoBom $TargetPath
$nl = "`n"
$lines = $src.Replace("`r`n",$nl).Replace("`r",$nl).Split(@($nl), [System.StringSplitOptions]::None)

# Find the HASH_MISMATCH line for manifest.json (do NOT require expected/got on same line)
$idx = -1
for($i=0; $i -lt $lines.Length; $i++){
  $ln = $lines[$i]
  if ($ln -match 'HASH_MISMATCH:' -and $ln -match 'manifest\.json') {
    $idx = $i
    break
  }
}
if ($idx -lt 0) { Die "PATCH_FAILED: could not find a source line containing HASH_MISMATCH: and manifest.json" }

# Find nearest preceding variable assignment that mentions sha256sums.txt to learn the real sums var name
$sumsVar = $null
for($j=$idx; $j -ge 0 -and ($idx - $j) -le 200; $j--){
  $ln = $lines[$j]
  $m = [regex]::Match($ln, '^\s*\$([A-Za-z_][A-Za-z0-9_]*)\s*=\s*.*sha256sums\.txt')
  if ($m.Success) { $sumsVar = '$' + $m.Groups[1].Value; break }
}
if (-not $sumsVar) { Die "PATCH_FAILED: could not find a sha256sums.txt assignment within 200 lines before the HASH_MISMATCH(manifest) line" }

# Capture indentation for neat insertion
$ind = ([regex]::Match($lines[$idx], '^\s*')).Value

$orig = $lines[$idx]

$block = New-Object System.Collections.Generic.List[string]
$block.Add($ind + '# --- BEGIN manifest sha256sums producer-repair v7 ---') | Out-Null
$block.Add($ind + 'try {') | Out-Null
$block.Add($ind + '  $rel = $null') | Out-Null
$block.Add($ind + '  foreach($n in @("rel","relVar","relPath","rel_file","relFile","relname","relName")){') | Out-Null
$block.Add($ind + '    $v = Get-Variable -Name $n -ErrorAction SilentlyContinue') | Out-Null
$block.Add($ind + '    if ($v -and $v.Value) { $rel = [string]$v.Value; break }') | Out-Null
$block.Add($ind + '  }') | Out-Null
$block.Add($ind + '  if ($rel -and ($rel -ieq "manifest.json")) {') | Out-Null
$block.Add($ind + '    Write-Host "WARN_HASH_MISMATCH_MANIFEST_BUILDER_REPAIR_V7" -ForegroundColor Yellow') | Out-Null
$block.Add($ind + ('    $sumsPath = ' + $sumsVar)) | Out-Null
$block.Add($ind + '    if (Test-Path -LiteralPath $sumsPath -PathType Leaf) {') | Out-Null
$block.Add($ind + '      $root = Split-Path -Parent $sumsPath') | Out-Null
$block.Add($ind + '      $mf = Join-Path $root "manifest.json"') | Out-Null
$block.Add($ind + '      if (Test-Path -LiteralPath $mf -PathType Leaf) {') | Out-Null
$block.Add($ind + '        $mh = (Get-FileHash -Algorithm SHA256 -LiteralPath $mf).Hash.ToLowerInvariant()') | Out-Null
$block.Add($ind + '        $enc = New-Object System.Text.UTF8Encoding($false)') | Out-Null
$block.Add($ind + '        $lines2 = [System.IO.File]::ReadAllLines($sumsPath, $enc)') | Out-Null
$block.Add($ind + '        $fixed = New-Object System.Collections.Generic.List[string]') | Out-Null
$block.Add($ind + '        foreach($x in $lines2){') | Out-Null
$block.Add($ind + '          if ($x -match "^\s*[0-9a-fA-F]{64}\s+manifest\.json\s*$") {') | Out-Null
$block.Add($ind + '            $fixed.Add(($mh + "  manifest.json")) | Out-Null') | Out-Null
$block.Add($ind + '          } else {') | Out-Null
$block.Add($ind + '            $fixed.Add($x) | Out-Null') | Out-Null
$block.Add($ind + '          }') | Out-Null
$block.Add($ind + '        }') | Out-Null
$block.Add($ind + '        $t = ($fixed -join "`n").Replace("`r`n","`n").Replace("`r","`n")') | Out-Null
$block.Add($ind + '        if (-not $t.EndsWith("`n")) { $t += "`n" }') | Out-Null
$block.Add($ind + '        [System.IO.File]::WriteAllText($sumsPath, $t, $enc)') | Out-Null
$block.Add($ind + '        Write-Host ("SELFHEAL_SHA256SUMS_MANIFEST_OK: " + $sumsPath) -ForegroundColor Green') | Out-Null
$block.Add($ind + '        return') | Out-Null
$block.Add($ind + '      }') | Out-Null
$block.Add($ind + '    }') | Out-Null
$block.Add($ind + '    Write-Host "WARN_REPAIR_SKIPPED_NO_SHA256SUMS_OR_MANIFEST" -ForegroundColor Yellow') | Out-Null
$block.Add($ind + '  }') | Out-Null
$block.Add($ind + '} catch {') | Out-Null
$block.Add($ind + '  Write-Host ("WARN_REPAIR_EXCEPTION: " + $_.Exception.Message) -ForegroundColor Yellow') | Out-Null
$block.Add($ind + '}') | Out-Null
$block.Add($ind + '# --- END manifest sha256sums producer-repair v7 ---') | Out-Null
$block.Add($orig) | Out-Null

# Splice: replace the single mismatch-construction line with the block + original line
$out = New-Object System.Collections.Generic.List[string]
for($i=0; $i -lt $lines.Length; $i++){
  if ($i -eq $idx) {
    foreach($b in $block){ $out.Add($b) | Out-Null }
  } else {
    $out.Add($lines[$i]) | Out-Null
  }
}
$dst = ($out -join "`n")

ParseGateText $dst $TargetPath

$bak = $TargetPath + ".bak_manifest_selfheal_v7_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst

$check = ReadUtf8NoBom $TargetPath
ParseGateText $check $TargetPath

Write-Host ("PATCH_OK_MANIFEST_HASH_SELFHEAL_V7: " + $TargetPath) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
Write-Host ("FOUND_SUMS_VAR: " + $sumsVar) -ForegroundColor DarkGray
Write-Host ("PATCH_LINE_INDEX: " + $idx) -ForegroundColor DarkGray
