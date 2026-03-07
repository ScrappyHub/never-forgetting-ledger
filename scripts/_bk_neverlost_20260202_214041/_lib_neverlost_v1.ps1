$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Write-Utf8NoBom([string]$Path, [string]$Text) {
  $enc = [System.Text.UTF8Encoding]::new($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $sw = [System.IO.StreamWriter]::new($Path, $false, $enc)
  try { $sw.Write($Text) } finally { $sw.Dispose() }
}

function Read-Utf8([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { throw ("Missing: " + $Path) }
  return [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false))
}

function Sha256HexBytes([byte[]]$Bytes) {
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try { ($sha.ComputeHash($Bytes) | ForEach-Object { $_.ToString("x2") }) -join "" } finally { $sha.Dispose() }
}

function Sha256HexPath([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { throw ("Missing: " + $Path) }
  $bytes = [System.IO.File]::ReadAllBytes($Path)
  return Sha256HexBytes -Bytes $bytes
}

function ResolveRealPath([string]$Path) { (Resolve-Path -LiteralPath $Path).Path }

function RelPathUnix([string]$Root, [string]$Path) {
  $r = (ResolveRealPath $Root).TrimEnd("\")
  $p = (ResolveRealPath $Path)
  if ($p -notlike ($r + "\*")) { return ($p -replace "\\","/") }
  $rel = $p.Substring($r.Length).TrimStart("\")
  return ($rel -replace "\\","/")
}

function AssertPrincipalFormat([string]$Principal) {
  if ([string]::IsNullOrWhiteSpace($Principal)) { throw "Principal empty" }
  if ($Principal -notmatch "^single-tenant\/[^\/]+\/authority\/[^\/]+$") { throw ("Principal format invalid: " + $Principal) }
}

function AssertKeyIdFormat([string]$KeyId) {
  if ([string]::IsNullOrWhiteSpace($KeyId)) { throw "KeyId empty" }
  if ($KeyId -notmatch "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$") { throw ("KeyId format invalid: " + $KeyId) }
}

function ConvertTo-Ordered([object]$Obj) {
  if ($null -eq $Obj) { return $null }
  if ($Obj -is [System.Collections.IDictionary]) {
    $keys = @($Obj.Keys) | Sort-Object
    $h = [ordered]@{}
    foreach ($k in $keys) { $h[$k] = ConvertTo-Ordered $Obj[$k] }
    return $h
  }
  if (($Obj -is [System.Collections.IEnumerable]) -and -not ($Obj -is [string])) {
    $arr = @()
    foreach ($it in $Obj) { $arr += ,(ConvertTo-Ordered $it) }
    return $arr
  }
  return $Obj
}

function To-CanonJson([object]$Obj) { (ConvertTo-Ordered $Obj | ConvertTo-Json -Depth 100 -Compress) }

function LoadTrustBundle([string]$TrustBundlePath) {
  $raw = Read-Utf8 $TrustBundlePath
  $tb = $raw | ConvertFrom-Json -Depth 100
  if ($null -eq $tb) { throw "trust_bundle parsed null" }
  if ($tb.schema -ne "neverlost.trust_bundle.v1") { throw ("Unsupported trust_bundle schema: " + [string]$tb.schema) }
  if ($null -eq $tb.trust) { throw "trust_bundle missing trust[]" }
  foreach ($t in $tb.trust) {
    AssertPrincipalFormat ([string]$t.principal)
    AssertKeyIdFormat ([string]$t.key_id)
    if ([string]::IsNullOrWhiteSpace([string]$t.pubkey_sha256)) { throw "trust record missing pubkey_sha256" }
    if ([string]::IsNullOrWhiteSpace([string]$t.pubkey_path)) { throw "trust record missing pubkey_path" }
    if ($null -eq $t.namespaces) { throw "trust record missing namespaces[]" }
  }
  return $tb
}

function WriteAllowedSignersFile([string]$AllowedSignersPath, [string[]]$Lines) {
  $enc = [System.Text.UTF8Encoding]::new($false)
  $txt = ($Lines -join "`r`n") + "`r`n"
  $sw = [System.IO.StreamWriter]::new($AllowedSignersPath, $false, $enc)
  try { $sw.Write($txt) } finally { $sw.Dispose() }
}

function Write-NeverLostReceipt([string]$ReceiptsPath, [hashtable]$Obj) {
  $enc = [System.Text.UTF8Encoding]::new($false)
  $line = (To-CanonJson $Obj) + "`r`n"
  $fs = [System.IO.File]::Open($ReceiptsPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
  try {
    $sw = [System.IO.StreamWriter]::new($fs, $enc)
    try { $sw.Write($line) } finally { $sw.Dispose() }
  } finally { $fs.Dispose() }
}

function SshYSignFile([string]$KeyPath, [string]$Namespace, [string]$FilePath, [string]$SigPath) {
  if ([string]::IsNullOrWhiteSpace($Namespace)) { throw "Namespace empty" }
  if (-not (Test-Path -LiteralPath $KeyPath)) { throw ("Missing key: " + $KeyPath) }
  if (-not (Test-Path -LiteralPath $FilePath)) { throw ("Missing file: " + $FilePath) }
  & ssh-keygen -Y sign -f $KeyPath -n $Namespace $FilePath | Out-Null
  $defaultSig = $FilePath + ".sig"
  if (-not (Test-Path -LiteralPath $defaultSig)) { throw "ssh-keygen did not produce .sig" }
  if ($SigPath -ne $defaultSig) { Copy-Item -LiteralPath $defaultSig -Destination $SigPath -Force }
}

function SshYVerifyFile([string]$AllowedSignersPath, [string]$Namespace, [string]$Principal, [string]$FilePath, [string]$SigPath) {
  if ([string]::IsNullOrWhiteSpace($Namespace)) { throw "Namespace empty" }
  AssertPrincipalFormat $Principal
  if (-not (Test-Path -LiteralPath $AllowedSignersPath)) { throw ("Missing allowed_signers: " + $AllowedSignersPath) }
  if (-not (Test-Path -LiteralPath $FilePath)) { throw ("Missing file: " + $FilePath) }
  if (-not (Test-Path -LiteralPath $SigPath)) { throw ("Missing sig: " + $SigPath) }
  $tmpRev = [System.IO.Path]::GetTempFileName()
  try {
    # -I must match the principal identity in allowed_signers
    & ssh-keygen -Y verify -f $AllowedSignersPath -I $Principal -n $Namespace -s $SigPath -r $tmpRev $FilePath | Out-Null
  } finally { Remove-Item -LiteralPath $tmpRev -Force -ErrorAction SilentlyContinue }
}
