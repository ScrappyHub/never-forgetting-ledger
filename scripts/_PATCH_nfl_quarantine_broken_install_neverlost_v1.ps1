param([Parameter(Mandatory=$true)][string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}

$RepoRoot   = (Resolve-Path -LiteralPath $RepoRoot).Path
$ScriptsDir = Join-Path $RepoRoot "scripts"
if(-not (Test-Path -LiteralPath $ScriptsDir -PathType Container)){ throw ("MISSING_SCRIPTS_DIR: " + $ScriptsDir) }

$Bad = Join-Path $ScriptsDir "_install_neverlost_v1_nfl.ps1"
if(-not (Test-Path -LiteralPath $Bad -PathType Leaf)){
  Write-Output ("NOOP: missing " + $Bad)
  Write-Output "PATCH_OK"
  exit 0
}

$QRoot = Join-Path (Join-Path $ScriptsDir "_scratch") "quarantine"
EnsureDir $QRoot

$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$Dest  = Join-Path $QRoot ("_install_neverlost_v1_nfl.BAD_" + $stamp + ".ps1")

Move-Item -LiteralPath $Bad -Destination $Dest -Force

Write-Output ("QUARANTINED: " + $Bad)
Write-Output ("TO: " + $Dest)
Write-Output "PATCH_OK"
