param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Write-Utf8NoBom([string]$Path,[string]$Text) {
  $enc = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

$Root = $RepoRoot
if (-not (Test-Path -LiteralPath $Root)) { throw ("Missing repo root: " + $Root) }

$TrustDir = Join-Path $Root "proofs\trust"
$KeysDir  = Join-Path $Root "proofs\keys"

$Allowed = Join-Path $TrustDir "allowed_signers"
$Pub     = Join-Path $KeysDir  "nfl-local_ed25519.pub"

foreach ($p in @($TrustDir,$KeysDir)) {
  if (-not (Test-Path -LiteralPath $p)) { throw ("Missing required dir: " + $p) }
}
if (-not (Test-Path -LiteralPath $Pub)) { throw ("Missing pubkey: " + $Pub) }

# Canonical identity (must match verify_sig_v1.ps1 -I)
$Principal = "single-tenant/local/authority/nfl"

# Canonical namespaces for this repo (expand later)
$Namespaces = @("nfl/ingest-receipt")

# Read the pubkey line (includes keytype + base64 + optional comment)
$pubLine = (Get-Content -Raw -LiteralPath $Pub).Trim()
if ([string]::IsNullOrWhiteSpace($pubLine)) { throw ("Pubkey empty: " + $Pub) }
if (-not ($pubLine -match '^ssh-ed25519\s+[A-Za-z0-9+/=]+')) { throw ("Unexpected pubkey format: " + $pubLine) }

# allowed_signers format: principal [options] key
# namespaces are options: namespaces="a,b,c"
$nsOpt = 'namespaces="' + (($Namespaces) -join ",") + '"'

$lines = @()
$lines += ($Principal + " " + $nsOpt + " " + $pubLine)

# Backup existing allowed_signers
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
if (Test-Path -LiteralPath $Allowed) {
  $bak = $Allowed + ".bak_" + $stamp
  Copy-Item -LiteralPath $Allowed -Destination $bak -Force | Out-Null
  ("BACKUP_ALLOWED: " + $bak) | Out-Host
}

Write-Utf8NoBom -Path $Allowed -Text (($lines -join "`r`n") + "`r`n")
("WROTE: " + $Allowed) | Out-Host

# Parse-gate the file we wrote (deterministic sanity)
$raw = Get-Content -Raw -LiteralPath $Allowed
if ($raw -notmatch 'namespaces="') { throw "allowed_signers missing namespaces option (unexpected)." }

"OK: allowed_signers format corrected (principal + namespaces option + pubkey)" | Out-Host
