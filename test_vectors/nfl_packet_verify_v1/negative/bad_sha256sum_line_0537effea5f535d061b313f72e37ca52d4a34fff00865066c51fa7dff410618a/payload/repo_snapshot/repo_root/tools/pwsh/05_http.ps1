#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-GiPpiJson {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Uri,
    [Parameter(Mandatory)][hashtable]$Headers,
    [Parameter(Mandatory)][string]$JsonBody,
    [ValidateSet("GET","POST","PUT","PATCH","DELETE")]
    [string]$Method = "POST"
  )

  Write-Verbose "GI_PPI_HTTP $Method $Uri"

  $resp = Invoke-WebRequest `
    -Uri $Uri `
    -Method $Method `
    -Headers $Headers `
    -Body $JsonBody `
    -ContentType "application/json" `
    -SkipHttpErrorCheck

  $status = [int]$resp.StatusCode
  $raw = [string]$resp.Content

  if ($status -lt 200 -or $status -ge 300) {
    throw "GI_PPI_HTTP_FAILED: HTTP $status`n$raw"
  }

  if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
  try { return $raw | ConvertFrom-Json } catch { return $raw }
}

function GI_PPI_NewUserHeaders {
  param([Parameter(Mandatory)][string]$AccessToken)

  @{
    "apikey"        = $env:SUPABASE_PUBLISHABLE_KEY
    "Authorization" = "Bearer $AccessToken"
    "Content-Type"  = "application/json"
  }
}

function GI_PPI_NewAdminHeaders {
  @{
    "apikey"        = $env:SUPABASE_SECRET_KEY
    "Authorization" = "Bearer $env:SUPABASE_SECRET_KEY"
    "Content-Type"  = "application/json"
  }
}
