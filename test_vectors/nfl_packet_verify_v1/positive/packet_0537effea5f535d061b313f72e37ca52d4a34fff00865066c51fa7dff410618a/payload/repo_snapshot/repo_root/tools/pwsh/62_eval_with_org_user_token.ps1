#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$OrgId,
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$AccessToken,
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$OperatorUserId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "05_http.ps1")
. (Join-Path $PSScriptRoot "00_env.ps1")

# user token headers (AUTHENTICATED USER)
$headersUser = @{
  "apikey"        = $global:SUPABASE_ANON_KEY
  "Authorization" = "Bearer $AccessToken"
  "Content-Type"  = "application/json"
}

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
  p_operator_user_id  = $OperatorUserId
}

$jsonBody = ($bodyObj | ConvertTo-Json -Depth 50)

Invoke-GiPpiJson -Uri $global:GI_PPI_RPC_EVAL_WITH_CREDITS_URI -Headers $headersUser -JsonBody $jsonBody
