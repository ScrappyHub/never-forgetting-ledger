#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$UserId,
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$NewPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "05_http.ps1")
. (Join-Path $PSScriptRoot "00_env.ps1")

# Basic password floor (instrument-grade minimum)
if ($NewPassword.Length -lt 12) { throw "WEAK_PASSWORD: require >= 12 chars" }

$uri = "$($global:SUPABASE_URL)/auth/v1/admin/users/$UserId"

$json = (@{
  password = $NewPassword
} | ConvertTo-Json -Depth 10)

Invoke-GiPpiJson -Uri $uri -Headers $global:GI_PPI_HEADERS_SERVICE -JsonBody $json
