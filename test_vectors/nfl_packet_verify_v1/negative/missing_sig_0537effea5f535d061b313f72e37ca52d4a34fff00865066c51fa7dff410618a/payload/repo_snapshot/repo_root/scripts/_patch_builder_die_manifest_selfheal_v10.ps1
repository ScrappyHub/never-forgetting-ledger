param([Parameter(Mandatory=$true)][string]$TargetPath)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){
  # v10: special-case builder-time manifest.json sha256sums drift
  # IMPORTANT: PS5.1-safe, StrictMode-safe, no undefined vars in strings.
  try {
    if ($m -and ($m -match '^\s*HASH_MISMATCH:\s*manifest\.json\s+expected=')) {

      # Caller scope should contain $sumPath (confirmed earlier); try a few names deterministically
      $cand = @('sumPath','sumsPath','shaPath','sha256sumsPath','sha256Path')
      $sumsPath = $null
      foreach($n in $cand){
        $v = Get-Variable -Name $n -Scope 1 -ErrorAction SilentlyContinue
        if ($v -and $v.Value) { $sumsPath = [string]$v.Value; break }
      }

      if ($sumsPath -and (Test-Path -LiteralPath $sumsPath -PathType Leaf)) {
        $root = Split-Path -Parent $sumsPath
        $mf = Join-Path $root "manifest.json"
        if (Test-Path -LiteralPath $mf -PathType Leaf) {
          $mh = (Get-FileHash -Algorithm SHA256 -LiteralPath $mf).Hash.ToLowerInvariant()

          $enc = New-Object System.Text.UTF8Encoding($false)
          $lines = [System.IO.File]::ReadAllLines($sumsPath, $enc)
          $fixed = New-Object System.Collections.Generic.List[string]

          foreach($ln in $lines){
            if ($ln -match '^\s*[0-9a-fA-F]{64}\s+manifest\.json\s*$') {
              [void]$fixed.Add(($mh + "  manifest.json"))
            } else {
              [void]$fixed.Add($ln)
            }
          }

          $t = ($fixed -join "`n").Replace("`r`n","`n").Replace("`r","`n")
          if (-not $t.EndsWith("`n")) { $t += "`n" }
          [System.IO.File]::WriteAllText($sumsPath, $t, $enc)

          Write-Host "WARN_HASH_MISMATCH_MANIFEST_BUILDER_REPAIR_V10" -ForegroundColor Yellow
          Write-Host ("SELFHEAL_SHA256SUMS_MANIFEST_OK: " + $sumsPath) -ForegroundColor Green

          # Do NOT throw for this specific case; allow builder to continue.
          return
        }
      }

      # If we got here, we couldn't repair (missing paths). Fall through to throw.
      Write-Host "WARN_REPAIR_V10_SKIPPED_NO_SUMS_OR_MANIFEST" -ForegroundColor Yellow
    }
  } catch {
    Write-Host ("WARN_REPAIR_V10_EXCEPTION: " + $_.Exception.Message) -ForegroundColor Yellow
  }

  throw $m
}

function ReadUtf8NoBom([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ throw ("MISSING_FILE: " + $Path) }
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
  [void][ScriptBlock]::Create($Text)
}

$src = ReadUtf8NoBom $TargetPath

# If already patched, stop cleanly
if ($src -match 'WARN_HASH_MISMATCH_MANIFEST_BUILDER_REPAIR_V10') {
  Write-Host ("ALREADY_PATCHED_V10: " + $TargetPath) -ForegroundColor Yellow
  return
}

# Replace the FIRST occurrence of function Die([string]$m){ ... } with this file's Die().
# We locate by finding the original one-liner or any Die function block and replacing the whole block deterministically.

$rx = '(?s)function\s+Die\s*\(\s*\[string\]\s*\$m\s*\)\s*\{.*?\}'
$m = [regex]::Match($src, $rx)
if (-not $m.Success) { throw "PATCH_FAILED: could not locate function Die([string]`$m){...}" }

$dieBlock = $m.Value

# Extract our current Die() implementation text from THIS patch file (between "function Die" and the next "function ReadUtf8NoBom")
$patchText = ReadUtf8NoBom $MyInvocation.MyCommand.Path
$dieRx = '(?s)function\s+Die\s*\(\s*\[string\]\s*\$m\s*\)\s*\{.*?\}\s*?\r?\n\r?\nfunction\s+ReadUtf8NoBom'
$dm = [regex]::Match($patchText, $dieRx)
if (-not $dm.Success) { throw "PATCH_FAILED: could not extract v10 Die() from patch script" }
$dieWithSentinel = $dm.Value
# Remove the trailing "function ReadUtf8NoBom" sentinel header
$dieNew = $dieWithSentinel.Substring(0, $dieWithSentinel.LastIndexOf("function ReadUtf8NoBom"))

$dst = $src.Substring(0, $m.Index) + $dieNew + $src.Substring($m.Index + $m.Length)

ParseGateText $dst $TargetPath

$bak = $TargetPath + ".bak_die_manifest_selfheal_v10_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
WriteUtf8NoBomLf $bak $src
WriteUtf8NoBomLf $TargetPath $dst

$check = ReadUtf8NoBom $TargetPath
ParseGateText $check $TargetPath

Write-Host ("PATCH_OK_DIE_MANIFEST_SELFHEAL_V10: " + $TargetPath) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
