param(
  [Parameter(Mandatory=$true)][string]$InstallerPath,
  [Parameter(Mandatory=$true)][string]$Version,
  [Parameter(Mandatory=$false)][string]$ArtifactKey = "work-engine-windows",
  [Parameter(Mandatory=$false)][string]$BucketId    = "work-engines",
  [Parameter(Mandatory=$false)][string]$ObjectPath  = "windows/WorkEngine-Setup.exe",
  [Parameter(Mandatory=$true)][string]$OrgId,
  [Parameter(Mandatory=$true)][string]$UserId,
  [Parameter(Mandatory=$false)][int]$ExpiresInSeconds = 300
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

# AUTOLOAD_ENV_FILE_V2
function LoadEnvFile([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  foreach ($ln in (Get-Content -LiteralPath $path)) {
    $s = $ln.Trim()
    if ($s.Length -eq 0) { continue }
    if ($s.StartsWith("#")) { continue }
    $idx = $s.IndexOf("=")
    if ($idx -lt 1) { continue }
    $k = $s.Substring(0, $idx).Trim()
    $v = $s.Substring($idx + 1).Trim()
    if ($k.Length -eq 0) { continue }
    [Environment]::SetEnvironmentVariable($k, $v, "Process")
  }
  return $true
}

function PullUserToProcess([string]$k) {
  if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($k,"Process"))) {
    $uv = [Environment]::GetEnvironmentVariable($k,"User")
    if (-not [string]::IsNullOrWhiteSpace($uv)) {
      [Environment]::SetEnvironmentVariable($k,$uv,"Process")
    }
  }
}

$SecretsEnv = Join-Path (Split-Path -Parent $PSScriptRoot) ".secrets\gi-ppi.env"
LoadEnvFile $SecretsEnv | Out-Null

foreach ($k in @("SUPABASE_URL","SUPABASE_SERVICE_ROLE_KEY","GI_PPI_WEBHOOK_INTERNAL_SECRET")) {
  PullUserToProcess $k
}

# Derive SUPABASE_URL deterministically if still missing
if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("SUPABASE_URL","Process"))) {
  [Environment]::SetEnvironmentVariable("SUPABASE_URL", "https://hmlihkcijjamxdurydbv.supabase.co", "Process")
}

# Final assert (single hard fail)
$missing = @()
foreach ($k in @("SUPABASE_URL","SUPABASE_SERVICE_ROLE_KEY","GI_PPI_WEBHOOK_INTERNAL_SECRET")) {
  if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($k,"Process"))) { $missing += $k }
}
if ($missing.Count -gt 0) { throw ("Missing required env vars after autoload: " + ($missing -join ", ")) }

# AUTOLOAD_ENV_FILE_V1
function LoadEnvFile([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  foreach ($ln in (Get-Content -LiteralPath $path)) {
    $s = $ln.Trim()
    if ($s.Length -eq 0) { continue }
    if ($s.StartsWith("#")) { continue }
    $idx = $s.IndexOf("=")
    if ($idx -lt 1) { continue }
    $k = $s.Substring(0, $idx).Trim()
    $v = $s.Substring($idx + 1).Trim()
    if ($k.Length -eq 0) { continue }
    [Environment]::SetEnvironmentVariable($k, $v, "Process")
  }
  return $true
}

$SecretsEnv = Join-Path (Split-Path -Parent $PSScriptRoot) ".secrets\gi-ppi.env"
LoadEnvFile $SecretsEnv | Out-Null

# Derive SUPABASE_URL deterministically if still missing
if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("SUPABASE_URL","Process"))) {
  [Environment]::SetEnvironmentVariable("SUPABASE_URL", ("https://hmlihkcijjamxdurydbv.supabase.co"), "Process")
}

function LoadEnvFile([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $false }
  $lines = Get-Content -LiteralPath $path
  foreach ($ln in $lines) {
    $s = $ln.Trim()
    if ($s.Length -eq 0) { continue }
    if ($s.StartsWith("#")) { continue }
    $idx = $s.IndexOf("=")
    if ($idx -lt 1) { continue }
    $k = $s.Substring(0, $idx).Trim()
    $v = $s.Substring($idx + 1).Trim()
    if ($k.Length -eq 0) { continue }
    [Environment]::SetEnvironmentVariable($k, $v, "Process")
  }
  return $true
}

# Auto-load secrets into this process if missing
$SecretsEnv = Join-Path (Split-Path -Parent $PSScriptRoot) ".secrets\gi-ppi.env"
if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("SUPABASE_URL")) -or
    [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("SUPABASE_SERVICE_ROLE_KEY")) -or
    [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable("GI_PPI_WEBHOOK_INTERNAL_SECRET"))) {
  LoadEnvFile $SecretsEnv | Out-Null
}

function Die([string]$m){ throw $m }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function MustEnv([string]$name){
  $v = [Environment]::GetEnvironmentVariable($name)
  if ([string]::IsNullOrWhiteSpace($v)) { Die ("Missing required env var: " + $name) }
  return $v
}
function J([object]$o){ return ($o | ConvertTo-Json -Depth 20) }

$SupabaseUrl = (MustEnv "SUPABASE_URL").TrimEnd("/")
$ServiceKey  = MustEnv "SUPABASE_SERVICE_ROLE_KEY"
$InternalSecret = MustEnv "GI_PPI_WEBHOOK_INTERNAL_SECRET"

if (-not (Test-Path -LiteralPath $InstallerPath)) { Die ("Installer not found: " + $InstallerPath) }
if ($ExpiresInSeconds -lt 60 -or $ExpiresInSeconds -gt 3600) { Die "ExpiresInSeconds must be 60..3600" }

$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$ProofRoot = Join-Path (Split-Path -Parent $PSScriptRoot) ("proof\publish_work_engine_windows_{0}" -f $stamp)
New-Item -ItemType Directory -Path $ProofRoot -Force | Out-Null

Write-Host "== PUBLISH WORK ENGINE (WINDOWS) ==" -ForegroundColor Cyan
Write-Host ("InstallerPath: {0}" -f $InstallerPath) -ForegroundColor Cyan
Write-Host ("ArtifactKey:    {0}" -f $ArtifactKey) -ForegroundColor Cyan
Write-Host ("BucketId:       {0}" -f $BucketId) -ForegroundColor Cyan
Write-Host ("ObjectPath:     {0}" -f $ObjectPath) -ForegroundColor Cyan
Write-Host ("Version:        {0}" -f $Version) -ForegroundColor Cyan
Write-Host ("OrgId/UserId:   {0} / {1}" -f $OrgId, $UserId) -ForegroundColor Cyan
Write-Host ("ProofRoot:      {0}" -f $ProofRoot) -ForegroundColor Cyan

# ------------------------------------------------------------------
# 1) Compute artifact truth (sha256 + size)
# ------------------------------------------------------------------
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $InstallerPath).Hash.ToLowerInvariant()
$size = (Get-Item -LiteralPath $InstallerPath).Length
$truth = [ordered]@{
  artifact_key = $ArtifactKey
  bucket_id    = $BucketId
  object_path  = $ObjectPath
  sha256       = $sha
  size_bytes   = [int64]$size
  version      = $Version
  platform     = "windows"
  computed_utc = (Get-Date).ToUniversalTime().ToString("o")
}
[IO.File]::WriteAllText((Join-Path $ProofRoot "truth.json"), (J $truth), (Utf8NoBom))
Write-Host ("TRUTH sha256={0} size={1}" -f $sha, $size) -ForegroundColor Green

# ------------------------------------------------------------------
# 2) Ensure bucket exists (idempotent) via Storage API
# ------------------------------------------------------------------
$headersAuth = @{ Authorization = ("Bearer " + $ServiceKey); apikey = $ServiceKey }
$bucketListUrl = ($SupabaseUrl + "/storage/v1/bucket")
$buckets = $null
try { $buckets = Invoke-RestMethod -Method Get -Uri $bucketListUrl -Headers $headersAuth } catch { $buckets = $null }
$exists = $false
if ($buckets) {
  foreach ($b in $buckets) { if ($b.id -eq $BucketId) { $exists = $true; break } }
}
if (-not $exists) {
  Write-Host ("Creating bucket: {0}" -f $BucketId) -ForegroundColor Yellow
  $createBody = @{ id = $BucketId; name = $BucketId; public = $false }
  $createUrl = ($SupabaseUrl + "/storage/v1/bucket")
  $resp = Invoke-RestMethod -Method Post -Uri $createUrl -Headers ($headersAuth + @{ "content-type"="application/json" }) -Body (J $createBody)
  [IO.File]::WriteAllText((Join-Path $ProofRoot "bucket_create_response.json"), (J $resp), (Utf8NoBom))
} else {
  Write-Host ("Bucket exists: {0}" -f $BucketId) -ForegroundColor DarkGray
}

# ------------------------------------------------------------------
# 3) Upload object (idempotent upsert) via Storage API
# ------------------------------------------------------------------
$uploadUrl = ($SupabaseUrl + "/storage/v1/object/" + $BucketId + "/" + $ObjectPath)
Write-Host ("Uploading -> {0}" -f $uploadUrl) -ForegroundColor Cyan
$uploadHeaders = $headersAuth + @{ "x-upsert"="true" }
$uploadResp = $null
try {
  $uploadResp = Invoke-RestMethod -Method Post -Uri $uploadUrl -Headers $uploadHeaders -InFile $InstallerPath -ContentType "application/octet-stream"
} catch {
  $e = $_
  [IO.File]::WriteAllText((Join-Path $ProofRoot "upload_error.txt"), ($e | Out-String), (Utf8NoBom))
  Die ("UPLOAD_FAILED: " + $e.Exception.Message)
}
[IO.File]::WriteAllText((Join-Path $ProofRoot "upload_response.json"), (J $uploadResp), (Utf8NoBom))
Write-Host "UPLOAD OK" -ForegroundColor Green

# ------------------------------------------------------------------
# 4) Register artifact row (upsert) via PostgREST
# ------------------------------------------------------------------
$restUrl = ($SupabaseUrl + "/rest/v1/gi_ppi_artifacts")
$regHeaders = $headersAuth + @{ "content-type"="application/json"; "Prefer"="resolution=merge-duplicates,return=representation" }
$row = @(@{
  artifact_key = $ArtifactKey
  bucket_id    = $BucketId
  object_path  = $ObjectPath
  sha256       = $sha
  size_bytes   = [int64]$size
  version      = $Version
  platform     = "windows"
})
Write-Host ("Registering artifact via PostgREST -> {0}" -f $restUrl) -ForegroundColor Cyan
$regResp = $null
try {
  $regResp = Invoke-RestMethod -Method Post -Uri $restUrl -Headers $regHeaders -Body (J $row)
} catch {
  $e = $_
  [IO.File]::WriteAllText((Join-Path $ProofRoot "register_error.txt"), ($e | Out-String), (Utf8NoBom))
  Die ("REGISTER_FAILED: " + $e.Exception.Message)
}
[IO.File]::WriteAllText((Join-Path $ProofRoot "register_response.json"), (J $regResp), (Utf8NoBom))
Write-Host "REGISTER OK" -ForegroundColor Green

# ------------------------------------------------------------------
# 5) Call download-url function (mint signed URL) and capture response
# ------------------------------------------------------------------
$fnUrl = ($SupabaseUrl + "/functions/v1/download-url")
$fnHeaders = @{ "content-type"="application/json"; "x-gi-ppi-secret"=$InternalSecret }
$fnBody = @{
  org_id = $OrgId
  user_id = $UserId
  artifact_key = $ArtifactKey
  expires_in_seconds = $ExpiresInSeconds
}
Write-Host ("Minting signed URL -> {0}" -f $fnUrl) -ForegroundColor Cyan
[IO.File]::WriteAllText((Join-Path $ProofRoot "download_url_request.json"), (J $fnBody), (Utf8NoBom))
$fnResp = $null
try {
  $fnResp = Invoke-RestMethod -Method Post -Uri $fnUrl -Headers $fnHeaders -Body (J $fnBody)
} catch {
  $e = $_
  [IO.File]::WriteAllText((Join-Path $ProofRoot "download_url_error.txt"), ($e | Out-String), (Utf8NoBom))
  Die ("DOWNLOAD_URL_FAILED: " + $e.Exception.Message)
}
[IO.File]::WriteAllText((Join-Path $ProofRoot "download_url_response.json"), (J $fnResp), (Utf8NoBom))
if (-not $fnResp.ok -or -not $fnResp.signed_url) { Die "download-url returned not ok or missing signed_url" }
$signed = [string]$fnResp.signed_url
Write-Host "SIGNED URL OK" -ForegroundColor Green

# ------------------------------------------------------------------
# 6) Download via signed URL and verify sha256+size
# ------------------------------------------------------------------
$dlPath = Join-Path $ProofRoot "downloaded_WorkEngine-Setup.exe"
Write-Host ("Downloading signed URL -> {0}" -f $dlPath) -ForegroundColor Cyan
try {
  Invoke-WebRequest -Uri $signed -OutFile $dlPath -UseBasicParsing | Out-Null
} catch {
  $e = $_
  [IO.File]::WriteAllText((Join-Path $ProofRoot "download_error.txt"), ($e | Out-String), (Utf8NoBom))
  Die ("DOWNLOAD_FAILED: " + $e.Exception.Message)
}
$dlSha = (Get-FileHash -Algorithm SHA256 -LiteralPath $dlPath).Hash.ToLowerInvariant()
$dlSize = (Get-Item -LiteralPath $dlPath).Length
$verify = [ordered]@{
  expected_sha256 = $sha
  expected_size   = [int64]$size
  downloaded_sha256 = $dlSha
  downloaded_size   = [int64]$dlSize
  sha_match = ($dlSha -eq $sha)
  size_match = ($dlSize -eq $size)
  verified_utc = (Get-Date).ToUniversalTime().ToString("o")
}
[IO.File]::WriteAllText((Join-Path $ProofRoot "verify.json"), (J $verify), (Utf8NoBom))
if (-not $verify.sha_match -or -not $verify.size_match) {
  Die ("VERIFY_FAILED: sha_match={0} size_match={1}" -f $verify.sha_match, $verify.size_match)
}
Write-Host "VERIFY OK (sha256+size match)" -ForegroundColor Green

Write-Host "== PUBLISH COMPLETE ==" -ForegroundColor Green
Write-Host ("Proof bundle: {0}" -f $ProofRoot) -ForegroundColor Green