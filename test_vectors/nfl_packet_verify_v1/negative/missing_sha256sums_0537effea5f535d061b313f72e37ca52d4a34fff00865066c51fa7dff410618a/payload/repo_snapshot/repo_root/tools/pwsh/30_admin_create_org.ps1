#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$OrgSlug,
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$OrgName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "05_http.ps1")
. (Join-Path $PSScriptRoot "00_env.ps1")

$bodyObj = @{
  p_org_slug          = $OrgSlug
  p_org_name          = $OrgName
  p_operator_user_id  = $global:GI_PPI_OPERATOR_USER_ID
}

$jsonBody = ($bodyObj | ConvertTo-Json -Depth 20)

Invoke-GiPpiJson -Uri $global:GI_PPI_RPC_ADMIN_CREATE_ORG_URI -Headers $global:GI_PPI_HEADERS_SERVICE -JsonBody $jsonBody
