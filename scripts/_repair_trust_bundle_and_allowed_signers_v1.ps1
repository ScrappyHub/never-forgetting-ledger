param(
  [Parameter()][string]$RepoRoot = "C:\dev\nfl"
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Write-Utf8NoBom([string]$Path,[string]$Text) {
  $enc = [System.Text.UTF8Encoding]::new($false)
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

$Root = $RepoRoot
if (-not (Test-Path -LiteralPath $Root)) { throw ("Missing repo root: " + $Root) }

$KeysDir  = Join-Path $Root "proofs\keys"
$TrustDir = Join-Path $Root "proofs\trust"

$Priv = Join-Path $KeysDir "nfl-local_ed25519"
$Pub  = $Priv + ".pub"

$Tb = Join-Path $TrustDir "trust_bundle.json"
$As = Join-Path $TrustDir "allowed_signers"

foreach ($p in @($KeysDir,$TrustDir)) {
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
}
foreach ($p in @($Priv,$Pub)) {
  if (-not (Test-Path -LiteralPath $p)) { throw ("Missing key file: " + $p + " (re-run CANON2 bootstrap)") }
}

# Backups
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
if (Test-Path -LiteralPath $Tb) { Copy-Item -LiteralPath $Tb -Destination ($Tb + ".bak_" + $stamp) -Force }
if (Test-Path -LiteralPath $As) { Copy-Item -LiteralPath $As -Destination ($As + ".bak_" + $stamp) -Force }

# Read current pubkey (must match signer key)
$pubLine = (Get-Content -Raw -LiteralPath $Pub).Trim()
if ([string]::IsNullOrWhiteSpace($pubLine)) { throw ("Pubkey file empty: " + $Pub) }

# Canonical identity (MUST match verify_sig_v1.ps1 -I)
$Principal = "single-tenant/local/authority/nfl"
$KeyId     = "dev-1"

# Namespaces
$Namespaces = @("nfl/ingest-receipt")

# Build trust_bundle.json deterministically (NO nested here-strings)
$createdUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$L = @()
$L += "{"
$L += '  "schema": "neverlost.trust_bundle.v1",'
$L += ('  "created_utc": "' + $createdUtc + '",')
$L += '  "principals": ['
$L += "    {"
$L += ('      "principal": "' + $Principal + '",')
$L += '      "keys": ['
$L += "        {"
$L += ('          "key_id": "' + $KeyId + '",')
$L += ('          "pubkey": "' + ($pubLine -replace '"','\"') + '",')
$L += '          "namespaces": ['
for ($i=0; $i -lt $Namespaces.Count; $i++) {
  $ns = $Namespaces[$i]
  $comma = if ($i -lt ($Namespaces.Count-1)) { "," } else { "" }
  $L += ('            "' + ($ns -replace '"','\"') + '"' + $comma)
}
$L += '          ]'
$L += "        }"
$L += '      ]'
$L += "    }"
$L += '  ]'
$L += "}"

Write-Utf8NoBom -Path $Tb -Text (($L -join "`r`n") + "`r`n")
("WROTE: " + $Tb) | Out-Host

# Derive allowed_signers deterministically: <principal> <namespace> <pubkey>
$als = @()
foreach ($ns in $Namespaces) {
  $als += ($Principal + " " + $ns + " " + $pubLine)
}
Write-Utf8NoBom -Path $As -Text (($als -join "`r`n") + "`r`n")
("WROTE: " + $As) | Out-Host

# Re-sign + verify (delete existing .sig to avoid prompts)
$Sign = Join-Path $Root "scripts\sign_file_v1.ps1"
$Ver  = Join-Path $Root "scripts\verify_sig_v1.ps1"
foreach ($p in @($Sign,$Ver)) { if (-not (Test-Path -LiteralPath $p)) { throw ("Missing script: " + $p) } }

$sigPath = $Tb + ".sig"
if (Test-Path -LiteralPath $sigPath) { Remove-Item -LiteralPath $sigPath -Force }

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Sign -File $Tb -Namespace "nfl/ingest-receipt" -TimeoutSeconds 20 | Out-Host
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Ver  -File $Tb -Sig $sigPath -Namespace "nfl/ingest-receipt" -TimeoutSeconds 20 | Out-Host

"OK: trust_bundle + allowed_signers repaired and signature verified" | Out-Host
