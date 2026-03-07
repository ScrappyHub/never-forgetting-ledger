param([Parameter(Mandatory=$true)][string]$ConfigPath)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $norm = ($Text -replace "`r`n","`n" -replace "`r","`n")
  if (-not $norm.EndsWith("`n")) { $norm += "`n" }
  [System.IO.File]::WriteAllText($Path,$norm,$enc)
}
function CanonJson([object]$o,[int]$depth=20){ return ($o | ConvertTo-Json -Depth $depth -Compress) }

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw ("Missing config: " + $ConfigPath) }
$raw = Get-Content -Raw -LiteralPath $ConfigPath -Encoding UTF8
$cfg = $raw | ConvertFrom-Json
if ($null -eq $cfg.watches) { $cfg | Add-Member -NotePropertyName watches -NotePropertyValue @() -Force }
$cfg.watches = @(@($cfg.watches))

function AddWatch([string]$name,[string]$repoRoot){
  $pk = Join-Path $repoRoot "packets"
  $out = Join-Path $pk "outbox"
  $inb = Join-Path $pk "inbox"
  $qua = Join-Path $pk "quarantine"
  if (-not (Test-Path -LiteralPath $repoRoot -PathType Container)) { Write-Host ("SKIP (missing repo): " + $repoRoot) -ForegroundColor DarkYellow; return }
  foreach($d in @($out,$inb,$qua)){ if (-not (Test-Path -LiteralPath $d -PathType Container)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
  $exists = $false
  foreach($w in @(@($cfg.watches))){
    if ($null -ne $w -and ([string]$w.name).ToLowerInvariant() -eq $name.ToLowerInvariant()) { $exists = $true }
  }
  if ($exists) { Write-Host ("KEEP (already): " + $name) -ForegroundColor DarkGray; return }
  $obj = [pscustomobject]@{ name=$name; outbox=$out; inbox=$inb; quarantine=$qua }
  $cfg.watches = @(@($cfg.watches) + @($obj))
  Write-Host ("ADD: " + $name + " => " + $out) -ForegroundColor Green
}

# --- add canonical repos here ---
AddWatch "nfl"            "C:\dev\nfl"
AddWatch "watchtower"      "C:\dev\watchtower"
AddWatch "echo-transport"  "C:\dev\echo-transport"
AddWatch "packetpuncture"  "C:\dev\packetpuncture"
AddWatch "runledger"       "C:\dev\runledger"
AddWatch "toolbelt"        "C:\dev\toolbelt"
AddWatch "triad"           "C:\dev\triad"
AddWatch "core-platform"   "C:\dev\core-platform"
AddWatch "clarity"         "C:\dev\clarity"
AddWatch "contract-registry" "C:\dev\contract-registry"
AddWatch "gos-runtime"     "C:\dev\gos-runtime"
AddWatch "neverlost"       "C:\dev\neverlost"

$json = CanonJson $cfg 50
Write-Utf8NoBomLf -Path $ConfigPath -Text $json
Write-Host ("WROTE_CONFIG: " + $ConfigPath) -ForegroundColor Green
