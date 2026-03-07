param()

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

# ------------------------------------------------------------
# NeverLost v1 (NFL) — CANON bootstrap
# Writes: proofs/keys, proofs/trust, proofs/receipts + scripts/*
# Uses cmd.exe wrapper for ssh-keygen to avoid PowerShell argument edge cases.
# ------------------------------------------------------------

$RepoRoot = "C:\dev\nfl"

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $enc = [System.Text.UTF8Encoding]::new($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  [System.IO.File]::WriteAllText($Path, $Text, $enc)
}

function QuoteCmd([string]$s) {
  if ($null -eq $s) { throw "QuoteCmd got null" }
  # cmd.exe quoting: wrap in " and double any embedded "
  return '"' + ($s -replace '"','""') + '"'
}

function Invoke-CmdExe([string]$InnerCommand) {
  if ([string]::IsNullOrWhiteSpace($InnerCommand)) { throw "Invoke-CmdExe InnerCommand empty" }
  # Important: use /d /s /c and wrap with "" ... ""
  $afterC = '""' + $InnerCommand + '""'
  $p = Start-Process -FilePath "cmd.exe" -ArgumentList @("/d","/s","/c",$afterC) -NoNewWindow -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw ("cmd.exe failed (exit " + $p.ExitCode + "): " + $InnerCommand) }
}

function Get-OpenSshKeygen() {
  $exe = Join-Path $env:WINDIR "System32\OpenSSH\ssh-keygen.exe"
  if (-not (Test-Path -LiteralPath $exe)) { throw ("Missing OpenSSH ssh-keygen: " + $exe) }
  return $exe
}

function New-Ed25519Keypair([string]$PrivKeyPath, [string]$Comment) {
  if ([string]::IsNullOrWhiteSpace($PrivKeyPath)) { throw "PrivKeyPath empty" }
  if ([string]::IsNullOrWhiteSpace($Comment)) { $Comment = "neverlost-dev" }

  $exe = Get-OpenSshKeygen
  $pub = $PrivKeyPath + ".pub"

  if (Test-Path -LiteralPath $PrivKeyPath) { Remove-Item -LiteralPath $PrivKeyPath -Force }
  if (Test-Path -LiteralPath $pub) { Remove-Item -LiteralPath $pub -Force }

  $inner =
    (QuoteCmd $exe) + " -t ed25519 -f " + (QuoteCmd $PrivKeyPath) + " -N " + (QuoteCmd "") + " -C " + (QuoteCmd $Comment)

  Invoke-CmdExe $inner

  if (-not (Test-Path -LiteralPath $pub)) { throw ("KEYGEN FAILED: missing pubkey: " + $pub) }
  return $pub
}

function Read-FirstLine([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { throw ("Missing: " + $Path) }
  $line = (Get-Content -LiteralPath $Path -TotalCount 1)
  if ([string]::IsNullOrWhiteSpace($line)) { throw ("Empty file: " + $Path) }
  return $line.Trim()
}

# ------------------------------------------------------------
# Layout
# ------------------------------------------------------------
$KeysDir     = Join-Path $RepoRoot "proofs\keys"
$TrustDir    = Join-Path $RepoRoot "proofs\trust"
$ReceiptsDir = Join-Path $RepoRoot "proofs\receipts"
$ScriptsDir  = Join-Path $RepoRoot "scripts"

New-Item -ItemType Directory -Force -Path $KeysDir,$TrustDir,$ReceiptsDir,$ScriptsDir | Out-Null

# ------------------------------------------------------------
# Identity constants (NFL dev)
# ------------------------------------------------------------
$AuthorityName = "nfl-local"
$Principal     = "single-tenant/local/authority/nfl"
$KeyId         = "dev-1"

# Minimal namespaces for NFL identity layer usage
$Namespaces = @(
  "nfl/ingest-receipt"
)

# ------------------------------------------------------------
# 1) Generate dev keypair
# ------------------------------------------------------------
Write-Host "INFO: generating dev keypair under proofs/keys/ (local only)"
$PrivKey = Join-Path $KeysDir "nfl-local_ed25519"
$PubKey  = New-Ed25519Keypair -PrivKeyPath $PrivKey -Comment ("neverlost-dev " + $AuthorityName)

$PubKeyLine = Read-FirstLine $PubKey

# ------------------------------------------------------------
# 2) Write trust_bundle.json (source of truth)
# ------------------------------------------------------------
$TrustBundlePath = Join-Path $TrustDir "trust_bundle.json"

$nowUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

# Ordered JSON for determinism
$trust = [ordered]@{
  schema      = "neverlost.trust_bundle.v1"
  created_utc = $nowUtc
  principals  = @(
    [ordered]@{
      principal = $Principal
      keys      = @(
        [ordered]@{
          key_id     = $KeyId
          pubkey     = $PubKeyLine
          namespaces = $Namespaces
        }
      )
    }
  )
}

$trustJson = ($trust | ConvertTo-Json -Depth 10)
Write-Utf8NoBom -Path $TrustBundlePath -Text ($trustJson + "`r`n")
Write-Host ("WROTE: " + $TrustBundlePath)

# ------------------------------------------------------------
# 3) Write allowed_signers (derived)
# Format: <principal> <namespace> <pubkey>
# ------------------------------------------------------------
$AllowedSignersPath = Join-Path $TrustDir "allowed_signers"

$asLines = New-Object System.Collections.Generic.List[string]
foreach ($ns in $Namespaces) {
  $asLines.Add(("{0} {1} {2}" -f $Principal, $ns, $PubKeyLine))
}
Write-Utf8NoBom -Path $AllowedSignersPath -Text (($asLines -join "`n") + "`n")
Write-Host ("WROTE: " + $AllowedSignersPath)

# ------------------------------------------------------------
# 4) Write scripts/show_identity_v1.ps1
# ------------------------------------------------------------
$show = @"
param()

`$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

`$RepoRoot = "$RepoRoot"
`$Principal = "$Principal"
`$KeyId = "$KeyId"
`$PubKeyPath = Join-Path `$RepoRoot "proofs\keys\nfl-local_ed25519.pub"

if (-not (Test-Path -LiteralPath `$PubKeyPath)) { throw ("Missing pubkey: " + `$PubKeyPath) }

`$pub = (Get-Content -LiteralPath `$PubKeyPath -TotalCount 1).Trim()
"PRINCIPAL: " + `$Principal
"KEY_ID:    " + `$KeyId
"PUBKEY:    " + `$pub
"@
Write-Utf8NoBom -Path (Join-Path $ScriptsDir "show_identity_v1.ps1") -Text ($show + "`r`n")
Write-Host "WROTE: scripts/show_identity_v1.ps1"

# ------------------------------------------------------------
# 5) Write scripts/sign_file_v1.ps1 (ssh-keygen -Y sign via cmd.exe wrapper)
# Produces: <file>.sig
# ------------------------------------------------------------
$sign = @"
param(
  [Parameter(Mandatory=`$true)][string]`$File,
  [Parameter(Mandatory=`$true)][string]`$Namespace
)

`$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

`$RepoRoot = "$RepoRoot"
`$KeyPath = Join-Path `$RepoRoot "proofs\keys\nfl-local_ed25519"

if (-not (Test-Path -LiteralPath `$File)) { throw ("Missing file: " + `$File) }
if (-not (Test-Path -LiteralPath `$KeyPath)) { throw ("Missing key: " + `$KeyPath) }
if ([string]::IsNullOrWhiteSpace(`$Namespace)) { throw "Namespace empty" }

function QuoteCmd([string]`$s) { '"' + (`$s -replace '"','""') + '"' }
function Invoke-CmdExe([string]`$Inner) {
  `$afterC = '""' + `$Inner + '""'
  `$p = Start-Process -FilePath "cmd.exe" -ArgumentList @("/d","/s","/c",`$afterC) -NoNewWindow -Wait -PassThru
  if (`$p.ExitCode -ne 0) { throw ("cmd.exe failed (exit " + `$p.ExitCode + "): " + `$Inner) }
}

`$exe = Join-Path `$env:WINDIR "System32\OpenSSH\ssh-keygen.exe"
if (-not (Test-Path -LiteralPath `$exe)) { throw ("Missing OpenSSH ssh-keygen: " + `$exe) }

`$inner = (QuoteCmd `$exe) + " -Y sign -f " + (QuoteCmd `$KeyPath) + " -n " + (QuoteCmd `$Namespace) + " " + (QuoteCmd `$File)
Invoke-CmdExe `$inner

`$sig = `$File + ".sig"
if (-not (Test-Path -LiteralPath `$sig)) { throw ("Missing sig: " + `$sig) }
"OK: " + `$sig
"@
Write-Utf8NoBom -Path (Join-Path $ScriptsDir "sign_file_v1.ps1") -Text ($sign + "`r`n")
Write-Host "WROTE: scripts/sign_file_v1.ps1"

# ------------------------------------------------------------
# 6) Write scripts/verify_sig_v1.ps1 (ssh-keygen -Y verify via cmd.exe wrapper)
# ------------------------------------------------------------
$ver = @"
param(
  [Parameter(Mandatory=`$true)][string]`$File,
  [Parameter(Mandatory=`$true)][string]`$Sig,
  [Parameter(Mandatory=`$true)][string]`$Namespace
)

`$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

`$RepoRoot = "$RepoRoot"
`$Allowed = Join-Path `$RepoRoot "proofs\trust\allowed_signers"
`$Principal = "$Principal"

if (-not (Test-Path -LiteralPath `$Allowed)) { throw ("Missing allowed_signers: " + `$Allowed) }
if (-not (Test-Path -LiteralPath `$File)) { throw ("Missing file: " + `$File) }
if (-not (Test-Path -LiteralPath `$Sig))  { throw ("Missing sig: " + `$Sig) }
if ([string]::IsNullOrWhiteSpace(`$Namespace)) { throw "Namespace empty" }

function QuoteCmd([string]`$s) { '"' + (`$s -replace '"','""') + '"' }
function Invoke-CmdExe([string]`$Inner) {
  `$afterC = '""' + `$Inner + '""'
  `$p = Start-Process -FilePath "cmd.exe" -ArgumentList @("/d","/s","/c",`$afterC) -NoNewWindow -Wait -PassThru
  if (`$p.ExitCode -ne 0) { throw ("cmd.exe failed (exit " + `$p.ExitCode + "): " + `$Inner) }
}

`$exe = Join-Path `$env:WINDIR "System32\OpenSSH\ssh-keygen.exe"
if (-not (Test-Path -LiteralPath `$exe)) { throw ("Missing OpenSSH ssh-keygen: " + `$exe) }

# verify requires -r <krl>; provide a temp path
`$tmp = [System.IO.Path]::GetTempFileName()
try {
  `$inner =
    (QuoteCmd `$exe) + " -Y verify -f " + (QuoteCmd `$Allowed) +
    " -I " + (QuoteCmd `$Principal) +
    " -n " + (QuoteCmd `$Namespace) +
    " -s " + (QuoteCmd `$Sig) +
    " -r " + (QuoteCmd `$tmp) +
    " " + (QuoteCmd `$File)

  Invoke-CmdExe `$inner
  "OK: verified"
} finally {
  Remove-Item -LiteralPath `$tmp -Force -ErrorAction SilentlyContinue
}
"@
Write-Utf8NoBom -Path (Join-Path $ScriptsDir "verify_sig_v1.ps1") -Text ($ver + "`r`n")
Write-Host "WROTE: scripts/verify_sig_v1.ps1"

# ------------------------------------------------------------
# 7) Smoke test: sign + verify trust_bundle.json
# ------------------------------------------------------------
Write-Host "INFO: smoke test sign+verify trust_bundle.json"
$signScript = Join-Path $ScriptsDir "sign_file_v1.ps1"
$verScript  = Join-Path $ScriptsDir "verify_sig_v1.ps1"

& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $signScript -File $TrustBundlePath -Namespace "nfl/ingest-receipt" | Out-Host
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $verScript  -File $TrustBundlePath -Sig ($TrustBundlePath + ".sig") -Namespace "nfl/ingest-receipt" | Out-Host

Write-Host "DONE: NeverLost v1 NFL bootstrap complete."
Write-Host ("  PubKey: " + $PubKey)
Write-Host ("  Trust:  " + $TrustBundlePath)
Write-Host ("  AS:     " + $AllowedSignersPath)
