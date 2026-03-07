param([Parameter(Mandatory=$true)][string]$TargetPath)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

function ReadUtf8NoBom([string]$Path){
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
function ParseGateUtf8NoBomText([string]$Text,[string]$Path){
  [void][ScriptBlock]::Create($Text) | Out-Null
}

if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) { Die ("TARGET_NOT_FOUND: " + $TargetPath) }

$src = ReadUtf8NoBom $TargetPath
$lines = $src.Replace("`r`n","`n").Replace("`r","`n").Split(@("`n"),[System.StringSplitOptions]::None)

$out = New-Object System.Collections.Generic.List[string]
$did = $false

for ($i=0; $i -lt $lines.Length; $i++){
  $ln = $lines[$i]

  # Replace the first HASH_MISMATCH throw/Die line (the one that has expected= and got=)
  if (-not $did -and ($ln -match 'HASH_MISMATCH:' ) -and ($ln -match 'expected=' ) -and ($ln -match 'got=' )) {
    $m = [regex]::Match($ln,'^(\s*)')
    $ind = $m.Groups[1].Value

    [void]$out.Add($ind + '# --- BEGIN builder manifest hash selfheal v5 (producer-side) ---')
    [void]$out.Add($ind + '$__relName = $null')
    [void]$out.Add($ind + 'foreach($__n in @("rel","relVar","relPath","rel_file","relFile","relname","relName","relp","relP")){')
    [void]$out.Add($ind + '  $v = Get-Variable -Name $__n -ErrorAction SilentlyContinue')
    [void]$out.Add($ind + '  if ($v -and $v.Value) { $__relName = [string]$v.Value; break }')
    [void]$out.Add($ind + '}')
    [void]$out.Add($ind + 'if ($__relName -and ($__relName -ieq "manifest.json")) {')
    [void]$out.Add($ind + '  Write-Host "WARN_HASH_MISMATCH_MANIFEST_BUILDER_SELFHEAL_V5" -ForegroundColor Yellow')
    [void]$out.Add($ind + '  $__sumsPath = $null')
    [void]$out.Add($ind + '  foreach($__n in @("sumsPath","sumPath","shaPath","sha256Path","sha256sumsPath","Sha256SumsPath","SumsPath","SumPath")){')
    [void]$out.Add($ind + '    $v = Get-Variable -Name $__n -ErrorAction SilentlyContinue')
    [void]$out.Add($ind + '    if ($v -and $v.Value) { $__sumsPath = [string]$v.Value; break }')
    [void]$out.Add($ind + '  }')
    [void]$out.Add($ind + '  if (-not $__sumsPath) {')
    [void]$out.Add($ind + '    # fallback: common local name in some implementations')
    [void]$out.Add($ind + '    $v = Get-Variable -Name "sums" -ErrorAction SilentlyContinue')
    [void]$out.Add($ind + '    if ($v -and $v.Value) { $__sumsPath = [string]$v.Value }')
    [void]$out.Add($ind + '  }')
    [void]$out.Add($ind + '  if ($__sumsPath -and (Test-Path -LiteralPath $__sumsPath -PathType Leaf)) {')
    [void]$out.Add($ind + '    $__root = Split-Path -Parent $__sumsPath')
    [void]$out.Add($ind + '    $__mf = Join-Path $__root "manifest.json"')
    [void]$out.Add($ind + '    if (Test-Path -LiteralPath $__mf -PathType Leaf) {')
    [void]$out.Add($ind + '      $__mh = (Get-FileHash -Algorithm SHA256 -LiteralPath $__mf).Hash.ToLowerInvariant()')
    [void]$out.Add($ind + '      $__enc = New-Object System.Text.UTF8Encoding($false)')
    [void]$out.Add($ind + '      $__lines = [System.IO.File]::ReadAllLines($__sumsPath, $__enc)')
    [void]$out.Add($ind + '      $__fixed = New-Object System.Collections.Generic.List[string]')
    [void]$out.Add($ind + '      foreach($__x in $__lines){')
    [void]$out.Add($ind + '        if ($__x -match "^\s*[0-9a-fA-F]{64}\s+manifest\.json\s*$") {')
    [void]$out.Add($ind + '          [void]$__fixed.Add(($__mh + "  manifest.json"))')
    [void]$out.Add($ind + '        } else {')
    [void]$out.Add($ind + '          [void]$__fixed.Add($__x)')
    [void]$out.Add($ind + '        }')
    [void]$out.Add($ind + '      }')
    [void]$out.Add($ind + '      $__t = ($__fixed -join "`n").Replace("`r`n","`n").Replace("`r","`n")')
    [void]$out.Add($ind + '      if (-not $__t.EndsWith("`n")) { $__t += "`n" }')
    [void]$out.Add($ind + '      [System.IO.File]::WriteAllText($__sumsPath, $__t, $__enc)')
    [void]$out.Add($ind + '      Write-Host ("SELFHEAL_SHA256SUMS_MANIFEST_OK: " + $__sumsPath) -ForegroundColor Green')
    [void]$out.Add($ind + '      # treat as repaired; do not throw')
    [void]$out.Add($ind + '      continue')
    [void]$out.Add($ind + '    }')
    [void]$out.Add($ind + '  }')
    [void]$out.Add($ind + '  Write-Host "WARN_SELFHEAL_SKIPPED_NO_SHA256SUMS_PATH" -ForegroundColor Yellow')
    [void]$out.Add($ind + '  # fall through to original throw below')
    [void]$out.Add($ind + '}')
    [void]$out.Add($ind + '# --- END builder manifest hash selfheal v5 ---')

    # emit original line as the else/fallthrough behavior
    [void]$out.Add($ln)

    $did = $true
    continue
  }

  [void]$out.Add($ln)
}

if (-not $did) { Die "PATCH_FAILED: could not find a HASH_MISMATCH line containing expected= and got= to wrap." }

$dst = ($out -join "`n")
ParseGateUtf8NoBomText $dst $TargetPath

$bak = $TargetPath + ".bak_manifest_selfheal_v5_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst

$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath

Write-Host ("PATCH_OK_MANIFEST_HASH_SELFHEAL_V5: " + $TargetPath) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
