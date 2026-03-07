param(
  [Parameter(Mandatory=$false)][string]$ProjectRef = "hmlihkcijjamxdurydbv"
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function GetEnv([string]$name,[string]$scope){ [Environment]::GetEnvironmentVariable($name,$scope) }
function SetEnv([string]$name,[string]$val,[string]$scope){ [Environment]::SetEnvironmentVariable($name,$val,$scope) }

function ReadSecretNonEmpty([string]$name){
  Write-Host ("Enter {0} (input hidden). Must be non-empty." -f $name) -ForegroundColor Cyan
  $s = Read-Host -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try {
    $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
  } finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) | Out-Null
  }
  if ([string]::IsNullOrWhiteSpace($plain)) { Die ("Empty value for " + $name) }
  return $plain
}

$Root = Split-Path -Parent $PSScriptRoot
$SecretsDir = Join-Path $Root ".secrets"
$EnvFile = Join-Path $SecretsDir "gi-ppi.env"
New-Item -ItemType Directory -Path $SecretsDir -Force | Out-Null

# Deterministic URL from ProjectRef
$supabaseUrl = ("https://{0}.supabase.co" -f $ProjectRef)

# Pull from User scope if present
$svcU = GetEnv "SUPABASE_SERVICE_ROLE_KEY" "User"
$secU = GetEnv "GI_PPI_WEBHOOK_INTERNAL_SECRET" "User"

if ([string]::IsNullOrWhiteSpace($svcU)) { $svcU = ReadSecretNonEmpty "SUPABASE_SERVICE_ROLE_KEY" }
if ([string]::IsNullOrWhiteSpace($secU)) { $secU = ReadSecretNonEmpty "GI_PPI_WEBHOOK_INTERNAL_SECRET" }

# Persist to USER scope so new powershell.exe processes see them
SetEnv "SUPABASE_URL" $supabaseUrl "User"
SetEnv "SUPABASE_SERVICE_ROLE_KEY" $svcU "User"
SetEnv "GI_PPI_WEBHOOK_INTERNAL_SECRET" $secU "User"

# Also set Process scope for THIS run
SetEnv "SUPABASE_URL" $supabaseUrl "Process"
SetEnv "SUPABASE_SERVICE_ROLE_KEY" $svcU "Process"
SetEnv "GI_PPI_WEBHOOK_INTERNAL_SECRET" $secU "Process"

# Write env file (no printing secrets)
$content = @(
  ("SUPABASE_URL=" + $supabaseUrl)
  ("SUPABASE_SERVICE_ROLE_KEY=" + $svcU)
  ("GI_PPI_WEBHOOK_INTERNAL_SECRET=" + $secU)
) -join "`r`n"
[IO.File]::WriteAllText($EnvFile, $content + "`r`n", (Utf8NoBom))

# Proof: sha256 of env file (not contents)
$h = (Get-FileHash -Algorithm SHA256 -LiteralPath $EnvFile).Hash.ToLowerInvariant()
Write-Host ("SEALED: {0}" -f $EnvFile) -ForegroundColor Green
Write-Host ("ENVFILE_SHA256: {0}" -f $h) -ForegroundColor DarkGray