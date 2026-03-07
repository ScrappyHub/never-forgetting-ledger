# tools/pwsh/30_export_audit_bundle.ps1
# Exports audit bundle JSON to runs/<YYYYMMDD>/audit_<timestamp>_<policy>_<page>.json
# Then SHA256 hashes the file and writes a .sha256 sidecar.

[CmdletBinding()]
param(
  [int]$Limit = 500,
  [int]$Offset = 0
)

. "$PSScriptRoot/00_env.ps1"

if (-not $script:SUPABASE_URL) { throw "SUPABASE_URL missing" }
if (-not $script:SUPABASE_KEY) { throw "SUPABASE_KEY missing" }
if (-not $script:POLICY_VERSION_ID) { throw "POLICY_VERSION_ID missing" }

$headers = @{
  "apikey"        = $script:SUPABASE_KEY
  "Authorization" = "Bearer $($script:SUPABASE_KEY)"
  "Content-Type"  = "application/json"
}

$bodyObj = @{
  p_policy_version_id = $script:POLICY_VERSION_ID
  p_limit             = $Limit
  p_offset            = $Offset
}

$uri = "$($script:SUPABASE_URL)/rest/v1/rpc/export_audit_bundle"

$resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body ($bodyObj | ConvertTo-Json -Depth 50)

$day = (Get-Date).ToString("yyyyMMdd")
$ts  = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$runDir = Join-Path $PSScriptRoot "..\..\runs\$day"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$outPath = Join-Path $runDir ("audit_{0}_{1}_limit{2}_offset{3}.json" -f $ts, $script:POLICY_VERSION_ID, $Limit, $Offset)
$resp | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $outPath -Encoding UTF8

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $outPath).Hash.ToLowerInvariant()
$shaPath = "$outPath.sha256"
Set-Content -LiteralPath $shaPath -Value $hash -Encoding ASCII

[pscustomobject]@{
  run_dir    = (Resolve-Path $runDir).Path
  output     = (Resolve-Path $outPath).Path
  sha256     = $hash
  limit      = $Limit
  offset     = $Offset
}
