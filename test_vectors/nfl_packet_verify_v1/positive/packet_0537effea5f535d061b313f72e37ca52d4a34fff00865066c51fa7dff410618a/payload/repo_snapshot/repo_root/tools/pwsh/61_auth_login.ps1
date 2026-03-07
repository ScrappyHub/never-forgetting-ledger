#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Email,
  [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# deterministic transcript support
if ($env:GI_PPI_TRANSCRIPT_PATH) {
  Start-Transcript -LiteralPath $env:GI_PPI_TRANSCRIPT_PATH -Append | Out-Null
  $script:__TRANSCRIBING = $true
}

try {
  . (Join-Path $PSScriptRoot "00_env.ps1")
  . (Join-Path $PSScriptRoot "05_http.ps1")

  if (-not $env:SUPABASE_PUBLISHABLE_KEY) {
    throw "ENV_MISSING: SUPABASE_PUBLISHABLE_KEY"
  }

  $password = Read-Host -AsSecureString "Password"
  $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
  )

  $uri = "$global:SUPABASE_URL/auth/v1/token?grant_type=password"

  $headers = @{
    "apikey"       = $env:SUPABASE_PUBLISHABLE_KEY
    "Content-Type" = "application/json"
  }

  $body = @{
    email    = $Email
    password = $plain
  } | ConvertTo-Json -Compress

  $resp = Invoke-GiPpiJson `
    -Uri $uri `
    -Headers $headers `
    -JsonBody $body `
    -Method POST

  if ($Json) {
    $resp | ConvertTo-Json -Depth 50
  } else {
    $resp
  }
}
finally {
  if ($script:__TRANSCRIBING) { Stop-Transcript | Out-Null }
}
