#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$OrgId,
  [Parameter(Mandatory=$true)][long]$DeltaCredits,
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Reason
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "05_http.ps1")
. (Join-Path $PSScriptRoot "00_env.ps1")

$bodyObj = @{
  p_org_id            = $OrgId
  p_delta_credits     = $DeltaCredits
  p_reason            = $Reason
  p_operator_user_id  = $global:GI_PPI_OPERATOR_USER_ID
}

$jsonBody = ($bodyObj | ConvertTo-Json -Depth 20)

Invoke-GiPpiJson -Uri $global:GI_PPI_RPC_ADMIN_GRANT_CREDITS_URI -Headers $global:GI_PPI_HEADERS_SERVICE -JsonBody $jsonBody
