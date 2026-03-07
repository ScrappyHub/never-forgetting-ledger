#requires -Version 7.0
[CmdletBinding()]
param(
  [string]$RunsDir = ".\runs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "00_env.ps1")

function Get-LatestRunDir([string]$Base) {
  if (-not (Test-Path -LiteralPath $Base)) { throw "Runs directory not found: $Base" }

  $latest = Get-ChildItem -LiteralPath $Base -Directory |
    Sort-Object Name -Descending |
    Select-Object -First 1

  if (-not $latest) { throw "No YYYYMMDD run folder found under: $Base" }

  $latestRun = Get-ChildItem -LiteralPath $latest.FullName -Directory |
    Sort-Object Name -Descending |
    Select-Object -First 1

  if (-not $latestRun) { throw "No eval_* run bundle found under: $($latest.FullName)" }

  return $latestRun.FullName
}

$runDir = Get-LatestRunDir -Base $RunsDir

$proposalPath = Join-Path $runDir "proposal.json"
if (-not (Test-Path -LiteralPath $proposalPath)) { throw "Missing proposal.json in: $runDir" }

$proposalObj = Get-Content -LiteralPath $proposalPath -Raw | ConvertFrom-Json

$bodyObj = @{
  p_policy_version_id = $global:POLICY_VERSION_ID
  p_proposal          = $proposalObj
}

$jsonBody = ($bodyObj | ConvertTo-Json -Depth 50)

$resp = Invoke-RestMethod `
  -Method Post `
  -Uri $global:GI_PPI_RPC_EVALUATE_URI `
  -Headers $global:GI_PPI_HEADERS `
  -Body $jsonBody

# Compare hashes (must match if policy + proposal identical)
$result = @{
  run_dir                = $runDir
  proposal_hash_replayed  = $resp.proposal_hash
  decision_replayed       = $resp.decision
  reason_codes_replayed   = $resp.reason_codes
}

$result | ConvertTo-Json -Depth 20
