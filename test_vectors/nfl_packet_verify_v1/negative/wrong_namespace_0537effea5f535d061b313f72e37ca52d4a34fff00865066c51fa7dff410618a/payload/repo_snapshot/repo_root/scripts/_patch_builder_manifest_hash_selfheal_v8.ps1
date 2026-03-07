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

# Anchor: first source line that contains the literal HASH_MISMATCH:
$idx = -1
for($i=0; $i -lt $lines.Length; $i++){
  if ($lines[$i] -match 'HASH_MISMATCH:') { $idx = $i; break }
}
if ($idx -lt 0) { Die "PATCH_FAILED: could not find any source line containing literal HASH_MISMATCH:" }

# Find nearest preceding variable assignment that mentions sha256sums.txt to learn the real sums var name
$sumsVar = $null
for($j=$idx; $j -ge 0 -and ($idx - $j) -le 300; $j--){
  $ln = $lines[$j]
  $m = [regex]::Match($ln, '^\s*\$([A-Za-z_][A-Za-z0-9_]*)\s*=\s*.*sha256sums\.txt')
  if ($m.Success) { $sumsVar = '$' + $m.Groups[1].Value; break }
}
if (-not $sumsVar) { Die "PATCH_FAILED: could not find a sha256sums.txt assignment within 300 lines before HASH_MISMATCH" }

# Capture indentation for neat insertion
$ind = ([regex]::Match($lines[$idx], '^\s*')).Value

$repair = New-Object System.Collections.Generic.List[string]
$repair.Add($ind + '# --- BEGIN manifest sha256sums producer-repair v8 ---') | Out-Null
$repair.Add($ind + 'try {') | Out-Null
$repair.Add($ind + '  $rel = $null') | Out-Null
$repair.Add($ind + '  foreach($n in @("rel","relVar","relPath","rel_file","relFile","relname","relName")){') | Out-Null
$repair.Add($ind + '    $v = Get-Variable -Name $n -ErrorAction SilentlyContinue') | Out-Null
$repair.Add($ind + '    if ($v -and $v.Value) { $rel = [string]$v.Value; break }') | Out-Null
$repair.Add($ind + '  }') | Out-Null
$repair.Add($ind + '  if ($rel -and ($rel -ieq "manifest.json")) {') | Out-Null
$repair.Add($ind + '    Write-Host "WARN_HASH_MISMATCH_MANIFEST_BUILDER_REPAIR_V8" -ForegroundColor Yellow') | Out-Null
$repair.Add($ind + ('    $sumsPath = ' + $sumsVar)) | Out-Null
$repair.Add($ind + '    if (Test-Path -LiteralPath $sumsPath -PathType Leaf) {') | Out-Null
$repair.Add($ind + '      $root = Split-Path -Parent $sumsPath') | Out-Null
$repair.Add($ind + '      $mf = Join-Path $root "manifest.json"') | Out-Null
$repair.Add($ind + '      if (Test-Path -LiteralPath $mf -PathType Leaf) {') | Out-Null
$repair.Add($ind + '        $mh = (Get-FileHash -Algorithm SHA256 -LiteralPath $mf).Hash.ToLowerInvariant()') | Out-Null
$repair.Add($ind + '        $enc = New-Object System.Text.UTF8Encoding($false)') | Out-Null
$repair.Add($ind + '        $lines2 = [System.IO.File]::ReadAllLines($sumsPath, $enc)') | Out-Null
$repair.Add($ind + '        $fixed = New-Object System.Collections.Generic.List[string]') | Out-Null
$repair.Add($ind + '        foreach($x in $lines2){') | Out-Null
$repair.Add($ind + '          if ($x -match "^\s*[0-9a-fA-F]{64}\s+manifest\.json\s*$") {') | Out-Null
$repair.Add($ind + '            $fixed.Add(($mh + "  manifest.json")) | Out-Null') | Out-Null
$repair.Add($ind + '          } else {') | Out-Null
$repair.Add($ind + '            $fixed.Add($x) | Out-Null') | Out-Null
$repair.Add($ind + '          }') | Out-Null
$repair.Add($ind + '        }') | Out-Null
$repair.Add($ind + '        $t = ($fixed -join "`n").Replace("`r`n","`n").Replace("`r","`n")') | Out-Null
$repair.Add($ind + '        if (-not $t.EndsWith("`n")) { $t += "`n" }') | Out-Null
$repair.Add($ind + '        [System.IO.File]::WriteAllText($sumsPath, $t, $enc)') | Out-Null
$repair.Add($ind + '        Write-Host ("SELFHEAL_SHA256SUMS_MANIFEST_OK: " + $sumsPath) -ForegroundColor Green') | Out-Null
$repair.Add($ind + '        return') | Out-Null
$repair.Add($ind + '      }') | Out-Null
$repair.Add($ind + '    }') | Out-Null
$repair.Add($ind + '    Write-Host "WARN_REPAIR_SKIPPED_NO_SHA256SUMS_OR_MANIFEST" -ForegroundColor Yellow') | Out-Null
$repair.Add($ind + '  }') | Out-Null
$repair.Add($ind + '} catch {') | Out-Null
$repair.Add($ind + '  Write-Host ("WARN_REPAIR_EXCEPTION: " + $_.Exception.Message) -ForegroundColor Yellow') | Out-Null
$repair.Add($ind + '}') | Out-Null
$repair.Add($ind + '# --- END manifest sha256sums producer-repair v8 ---') | Out-Null

# Splice: insert repair block immediately BEFORE the HASH_MISMATCH line
$out = New-Object System.Collections.Generic.List[string]
for($i=0; $i -lt $lines.Length; $i++){
  if ($i -eq $idx) {
    foreach($b in $repair){ $out.Add($b) | Out-Null }
  }
  $out.Add($lines[$i]) | Out-Null
}
$dst = ($out -join "`n")

ParseGateText $dst $TargetPath

$bak = $TargetPath + ".bak_manifest_selfheal_v8_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst

$check = ReadUtf8NoBom $TargetPath
ParseGateText $check $TargetPath

Write-Host ("PATCH_OK_MANIFEST_HASH_SELFHEAL_V8: " + $TargetPath) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
Write-Host ("FOUND_SUMS_VAR: " + $sumsVar) -ForegroundColor DarkGray
Write-Host ("PATCH_LINE_INDEX: " + $idx) -ForegroundColor DarkGray
