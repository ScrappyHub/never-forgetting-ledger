#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$OrgId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "05_http.ps1")
. (Join-Path $PSScriptRoot "00_env.ps1")

if ([string]::IsNullOrWhiteSpace($global:GI_PPI_RPC_EVAL_WITH_CREDITS_URI)) { throw "ENV_MISSING: GI_PPI_RPC_EVAL_WITH_CREDITS_URI" }
if ($null -eq $global:GI_PPI_HEADERS_SERVICE) { throw "ENV_MISSING: GI_PPI_HEADERS_SERVICE" }
if ([string]::IsNullOrWhiteSpace($global:POLICY_VERSION_ID)) { throw "ENV_MISSING: POLICY_VERSION_ID" }
if ([string]::IsNullOrWhiteSpace($global:GI_PPI_OPERATOR_USER_ID)) { throw "ENV_MISSING: GI_PPI_OPERATOR_USER_ID" }

$proposalObj = @{
  schema_version = "GI_PPI_PROPOSAL_V0"
  action         = "REQUEST_EXECUTION"
  resource       = "compute"
  intent         = "run_task"
  inputs         = @{ task_type = "deterministic_transform" }
  attestations   = @{
    no_network       = $true
    no_external_data = $true
    deterministic    = $true
  }
}

$bodyObj = @{
  p_policy_version_id = $global:POLICY_VERSION_ID
  p_org_id            = $OrgId
  p_proposal          = $proposalObj
  p_operator_user_id  = $global:GI_PPI_OPERATOR_USER_ID
}

$jsonBody = ($bodyObj | ConvertTo-Json -Depth 50)

Invoke-GiPpiJson -Uri $global:GI_PPI_RPC_EVAL_WITH_CREDITS_URI -Headers $global:GI_PPI_HEADERS_SERVICE -JsonBody $jsonBody
