#requires -Version 7.0
[CmdletBinding()]
param(
  [string]$OutDir = ".\runs"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "00_env.ps1")

function Assert-NotBlank([string]$Name, [object]$Value) {
  if ($null -eq $Value) { throw "ENV_MISSING: $Name is null" }
  $s = [string]$Value
  if ([string]::IsNullOrWhiteSpace($s)) { throw "ENV_MISSING: $Name is blank" }
}

function New-RunId { ([guid]::NewGuid().ToString()) }

function Now-Stamp { (Get-Date).ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'") }

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -ItemType Directory -Path $Path | Out-Null
  }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

function Get-Json([object]$Obj, [int]$Depth = 50) {
  return ($Obj | ConvertTo-Json -Depth $Depth -Compress:$false)
}

# ---- ENV REQUIRED (canonical hard gates) ----
Assert-NotBlank "SUPABASE_URL" $global:SUPABASE_URL
Assert-NotBlank "SUPABASE_KEY" $global:SUPABASE_KEY
Assert-NotBlank "POLICY_VERSION_ID" $global:POLICY_VERSION_ID
Assert-NotBlank "GI_PPI_RPC_EVALUATE_URI" $global:GI_PPI_RPC_EVALUATE_URI

if ($null -eq $global:GI_PPI_HEADERS) {
  throw "ENV_MISSING: GI_PPI_HEADERS is null"
}

# ---- Proposal (GI/PPI only; no external system names) ----
$proposalObj = @{
  schema_version = "GI_PPI_PROPOSAL_V0"
  action         = "REQUEST_EXECUTION"
  resource       = "compute"
  intent         = "run_task"
  inputs         = @{
    task_type = "deterministic_transform"
  }
  attestations   = @{
    no_network       = $true
    no_external_data = $true
    deterministic    = $true
  }
}

$bodyObj = @{
  p_policy_version_id = $global:POLICY_VERSION_ID
  p_proposal          = $proposalObj
}

# IMPORTANT: $jsonBody must be valid JSON object, not a JSON string inside JSON
$jsonBody = Get-Json $bodyObj 50

# ---- Call RPC ----
$resp = $null
try {
  $resp = Invoke-RestMethod `
    -Method Post `
    -Uri $global:GI_PPI_RPC_EVALUATE_URI `
    -Headers $global:GI_PPI_HEADERS `
    -Body $jsonBody
} catch {
  $r = $_.Exception.Response
  if ($null -ne $r) {
    $reader = New-Object System.IO.StreamReader($r.GetResponseStream())
    $msg = $reader.ReadToEnd()
    throw ("RPC_FAILED: {0}`n{1}" -f $_.Exception.Message, $msg)
  }
  throw
}

# ---- Response sanity (do not write incomplete bundles) ----
if ($null -eq $resp) { throw "RPC_FAILED: response is null" }

$requiredFields = @("evaluation_id","proposal_hash","decision","reason_codes")
foreach ($f in $requiredFields) {
  if ($null -eq $resp.$f) {
    throw ("RPC_RESPONSE_INVALID: missing field '{0}'" -f $f)
  }
}

# ---- Write run bundle (local, append-only) ----
$runId  = New-RunId
$stamp  = Now-Stamp
$dayDir = Join-Path $OutDir (Get-Date).ToUniversalTime().ToString("yyyyMMdd")
$runDir = Join-Path $dayDir ("eval_{0}_{1}" -f $stamp, $runId)

Ensure-Dir $OutDir
Ensure-Dir $dayDir
Ensure-Dir $runDir

$pathProposal = Join-Path $runDir "proposal.json"
$pathReq      = Join-Path $runDir "rpc_request.json"
$pathResp     = Join-Path $runDir "rpc_response.json"
$pathSummary  = Join-Path $runDir "summary.json"

Write-Utf8NoBom $pathProposal (Get-Json $proposalObj 50)
Write-Utf8NoBom $pathReq      $jsonBody
Write-Utf8NoBom $pathResp     (Get-Json $resp 50)

$summaryObj = @{
  run_id            = $runId
  created_at_utc    = $stamp
  policy_version_id = $global:POLICY_VERSION_ID
  decision          = $resp.decision
  reason_codes      = $resp.reason_codes
  proposal_hash     = $resp.proposal_hash
  evaluation_id     = $resp.evaluation_id
}

Write-Utf8NoBom $pathSummary (Get-Json $summaryObj 20)

# ---- Runs Contract enforcement (V0) ----
$required = @($pathProposal, $pathReq, $pathResp, $pathSummary)
$missing = @()
foreach ($p in $required) {
  if (-not (Test-Path -LiteralPath $p)) { $missing += $p }
}
if ($missing.Count -gt 0) {
  throw ("RUNS_CONTRACT_V0_VIOLATION: missing required files:`n" + ($missing -join "`n"))
}

# ---- Output: show result + run dir for audit trail ----
[pscustomobject]@{
  evaluation_id = $resp.evaluation_id
  proposal_hash = $resp.proposal_hash
  decision      = $resp.decision
  reason_codes  = $resp.reason_codes
  diagnostics   = $resp.diagnostics
  run_dir       = $runDir
}
