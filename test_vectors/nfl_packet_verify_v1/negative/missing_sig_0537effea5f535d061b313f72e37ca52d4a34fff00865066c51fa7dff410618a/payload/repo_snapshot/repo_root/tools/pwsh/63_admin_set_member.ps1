#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$OrgId,
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$UserId,
  [Parameter(Mandatory=$true)][ValidateSet("owner","admin","member")][string]$Role,
  [Parameter(Mandatory=$true)][ValidateSet("active","invited","disabled")][string]$Status
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "05_http.ps1")
. (Join-Path $PSScriptRoot "00_env.ps1")

function Assert-Guid([string]$Name, [string]$Value) {
  try { [void][guid]::Parse($Value) }
  catch { throw "INVALID_UUID: $Name=$Value" }
}

function Assert-NotBlank([string]$Name, [object]$Value) {
  if ($null -eq $Value) { throw "ENV_MISSING: $Name is null" }
  $s = [string]$Value
  if ([string]::IsNullOrWhiteSpace($s)) { throw "ENV_MISSING: $Name is blank" }
}

Assert-Guid "OrgId" $OrgId
Assert-Guid "UserId" $UserId
Assert-Guid "GI_PPI_OPERATOR_USER_ID" $global:GI_PPI_OPERATOR_USER_ID

Assert-NotBlank "GI_PPI_RPC_ADMIN_SET_MEMBER_URI" $global:GI_PPI_RPC_ADMIN_SET_MEMBER_URI
if ($null -eq $global:GI_PPI_HEADERS_SERVICE) { throw "ENV_MISSING: GI_PPI_HEADERS_SERVICE is null" }

$bodyObj = @{
  p_org_id            = $OrgId
  p_user_id           = $UserId
  p_role              = $Role
  p_status            = $Status
  p_operator_user_id  = $global:GI_PPI_OPERATOR_USER_ID
}

$jsonBody = ($bodyObj | ConvertTo-Json -Depth 20)

Invoke-GiPpiJson -Uri $global:GI_PPI_RPC_ADMIN_SET_MEMBER_URI -Headers $global:GI_PPI_HEADERS_SERVICE -JsonBody $jsonBody

# Return a canonical operator-facing confirmation object (stdout)
[pscustomobject]@{
  ok               = $true
  org_id           = $OrgId
  user_id          = $UserId
  role             = $Role
  status           = $Status
  operator_user_id = $global:GI_PPI_OPERATOR_USER_ID
}
