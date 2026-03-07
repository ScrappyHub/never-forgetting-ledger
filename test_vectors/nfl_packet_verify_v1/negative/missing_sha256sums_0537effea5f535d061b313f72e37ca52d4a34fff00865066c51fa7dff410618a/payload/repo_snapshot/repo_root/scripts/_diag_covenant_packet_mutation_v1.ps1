param(
  [Parameter(Mandatory=$false)][string]$TempRoot = $env:TEMP
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }

function Sha256HexFile([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Die ("MISSING_FILE: " + $Path) }
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

# Find latest covenant temp dir
$dirs = @(@(Get-ChildItem -LiteralPath $TempRoot -Directory -ErrorAction Stop | Where-Object { $_.Name -like "covenant_transfer_*" } | Sort-Object LastWriteTimeUtc -Descending))
if ($dirs.Count -lt 1) { Die ("NO_TEMP_DIRS_MATCHING covenant_transfer_* under: " + $TempRoot) }

$top = $dirs[0].FullName
Write-Host ("TEMP_ROOT_PICKED: " + $top) -ForegroundColor Cyan

# Find packet roots under it
$packetRoots = @()
$maybe = Join-Path $top "packet_repo_snapshot"
if (Test-Path -LiteralPath $maybe -PathType Container) { $packetRoots += $maybe }
$maybe2 = Join-Path $top "packet_runtime_snapshot"
if (Test-Path -LiteralPath $maybe2 -PathType Container) { $packetRoots += $maybe2 }

if ($packetRoots.Count -lt 1) {
  # fall back: any dir named packet_* one level down
  $packetRoots = @(@(Get-ChildItem -LiteralPath $top -Directory | Where-Object { $_.Name -like "packet_*" } | ForEach-Object { $_.FullName }))
}
if ($packetRoots.Count -lt 1) { Die ("NO_PACKET_ROOTS_FOUND under: " + $top) }

foreach ($pr in $packetRoots) {
  Write-Host ""
  Write-Host ("== PACKET ROOT == " + $pr) -ForegroundColor White

  $manifest = Join-Path $pr "manifest.json"
  $sums = Join-Path $pr "sha256sums.txt"
  if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { Write-Host ("MISSING: " + $manifest) -ForegroundColor Yellow; continue }
  if (-not (Test-Path -LiteralPath $sums -PathType Leaf)) { Write-Host ("MISSING: " + $sums) -ForegroundColor Yellow; continue }

  $mh = Sha256HexFile $manifest
  $sh = Sha256HexFile $sums

  $mi = Get-Item -LiteralPath $manifest
  $si = Get-Item -LiteralPath $sums

  Write-Host ("manifest.sha256:  " + $mh)
  Write-Host ("sha256sums.sha256: " + $sh)
  Write-Host ("manifest.lastWriteUtc:  " + $mi.LastWriteTimeUtc.ToString("o"))
  Write-Host ("sha256sums.lastWriteUtc: " + $si.LastWriteTimeUtc.ToString("o"))

  if ($mi.LastWriteTimeUtc -gt $si.LastWriteTimeUtc) {
    Write-Host "ORDER_SMELL: manifest.json was modified AFTER sha256sums.txt was written." -ForegroundColor Red
  } elseif ($si.LastWriteTimeUtc -gt $mi.LastWriteTimeUtc) {
    Write-Host "ORDER_NOTE: sha256sums.txt was modified AFTER manifest.json (this is OK only if manifest never changes afterwards)." -ForegroundColor Green
  } else {
    Write-Host "ORDER_NOTE: manifest and sha256sums have equal write times (low resolution clock; still check content)." -ForegroundColor Yellow
  }

  $lines = @(@(Get-Content -LiteralPath $sums -Encoding UTF8))
  $rx = '^\s*([0-9a-fA-F]{64})\s+manifest\.json\s*$'
  $found = $null
  foreach($ln in $lines){
    $m = [regex]::Match($ln,$rx)
    if($m.Success){ $found = $m.Groups[1].Value.ToLowerInvariant(); break }
  }

  if ($null -eq $found) {
    Write-Host "SumsLine: manifest.json entry NOT FOUND in sha256sums.txt" -ForegroundColor Red
  } else {
    Write-Host ("sums.expected(manifest.json): " + $found)
    if ($found -ne $mh) {
      Write-Host "MISMATCH_CONFIRMED: sha256sums.txt expects a different manifest.json hash than on disk." -ForegroundColor Red
    } else {
      Write-Host "OK: manifest.json hash matches sha256sums.txt" -ForegroundColor Green
    }
  }
}
