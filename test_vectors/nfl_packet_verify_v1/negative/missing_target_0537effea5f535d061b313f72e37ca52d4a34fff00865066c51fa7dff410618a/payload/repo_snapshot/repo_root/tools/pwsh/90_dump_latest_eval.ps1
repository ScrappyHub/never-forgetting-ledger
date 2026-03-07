#requires -Version 7.0
[CmdletBinding()]
param(
  [int]$Limit = 10
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "00_env.ps1")

function Assert-NotBlank([string]$Name, [object]$Value) {
  if ($null -eq $Value) { throw "ENV_MISSING: $Name is null" }
  $s = [string]$Value
  if ([string]::IsNullOrWhiteSpace($s)) { throw "ENV_MISSING: $Name is blank" }
}

Assert-NotBlank "SUPABASE_URL" $global:SUPABASE_URL
Assert-NotBlank "SUPABASE_KEY" $global:SUPABASE_KEY
Assert-NotBlank "POLICY_VERSION_ID" $global:POLICY_VERSION_ID

if ($null -eq $global:GI_PPI_HEADERS) {
  throw "ENV_MISSING: GI_PPI_HEADERS is null"
}

if ($Limit -lt 1 -or $Limit -gt 200) {
  throw "INVALID_ARG: Limit must be between 1 and 200"
}

$base = $global:SUPABASE_URL.TrimEnd("/")
$select = "evaluation_id,policy_version_id,proposal_hash,decision,reason_codes,created_at,policy_hash_sha256"
$uri = "$base/rest/v1/governance_evaluations?select=$select&policy_version_id=eq.$($global:POLICY_VERSION_ID)&order=created_at.desc&limit=$Limit"

try {
  Invoke-RestMethod -Method Get -Uri $uri -Headers $global:GI_PPI_HEADERS
} catch {
  $r = $_.Exception.Response
  if ($null -ne $r) {
    $reader = New-Object System.IO.StreamReader($r.GetResponseStream())
    $msg = $reader.ReadToEnd()
    throw ("DUMP_FAILED: {0}`n{1}" -f $_.Exception.Message, $msg)
  }
  throw
}
