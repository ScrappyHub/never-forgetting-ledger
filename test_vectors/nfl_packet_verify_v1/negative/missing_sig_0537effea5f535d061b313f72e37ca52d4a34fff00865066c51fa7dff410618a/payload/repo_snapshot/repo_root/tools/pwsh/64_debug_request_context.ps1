#requires -Version 7.0
[CmdletBinding()]
param([switch]$UseServiceRole)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:GI_PPI_TRANSCRIPT_PATH) {
  Start-Transcript -LiteralPath $env:GI_PPI_TRANSCRIPT_PATH -Append | Out-Null
  $script:__TRANSCRIBING = $true
}

try {
  . (Join-Path $PSScriptRoot "00_env.ps1")
  . (Join-Path $PSScriptRoot "05_http.ps1")

  $headers = if ($UseServiceRole) { GI_PPI_NewServiceHeaders } else { GI_PPI_NewAnonHeaders }

  Write-Verbose ("DEBUG_REQUEST_CONTEXT: uri={0} use_service_role={1}" -f $global:GI_PPI_RPC_DEBUG_REQUEST_CONTEXT_URI, [bool]$UseServiceRole)

  $r = Invoke-GiPpiJson -Uri $global:GI_PPI_RPC_DEBUG_REQUEST_CONTEXT_URI -Headers $headers -JsonBody "{}" -Method "POST" -Verbose:$VerbosePreference

  if ($null -eq $r) { Write-Output "DEBUG_CONTEXT_OK: null_response"; exit 0 }

  if ($r -is [System.Array]) {
    if ($r.Count -gt 0) { Write-Output ("DEBUG_CONTEXT_OK: {0}" -f ($r[0] | ConvertTo-Json -Depth 50 -Compress)); exit 0 }
    Write-Output "DEBUG_CONTEXT_OK: empty_array"; exit 0
  }

  Write-Output ("DEBUG_CONTEXT_OK: {0}" -f ($r | ConvertTo-Json -Depth 50 -Compress))
  exit 0
}
finally {
  if ($script:__TRANSCRIBING) { Stop-Transcript | Out-Null }
}
