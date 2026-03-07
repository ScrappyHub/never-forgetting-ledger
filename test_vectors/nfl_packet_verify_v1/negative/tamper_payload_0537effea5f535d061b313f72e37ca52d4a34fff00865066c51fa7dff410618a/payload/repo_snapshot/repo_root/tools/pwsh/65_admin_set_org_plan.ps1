#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$OrgId,
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$PlanCode,

  # USER JWT (not service role)
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$AccessToken,

  # must match the JWT subject (auth.uid) for operator console flows
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$OperatorUserId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "00_env.ps1")
. (Join-Path $PSScriptRoot "05_http.ps1")

function New-UserAuthHeaders {
  param([string]$Jwt)
  return @{
    "apikey"        = $global:SUPABASE_ANON_KEY
    "Authorization" = "Bearer $Jwt"
    "Content-Type"  = "application/json"
  }
}

# --- Build request ---
$headersUser = New-UserAuthHeaders -Jwt $AccessToken

$bodyObj = @{
  p_org_id           = $OrgId
  p_plan_code        = $PlanCode
  p_operator_user_id = $OperatorUserId
}

$jsonBody = ($bodyObj | ConvertTo-Json -Depth 30)

Write-Verbose ("GI_PPI_ADMIN_SET_ORG_PLAN: org_id={0} plan_code={1} operator_user_id={2}" -f $OrgId, $PlanCode, $OperatorUserId)
Write-Verbose ("GI_PPI_HTTP: POST {0}" -f $global:GI_PPI_RPC_ADMIN_SET_ORG_PLAN_URI)

Invoke-GiPpiJson -Uri $global:GI_PPI_RPC_ADMIN_SET_ORG_PLAN_URI -Headers $headersUser -JsonBody $jsonBody
