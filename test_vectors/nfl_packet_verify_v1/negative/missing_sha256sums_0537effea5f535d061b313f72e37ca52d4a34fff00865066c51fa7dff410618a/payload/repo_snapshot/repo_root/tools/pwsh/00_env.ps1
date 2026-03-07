#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
$envFile  = Join-Path $repoRoot ".env"

if (-not (Test-Path -LiteralPath $envFile)) {
  throw "ENV_MISSING: .env file not found at $envFile"
}

# Load KEY=VALUE into Process env
Get-Content -LiteralPath $envFile -ErrorAction Stop | ForEach-Object {
  $line = $_
  if ($null -eq $line) { return }

  $line = $line.Trim()
  if ($line.Length -eq 0) { return }
  if ($line.StartsWith("#")) { return }

  $kv = $line.Split("=", 2)
  if ($kv.Count -ne 2) { return }

  $k = $kv[0].Trim()
  $v = $kv[1].Trim()
  if ([string]::IsNullOrWhiteSpace($k)) { return }

  # Strip optional quotes
  if ($v.Length -ge 2) {
    if (($v.StartsWith('"') -and $v.EndsWith('"')) -or ($v.StartsWith("'") -and $v.EndsWith("'"))) {
      $v = $v.Substring(1, $v.Length - 2)
    }
  }

  [Environment]::SetEnvironmentVariable($k, $v, "Process")
}

function Get-EnvValue {
  param([Parameter(Mandatory=$true)][string]$Name)
  $item = Get-Item -LiteralPath ("Env:{0}" -f $Name) -ErrorAction SilentlyContinue
  if ($null -eq $item) { return $null }
  return [string]$item.Value
}

function Assert-Env {
  param([Parameter(Mandatory=$true)][string]$Name)
  $val = Get-EnvValue -Name $Name
  if ([string]::IsNullOrWhiteSpace($val)) {
    throw ("ENV_MISSING: {0}" -f $Name)
  }
  return $val
}

# Required env (canonical)
$global:SUPABASE_URL              = (Assert-Env "SUPABASE_URL").TrimEnd("/")
$global:SUPABASE_PUBLISHABLE_KEY  = Assert-Env "SUPABASE_PUBLISHABLE_KEY"
$global:SUPABASE_SECRET_KEY       = Assert-Env "SUPABASE_SECRET_KEY"
$global:POLICY_VERSION_ID         = [Guid](Assert-Env "POLICY_VERSION_ID")

# Canonical RPC endpoints
$global:GI_PPI_RPC_DEBUG_REQUEST_CONTEXT_URI =
  "$global:SUPABASE_URL/rest/v1/rpc/gi_ppi_debug_request_context"

$global:GI_PPI_RPC_ADMIN_PUBLISH_OVERLAY_URI =
  "$global:SUPABASE_URL/rest/v1/rpc/gi_ppi_admin_publish_overlay"

$global:GI_PPI_RPC_EVAL_WITH_CREDITS_AND_OVERLAY_URI =
  "$global:SUPABASE_URL/rest/v1/rpc/gi_ppi_eval_with_org_credits_and_overlay"

$global:GI_PPI_RPC_REPLAY_EVALUATION_URI =
  "$global:SUPABASE_URL/rest/v1/rpc/gi_ppi_replay_evaluation"
