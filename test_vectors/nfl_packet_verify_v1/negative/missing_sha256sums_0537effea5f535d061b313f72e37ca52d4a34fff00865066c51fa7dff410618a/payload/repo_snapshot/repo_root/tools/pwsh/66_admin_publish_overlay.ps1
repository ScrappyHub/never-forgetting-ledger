#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][Guid]$OrgId,
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$OverlayPath,
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][Guid]$OperatorUserId
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

  if (-not (Test-Path -LiteralPath $OverlayPath)) { throw "OVERLAY_FILE_MISSING: $OverlayPath" }

  $overlayText = Get-Content -Raw -LiteralPath $OverlayPath -Encoding UTF8
  try { $overlayObj = $overlayText | ConvertFrom-Json } catch { throw "OVERLAY_JSON_INVALID: $($_.Exception.Message)" }

  $schemaVersion = $overlayObj.schema_version
  if ([string]::IsNullOrWhiteSpace($schemaVersion)) { throw "OVERLAY_SCHEMA_VERSION_REQUIRED" }
  if ($schemaVersion -ne "GI_PPI_OVERLAY_V0") { throw "OVERLAY_SCHEMA_VERSION_INVALID: got=$schemaVersion expected=GI_PPI_OVERLAY_V0" }

  $headers = GI_PPI_NewServiceHeaders

  $bodyObj = @{
    p_org_id           = $OrgId
    p_overlay          = $overlayObj
    p_operator_user_id = $OperatorUserId
  }
  $bodyJson = $bodyObj | ConvertTo-Json -Depth 200 -Compress

  Write-Verbose "GI_PPI_ADMIN_PUBLISH_OVERLAY:"
  Write-Verbose ("  uri={0}" -f $global:GI_PPI_RPC_ADMIN_PUBLISH_OVERLAY_URI)
  Write-Verbose ("  org_id={0}" -f $OrgId)
  Write-Verbose ("  operator_user_id={0}" -f $OperatorUserId)
  Write-Verbose ("  overlay_path={0}" -f $OverlayPath)
  Write-Verbose ("  overlay_schema_version={0}" -f $schemaVersion)

  $r = Invoke-GiPpiJson -Uri $global:GI_PPI_RPC_ADMIN_PUBLISH_OVERLAY_URI -Headers $headers -JsonBody $bodyJson -Method "POST" -Verbose:$VerbosePreference

  if ($null -eq $r) { Write-Output "PUBLISH_OK: null_response"; exit 0 }
  if ($r -is [System.Array]) {
    if ($r.Count -gt 0) { Write-Output ("PUBLISH_OK: {0}" -f ($r[0] | ConvertTo-Json -Depth 50 -Compress)); exit 0 }
    Write-Output "PUBLISH_OK: empty_array"; exit 0
  }
  Write-Output ("PUBLISH_OK: {0}" -f ($r | ConvertTo-Json -Depth 50 -Compress))
  exit 0
}
finally {
  if ($script:__TRANSCRIBING) { Stop-Transcript | Out-Null }
}
