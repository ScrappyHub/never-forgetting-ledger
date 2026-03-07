$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$Root = "C:\dev\nfl"
if (-not (Test-Path -LiteralPath $Root)) { throw "Repo root missing: $Root" }

$Proofs      = Join-Path $Root "proofs"
$KeysDir     = Join-Path $Proofs "keys"
$TrustDir    = Join-Path $Proofs "trust"
$ReceiptsDir = Join-Path $Proofs "receipts"
$ScriptsDir  = Join-Path $Root "scripts"

New-Item -ItemType Directory -Force -Path $KeysDir,$TrustDir,$ReceiptsDir,$ScriptsDir | Out-Null

# Required presence files
$GitKeep = Join-Path $KeysDir ".gitkeep"
if (-not (Test-Path -LiteralPath $GitKeep)) { Set-Content -LiteralPath $GitKeep -Value "" -Encoding UTF8 }

$TrustBundlePath    = Join-Path $TrustDir "trust_bundle.json"
$AllowedSignersPath = Join-Path $TrustDir "allowed_signers"
$ReceiptsPath       = Join-Path $ReceiptsDir "neverlost.ndjson"

if (-not (Test-Path -LiteralPath $ReceiptsPath)) { New-Item -ItemType File -Force -Path $ReceiptsPath | Out-Null }
if (-not (Test-Path -LiteralPath $AllowedSignersPath)) { New-Item -ItemType File -Force -Path $AllowedSignersPath | Out-Null }

# ------------------------------------------------------------
# Backup any existing NeverLost scripts
# ------------------------------------------------------------
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$bkDir = Join-Path $ScriptsDir ("_bk_neverlost_" + $stamp)
New-Item -ItemType Directory -Force -Path $bkDir | Out-Null
Get-ChildItem -LiteralPath $ScriptsDir -File -Filter "*neverlost*_v1*.ps1" -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $bkDir $_.Name) -Force }
Get-ChildItem -LiteralPath $ScriptsDir -File -Filter "_lib_neverlost_v1.ps1" -ErrorAction SilentlyContinue | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $bkDir $_.Name) -Force }
"BACKUP_DIR: " + $bkDir

# ------------------------------------------------------------
# Write scripts/_lib_neverlost_v1.ps1
# ------------------------------------------------------------
$LibPath = Join-Path $ScriptsDir "_lib_neverlost_v1.ps1"
$lib = @()
$lib += '$ErrorActionPreference="Stop"'
$lib += 'Set-StrictMode -Version Latest'
$lib += ''
$lib += 'function Write-Utf8NoBom([string]$Path, [string]$Text) {'
$lib += '  $enc = [System.Text.UTF8Encoding]::new($false)'
$lib += '  $dir = Split-Path -Parent $Path'
$lib += '  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }'
$lib += '  $sw = [System.IO.StreamWriter]::new($Path, $false, $enc)'
$lib += '  try { $sw.Write($Text) } finally { $sw.Dispose() }'
$lib += '}'
$lib += ''
$lib += 'function Read-Utf8([string]$Path) {'
$lib += '  if (-not (Test-Path -LiteralPath $Path)) { throw ("Missing: " + $Path) }'
$lib += '  return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))'
$lib += '}'
$lib += ''
$lib += 'function Sha256HexBytes([byte[]]$Bytes) {'
$lib += '  $sha = [System.Security.Cryptography.SHA256]::Create()'
$lib += '  try { ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "" } finally { $sha.Dispose() }'
$lib += '}'
$lib += ''
$lib += 'function Sha256HexPath([string]$Path) {'
$lib += '  if (-not (Test-Path -LiteralPath $Path)) { throw ("Missing: " + $Path) }'
$lib += '  $bytes = [System.IO.File]::ReadAllBytes($Path)'
$lib += '  return Sha256HexBytes -Bytes $bytes'
$lib += '}'
$lib += ''
$lib += 'function ResolveRealPath([string]$Path) { (Resolve-Path -LiteralPath $Path).Path }'
$lib += ''
$lib += 'function RelPathUnix([string]$Root, [string]$Path) {'
$lib += '  $r = (ResolveRealPath $Root).TrimEnd("\")'
$lib += '  $p = (ResolveRealPath $Path)'
$lib += '  if ($p -notlike ($r + "\*")) { return ($p -replace "\\","/") }'
$lib += '  $rel = $p.Substring($r.Length).TrimStart("\")'
$lib += '  return ($rel -replace "\\","/")'
$lib += '}'
$lib += ''
$lib += 'function AssertPrincipalFormat([string]$Principal) {'
$lib += '  if ([string]::IsNullOrWhiteSpace($Principal)) { throw "Principal empty" }'
$lib += '  if ($Principal -notmatch "^single-tenant\/[^\/]+\/authority\/[^\/]+$") { throw ("Principal format invalid: " + $Principal) }'
$lib += '}'
$lib += ''
$lib += 'function AssertKeyIdFormat([string]$KeyId) {'
$lib += '  if ([string]::IsNullOrWhiteSpace($KeyId)) { throw "KeyId empty" }'
$lib += '  if ($KeyId -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$") { throw ("KeyId format invalid: " + $KeyId) }'
$lib += '}'
$lib += ''
$lib += 'function ConvertTo-Ordered([object]$Obj) {'
$lib += '  if ($null -eq $Obj) { return $null }'
$lib += '  if ($Obj -is [System.Collections.IDictionary]) {'
$lib += '    $keys = @($Obj.Keys) | Sort-Object'
$lib += '    $h = [ordered]@{}'
$lib += '    foreach ($k in $keys) { $h[$k] = ConvertTo-Ordered $Obj[$k] }'
$lib += '    return $h'
$lib += '  }'
$lib += '  if (($Obj -is [System.Collections.IEnumerable]) -and -not ($Obj -is [string])) {'
$lib += '    $arr = @()'
$lib += '    foreach ($it in $Obj) { $arr += ,(ConvertTo-Ordered $it) }'
$lib += '    return $arr'
$lib += '  }'
$lib += '  return $Obj'
$lib += '}'
$lib += ''
$lib += 'function To-CanonJson([object]$Obj) { (ConvertTo-Ordered $Obj | ConvertTo-Json -Depth 100 -Compress) }'
$lib += ''
$lib += 'function LoadTrustBundle([string]$TrustBundlePath) {'
$lib += '  $raw = Read-Utf8 $TrustBundlePath'
$lib += '  $tb = $raw | ConvertFrom-Json -Depth 100'
$lib += '  if ($null -eq $tb) { throw "trust_bundle parsed null" }'
$lib += '  if ($tb.schema -ne "neverlost.trust_bundle.v1") { throw ("Unsupported trust_bundle schema: " + [string]$tb.schema) }'
$lib += '  if ($null -eq $tb.trust) { throw "trust_bundle missing trust[]" }'
$lib += '  foreach ($t in $tb.trust) {'
$lib += '    AssertPrincipalFormat ([string]$t.principal)'
$lib += '    AssertKeyIdFormat ([string]$t.key_id)'
$lib += '    if ([string]::IsNullOrWhiteSpace([string]$t.pubkey_sha256)) { throw "trust record missing pubkey_sha256" }'
$lib += '    if ([string]::IsNullOrWhiteSpace([string]$t.pubkey_path)) { throw "trust record missing pubkey_path" }'
$lib += '    if ($null -eq $t.namespaces) { throw "trust record missing namespaces[]" }'
$lib += '  }'
$lib += '  return $tb'
$lib += '}'
$lib += ''
$lib += 'function WriteAllowedSignersFile([string]$AllowedSignersPath, [string[]]$Lines) {'
$lib += '  $enc = [System.Text.UTF8Encoding]::new($false)'
$lib += '  $txt = ($Lines -join "`r`n") + "`r`n"'
$lib += '  $sw = [System.IO.StreamWriter]::new($AllowedSignersPath, $false, $enc)'
$lib += '  try { $sw.Write($txt) } finally { $sw.Dispose() }'
$lib += '}'
$lib += ''
$lib += 'function Write-NeverLostReceipt([string]$ReceiptsPath, [hashtable]$Obj) {'
$lib += '  $enc = [System.Text.UTF8Encoding]::new($false)'
$lib += '  $line = (To-CanonJson $Obj) + "`r`n"'
$lib += '  $fs = [System.IO.File]::Open($ReceiptsPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)'
$lib += '  try {'
$lib += '    $sw = [System.IO.StreamWriter]::new($fs, $enc)'
$lib += '    try { $sw.Write($line) } finally { $sw.Dispose() }'
$lib += '  } finally { $fs.Dispose() }'
$lib += '}'
$lib += ''
$lib += 'function SshYSignFile([string]$KeyPath, [string]$Namespace, [string]$FilePath, [string]$SigPath) {'
$lib += '  if ([string]::IsNullOrWhiteSpace($Namespace)) { throw "Namespace empty" }'
$lib += '  if (-not (Test-Path -LiteralPath $KeyPath)) { throw ("Missing key: " + $KeyPath) }'
$lib += '  if (-not (Test-Path -LiteralPath $FilePath)) { throw ("Missing file: " + $FilePath) }'
$lib += '  & ssh-keygen -Y sign -f $KeyPath -n $Namespace $FilePath | Out-Null'
$lib += '  $defaultSig = $FilePath + ".sig"'
$lib += '  if (-not (Test-Path -LiteralPath $defaultSig)) { throw "ssh-keygen did not produce .sig" }'
$lib += '  if ($SigPath -ne $defaultSig) { Copy-Item -LiteralPath $defaultSig -Destination $SigPath -Force }'
$lib += '}'
$lib += ''
$lib += 'function SshYVerifyFile([string]$AllowedSignersPath, [string]$Namespace, [string]$Principal, [string]$FilePath, [string]$SigPath) {'
$lib += '  if ([string]::IsNullOrWhiteSpace($Namespace)) { throw "Namespace empty" }'
$lib += '  AssertPrincipalFormat $Principal'
$lib += '  if (-not (Test-Path -LiteralPath $AllowedSignersPath)) { throw ("Missing allowed_signers: " + $AllowedSignersPath) }'
$lib += '  if (-not (Test-Path -LiteralPath $FilePath)) { throw ("Missing file: " + $FilePath) }'
$lib += '  if (-not (Test-Path -LiteralPath $SigPath)) { throw ("Missing sig: " + $SigPath) }'
$lib += '  $tmpRev = [System.IO.Path]::GetTempFileName()'
$lib += '  try {'
$lib += '    # -I must match the principal identity in allowed_signers'
$lib += '    & ssh-keygen -Y verify -f $AllowedSignersPath -I $Principal -n $Namespace -s $SigPath -r $tmpRev $FilePath | Out-Null'
$lib += '  } finally { Remove-Item -LiteralPath $tmpRev -Force -ErrorAction SilentlyContinue }'
$lib += '}'

# --- write _lib_neverlost_v1.ps1 without depending on functions that don't exist yet ---
$enc = [System.Text.UTF8Encoding]::new($false)
$libText = (($lib -join "`r`n") + "`r`n")
$sw = [System.IO.StreamWriter]::new($LibPath, $false, $enc)
try { $sw.Write($libText) } finally { $sw.Dispose() }
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $LibPath)) | Out-Null
"WROTE: scripts/_lib_neverlost_v1.ps1"

. $LibPath

# ------------------------------------------------------------
# Identity config (NFL local dev defaults)
# ------------------------------------------------------------
$Principal = "single-tenant/local/authority/nfl"
$KeyId     = "dev-1"
$AuthorityName = "nfl-local"
AssertPrincipalFormat $Principal
AssertKeyIdFormat $KeyId

$PrivKey = Join-Path $KeysDir ($AuthorityName + "_ed25519")
$PubKey  = $PrivKey + ".pub"
if (-not (Test-Path -LiteralPath $PrivKey) -or -not (Test-Path -LiteralPath $PubKey)) {
  "INFO: generating dev keypair under proofs/keys/ (local only)"
& ssh-keygen -t ed25519 -f $KeyPath -N "" -C $Comment
}
if (-not (Test-Path -LiteralPath $PubKey)) { throw "Missing pubkey: $PubKey" }
$pubHash = Sha256HexPath $PubKey

# ------------------------------------------------------------
# Seed trust_bundle.json if missing (do not mutate if present)
# ------------------------------------------------------------
if (-not (Test-Path -LiteralPath $TrustBundlePath)) {
  $tb = [ordered]@{
    schema="neverlost.trust_bundle.v1"
    bundle_id="nfl.trust.dev.v1"
    created_utc=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    trust=@(
      [ordered]@{
        principal=$Principal
        key_id=$KeyId
        pubkey_sha256=$pubHash
        pubkey_path=(RelPathUnix $Root $PubKey)
        namespaces=@("packet/envelope","nfl/ingest-receipt")
      }
    )
  }
  Write-Utf8NoBom -Path $TrustBundlePath -Text ((To-CanonJson $tb) + "`r`n")
  "WROTE: proofs/trust/trust_bundle.json (seed)"
} else {
  $null = LoadTrustBundle $TrustBundlePath
  "OK: proofs/trust/trust_bundle.json exists and validates"
}

# ------------------------------------------------------------
# Materialize allowed_signers deterministically from trust bundle
# allowed_signers line format: <principal> <ssh-public-key>
# ------------------------------------------------------------
$tb2 = LoadTrustBundle $TrustBundlePath
$asLines = @()
foreach ($t in @($tb2.trust | Sort-Object principal,key_id)) {
  $p = [string]$t.principal
  $pubRel = [string]$t.pubkey_path
  $pubAbs = Join-Path $Root ($pubRel -replace "/","\")
  if (-not (Test-Path -LiteralPath $pubAbs)) { throw ("Missing pubkey referenced by trust bundle: " + $pubRel) }
  $pub = (Get-Content -Raw -LiteralPath $pubAbs).Trim()
  if ($pub -notmatch "^ssh-") { throw "Pubkey does not look like ssh public key" }
  $asLines += ($p + " " + $pub)
}
WriteAllowedSignersFile -AllowedSignersPath $AllowedSignersPath -Lines $asLines
$rbHash = Sha256HexPath $TrustBundlePath
$asHash = Sha256HexPath $AllowedSignersPath
Write-NeverLostReceipt -ReceiptsPath $ReceiptsPath -Obj ([ordered]@{schema="neverlost.receipt.v1";at_utc=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ");action="make_allowed_signers";ok=$true;trust_bundle_sha256=$rbHash;allowed_signers_sha256=$asHash})
"OK: allowed_signers regenerated + receipt written"

# ------------------------------------------------------------
# Write required entrypoint scripts
# ------------------------------------------------------------
$mkPath = Join-Path $ScriptsDir "make_allowed_signers_v1.ps1"
$mk = @()
$mk += '$ErrorActionPreference="Stop"'
$mk += 'Set-StrictMode -Version Latest'
$mk += ''
$mk += '$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)'
$mk += '. (Join-Path $Root "scripts\_lib_neverlost_v1.ps1")'
$mk += '$TrustBundlePath = Join-Path $Root "proofs\trust\trust_bundle.json"'
$mk += '$AllowedSignersPath = Join-Path $Root "proofs\trust\allowed_signers"'
$mk += '$ReceiptsPath = Join-Path $Root "proofs\receipts\neverlost.ndjson"'
$mk += ''
$mk += '$tb = LoadTrustBundle $TrustBundlePath'
$mk += '$asLines = @()'
$mk += 'foreach ($t in @($tb.trust | Sort-Object principal,key_id)) {'
$mk += '  $p = [string]$t.principal'
$mk += '  $pubAbs = Join-Path $Root (([string]$t.pubkey_path) -replace "/","\")'
$mk += '  $pub = (Get-Content -Raw -LiteralPath $pubAbs).Trim()'
$mk += '  $asLines += ($p + " " + $pub)'
$mk += '}'
$mk += 'WriteAllowedSignersFile -AllowedSignersPath $AllowedSignersPath -Lines $asLines'
$mk += '$rbHash = Sha256HexPath $TrustBundlePath'
$mk += '$asHash = Sha256HexPath $AllowedSignersPath'
$mk += 'Write-NeverLostReceipt -ReceiptsPath $ReceiptsPath -Obj ([ordered]@{schema="neverlost.receipt.v1";at_utc=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ");action="make_allowed_signers";ok=$true;trust_bundle_sha256=$rbHash;allowed_signers_sha256=$asHash})'
$mk += '"OK"'
Write-Utf8NoBom -Path $mkPath -Text (($mk -join "`r`n") + "`r`n")
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $mkPath)) | Out-Null
"WROTE: scripts/make_allowed_signers_v1.ps1"

$shPath = Join-Path $ScriptsDir "show_identity_v1.ps1"
$sh = @()
$sh += '$ErrorActionPreference="Stop"'
$sh += 'Set-StrictMode -Version Latest'
$sh += ''
$sh += '$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)'
$sh += '. (Join-Path $Root "scripts\_lib_neverlost_v1.ps1")'
$sh += '$TrustBundlePath = Join-Path $Root "proofs\trust\trust_bundle.json"'
$sh += '$AllowedSignersPath = Join-Path $Root "proofs\trust\allowed_signers"'
$sh += '$ReceiptsPath = Join-Path $Root "proofs\receipts\neverlost.ndjson"'
$sh += ''
$sh += '$tb = LoadTrustBundle $TrustBundlePath'
$sh += '$rbHash = Sha256HexPath $TrustBundlePath'
$sh += '$asHash = Sha256HexPath $AllowedSignersPath'
$sh += 'Write-Host ("RepoRoot: " + (ResolveRealPath $Root))'
$sh += 'Write-Host ("TrustBundle: " + (RelPathUnix $Root $TrustBundlePath) + " sha256=" + $rbHash)'
$sh += 'Write-Host ("AllowedSigners: " + (RelPathUnix $Root $AllowedSignersPath) + " sha256=" + $asHash)'
$sh += ''
$sh += 'foreach ($t in @($tb.trust | Sort-Object principal,key_id)) {'
$sh += '  Write-Host ("Principal: " + [string]$t.principal)'
$sh += '  Write-Host ("KeyId:     " + [string]$t.key_id)'
$sh += '  Write-Host ("PubKeySha: " + [string]$t.pubkey_sha256)'
$sh += '  Write-Host "Namespaces:"'
$sh += '  foreach ($ns in @($t.namespaces | Sort-Object)) { Write-Host ("  - " + $ns) }'
$sh += '  Write-Host ""'
$sh += '}'
$sh += 'Write-NeverLostReceipt -ReceiptsPath $ReceiptsPath -Obj ([ordered]@{schema="neverlost.receipt.v1";at_utc=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ");action="show_identity";ok=$true;trust_bundle_sha256=$rbHash;allowed_signers_sha256=$asHash})'
$sh += '"OK"'
Write-Utf8NoBom -Path $shPath -Text (($sh -join "`r`n") + "`r`n")
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $shPath)) | Out-Null
"WROTE: scripts/show_identity_v1.ps1"

$verPath = Join-Path $ScriptsDir "verify_sig_v1.ps1"
$vv = @()
$vv += '$ErrorActionPreference="Stop"'
$vv += 'Set-StrictMode -Version Latest'
$vv += 'param('
$vv += '  [Parameter(Mandatory=$true)][string]$File,'
$vv += '  [Parameter(Mandatory=$true)][string]$Sig,'
$vv += '  [Parameter(Mandatory=$true)][string]$Namespace,'
$vv += '  [Parameter(Mandatory=$true)][string]$Principal,'
$vv += '  [Parameter(Mandatory=$true)][string]$KeyId'
$vv += ')'
$vv += ''
$vv += '$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)'
$vv += '. (Join-Path $Root "scripts\_lib_neverlost_v1.ps1")'
$vv += '$TrustBundlePath = Join-Path $Root "proofs\trust\trust_bundle.json"'
$vv += '$AllowedSignersPath = Join-Path $Root "proofs\trust\allowed_signers"'
$vv += '$ReceiptsPath = Join-Path $Root "proofs\receipts\neverlost.ndjson"'
$vv += ''
$vv += 'AssertPrincipalFormat $Principal'
$vv += 'AssertKeyIdFormat $KeyId'
$vv += '$tb = LoadTrustBundle $TrustBundlePath'
$vv += '$rbHash = Sha256HexPath $TrustBundlePath'
$vv += '$fAbs = ResolveRealPath $File'
$vv += '$sAbs = ResolveRealPath $Sig'
$vv += '$fHash = Sha256HexPath $fAbs'
$vv += '$ok = $false'
$vv += '$reason = ""'
$vv += 'try {'
$vv += '  # Trust policy: principal+keyid must exist, and namespace must be allowed'
$vv += '  $t = @($tb.trust | Where-Object { [string]$_.principal -eq $Principal -and [string]$_.key_id -eq $KeyId })'
$vv += '  if (-not $t -or $t.Count -eq 0) { throw ("Principal+KeyId not trusted: " + $Principal + " / " + $KeyId) }'
$vv += '  if (@($t[0].namespaces) -notcontains $Namespace) { throw ("Namespace not allowed: " + $Namespace) }'
$vv += '  # Cryptographic verify (namespace enforced by -n; identity enforced by -I)'
$vv += '  SshYVerifyFile -AllowedSignersPath $AllowedSignersPath -Namespace $Namespace -Principal $Principal -FilePath $fAbs -SigPath $sAbs'
$vv += '  $ok = $true'
$vv += '} catch { $ok = $false; $reason = $_.Exception.Message }'
$vv += 'Write-NeverLostReceipt -ReceiptsPath $ReceiptsPath -Obj ([ordered]@{schema="neverlost.receipt.v1";at_utc=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ");action="verify_sig";ok=$ok;namespace=$Namespace;principal=$Principal;key_id=$KeyId;file=(RelPathUnix $Root $fAbs);file_sha256=$fHash;trust_bundle_sha256=$rbHash;reason=$reason})'
$vv += 'if (-not $ok) { throw ("verify_sig failed: " + $reason) }'
$vv += '"OK"'
Write-Utf8NoBom -Path $verPath -Text (($vv -join "`r`n") + "`r`n")
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $verPath)) | Out-Null
"WROTE: scripts/verify_sig_v1.ps1"

$sgPath = Join-Path $ScriptsDir "sign_file_v1.ps1"
$ss = @()
$ss += '$ErrorActionPreference="Stop"'
$ss += 'Set-StrictMode -Version Latest'
$ss += 'param('
$ss += '  [Parameter(Mandatory=$true)][string]$File,'
$ss += '  [Parameter(Mandatory=$true)][string]$Namespace,'
$ss += '  [Parameter(Mandatory=$true)][string]$AuthorityName,'
$ss += '  [Parameter(Mandatory=$true)][string]$Principal,'
$ss += '  [Parameter(Mandatory=$true)][string]$KeyId'
$ss += ')'
$ss += ''
$ss += '$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)'
$ss += '. (Join-Path $Root "scripts\_lib_neverlost_v1.ps1")'
$ss += '$ReceiptsPath = Join-Path $Root "proofs\receipts\neverlost.ndjson"'
$ss += ''
$ss += 'AssertPrincipalFormat $Principal'
$ss += 'AssertKeyIdFormat $KeyId'
$ss += 'if ([string]::IsNullOrWhiteSpace($Namespace)) { throw "Namespace empty" }'
$ss += '$KeyPath = Join-Path (Join-Path $Root "proofs\keys") ($AuthorityName + "_ed25519")'
$ss += '$fAbs = ResolveRealPath $File'
$ss += '$fHash = Sha256HexPath $fAbs'
$ss += '$sigPath = $fAbs + ".sig"'
$ss += 'SshYSignFile -KeyPath $KeyPath -Namespace $Namespace -FilePath $fAbs -SigPath $sigPath'
$ss += '$sigHash = Sha256HexPath $sigPath'
$ss += 'Write-NeverLostReceipt -ReceiptsPath $ReceiptsPath -Obj ([ordered]@{schema="neverlost.receipt.v1";at_utc=(Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ");action="sign";ok=$true;principal=$Principal;key_id=$KeyId;namespace=$Namespace;file=(RelPathUnix $Root $fAbs);file_sha256=$fHash;sig=(RelPathUnix $Root $sigPath);sig_sha256=$sigHash})'
$ss += '("OK: " + (RelPathUnix $Root $sigPath))'
Write-Utf8NoBom -Path $sgPath -Text (($ss -join "`r`n") + "`r`n")
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $sgPath)) | Out-Null
"WROTE: scripts/sign_file_v1.ps1"

"DONE: NeverLost v1 installed for NFL"



