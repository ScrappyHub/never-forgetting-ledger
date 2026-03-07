$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$Root = "C:\Users\Keira\gi-ppi"
$ProjectRef = "hmlihkcijjamxdurydbv"

function Die([string]$m){ throw $m }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }

function GetEnvAny([string]$name) {
  $v = [Environment]::GetEnvironmentVariable($name,"Process")
  if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
  $v = [Environment]::GetEnvironmentVariable($name,"User")
  if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
  $v = [Environment]::GetEnvironmentVariable($name,"Machine")
  if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
  return $null
}

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

$SecretsDir = Join-Path $Root ".secrets"
$EnvFile    = Join-Path $SecretsDir "gi-ppi.env"
New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null

# Always derive SUPABASE_URL deterministically from ProjectRef
$supabaseUrl = ("https://{0}.supabase.co" -f $ProjectRef)

# Try to seal gi-ppi.env from existing User/Machine/Process env vars (no paste)
$svc = GetEnvAny "SUPABASE_SERVICE_ROLE_KEY"
$sec = GetEnvAny "GI_PPI_WEBHOOK_INTERNAL_SECRET"

if (-not (Test-Path -LiteralPath $EnvFile)) {
  if ([string]::IsNullOrWhiteSpace($svc) -or [string]::IsNullOrWhiteSpace($sec)) {
    Die ("Cannot seal " + $EnvFile + " because required env vars are missing in ALL scopes (Process/User/Machine): " +
         "SUPABASE_SERVICE_ROLE_KEY and/or GI_PPI_WEBHOOK_INTERNAL_SECRET.`n" +
         "If you truly set them 100 times, set them at User scope ONCE (so child processes see them):`n" +
         "  [Environment]::SetEnvironmentVariable('SUPABASE_SERVICE_ROLE_KEY', '<value>', 'User')`n" +
         "  [Environment]::SetEnvironmentVariable('GI_PPI_WEBHOOK_INTERNAL_SECRET', '<value>', 'User')`n" +
         "Then rerun this bootstrap. After that, you never touch them again.")
  }
  $content = @(
    "SUPABASE_URL=$supabaseUrl"
    "SUPABASE_SERVICE_ROLE_KEY=$svc"
    "GI_PPI_WEBHOOK_INTERNAL_SECRET=$sec"
  ) -join "`r`n"
  [IO.File]::WriteAllText($EnvFile, $content + "`r`n", (Utf8NoBom))
  Write-Host ("WROTE secrets env -> {0}" -f $EnvFile) -ForegroundColor Green
} else {
  Write-Host ("OK: secrets env exists -> {0}" -f $EnvFile) -ForegroundColor DarkGray
}

# Load env file into THIS process (so patch run can test MustEnv)
LoadEnvFile $EnvFile | Out-Null

# Patch publish pipeline to auto-load env file + derive SUPABASE_URL if missing
$PublishPath = Join-Path $Root "scripts\pipeline_publish_work_engine_windows.ps1"
if (-not (Test-Path -LiteralPath $PublishPath)) { Die ("Missing publish pipeline: " + $PublishPath) }
$src = Get-Content -Raw -LiteralPath $PublishPath

if ($src -notmatch "AUTOLOAD_ENV_FILE_V1") {
  $insert = @(
    "# AUTOLOAD_ENV_FILE_V1"
    "function LoadEnvFile([string]`$path) {"
    "  if (-not (Test-Path -LiteralPath `$path)) { return `$false }"
    "  foreach (`$ln in (Get-Content -LiteralPath `$path)) {"
    "    `$s = `$ln.Trim()"
    "    if (`$s.Length -eq 0) { continue }"
    "    if (`$s.StartsWith(`#`")) { continue }"
    "    `$idx = `$s.IndexOf(`"=`")"
    "    if (`$idx -lt 1) { continue }"
    "    `$k = `$s.Substring(0, `$idx).Trim()"
    "    `$v = `$s.Substring(`$idx + 1).Trim()"
    "    if (`$k.Length -eq 0) { continue }"
    "    [Environment]::SetEnvironmentVariable(`$k, `$v, `"Process`")"
    "  }"
    "  return `$true"
    "}"
    ""
    "`$SecretsEnv = Join-Path (Split-Path -Parent `$PSScriptRoot) `".secrets\gi-ppi.env`""
    "LoadEnvFile `$SecretsEnv | Out-Null"
    ""
    "if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable(`"SUPABASE_URL`",`"Process`"))) {"
    "  [Environment]::SetEnvironmentVariable(`"SUPABASE_URL`", (`"https://{0}.supabase.co`" -f `"hmlihkcijjamxdurydbv`"), `"Process`")"
    "}"
    ""
  ) -join "`r`n"

  $src2 = $src -replace "Set-StrictMode -Version Latest`r?`n", ("Set-StrictMode -Version Latest`r`n`r`n" + $insert + "`r`n")
  [IO.File]::WriteAllText($PublishPath, $src2, (Utf8NoBom))
  Write-Host ("PATCHED publish pipeline -> {0}" -f $PublishPath) -ForegroundColor Green
} else {
  Write-Host ("OK: publish pipeline already patched -> {0}" -f $PublishPath) -ForegroundColor DarkGray
}

Write-Host "BOOTSTRAP COMPLETE" -ForegroundColor Green