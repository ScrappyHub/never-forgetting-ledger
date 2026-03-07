#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory)][Guid]$OrgId,
  [Parameter(Mandatory)][string]$AccessToken,
  [Parameter(Mandatory)][Guid]$OperatorUserId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ($env:GI_PPI_TRANSCRIPT_PATH) {
  Start-Transcript -LiteralPath $env:GI_PPI_TRANSCRIPT_PATH -Append | Out-Null
  $script:__TRANSCRIBING = $true
}

try {
  . (Join-Path $PSScriptRoot "00_env.ps1")
  . (Join-Path $PSScriptRoot "05_http.ps1")

  $headers = GI_PPI_NewUserHeaders -AccessToken $AccessToken

  $proposal = @{ schema_version = "GI_PPI_PROPOSAL_V0" }

  $body = @{
    p_policy_version_id = $global:POLICY_VERSION_ID
    p_org_id            = $OrgId
    p_proposal          = $proposal
    p_operator_user_id  = $OperatorUserId
  } | ConvertTo-Json -Depth 50 -Compress

  $resp = Invoke-GiPpiJson `
    -Uri $global:GI_PPI_RPC_EVAL_WITH_CREDITS_AND_OVERLAY_URI `
    -Headers $headers `
    -JsonBody $body `
    -Method POST `
    -Verbose:$VerbosePreference

  if ($resp -is [array] -and $resp.Count -gt 0) {
    Write-Output ($resp[0] | ConvertTo-Json -Depth 50 -Compress)
  } else {
    Write-Output ($resp | ConvertTo-Json -Depth 50 -Compress)
  }
}
finally {
  if ($script:__TRANSCRIBING) { Stop-Transcript | Out-Null }
}
