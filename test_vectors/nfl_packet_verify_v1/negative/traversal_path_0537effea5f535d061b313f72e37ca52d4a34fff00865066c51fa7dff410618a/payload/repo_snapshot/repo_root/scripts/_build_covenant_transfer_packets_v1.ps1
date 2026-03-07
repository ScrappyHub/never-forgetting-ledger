param(
  [Parameter(Mandatory=$true)][string]$RepoRoot,
  [Parameter(Mandatory=$true)][string]$Producer,
  [Parameter(Mandatory=$true)][string]$UsbRoot,
  [Parameter(Mandatory=$true)][string]$RuntimeRoot
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function EnsureDir([string]$p){
  if (-not $p -or $p.Trim().Length -eq 0) { return }
  if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}
function WriteUtf8([string]$path, [string]$content){
  EnsureDir (Split-Path -Parent $path)
  if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
  [IO.File]::WriteAllText($path, $content, (Utf8NoBom))
  if (-not (Test-Path -LiteralPath $path)) { Die ("WRITE_FAILED: " + $path) }
}
function ReadBytes([string]$path){ [IO.File]::ReadAllBytes($path) }
function Sha256HexBytes([byte[]]$b){
  $sha = [System.Security.Cryptography.SHA256]::Create()
  ($sha.ComputeHash($b) | ForEach-Object { $_.ToString("x2") }) -join ""
}
function Sha256HexFile([string]$path){ Sha256HexBytes (ReadBytes $path) }

function CanonJson([object]$o){
  function Normalize($x){
    if ($null -eq $x) { return $null }
    if ($x -is [System.Collections.IDictionary]){
      $keys = @($x.Keys) | Sort-Object
      $h = [ordered]@{}
      foreach ($k in $keys){ $h[[string]$k] = Normalize $x[$k] }
      return $h
    }
    if ($x -is [System.Collections.IEnumerable] -and -not ($x -is [string])){
      $arr = @()
      foreach ($i in $x){ $arr += ,(Normalize $i) }
      return $arr
    }
    return $x
  }
  $n = Normalize $o
  return ($n | ConvertTo-Json -Depth 200 -Compress)
}

function FindSshKeygen(){
  $cmd = Get-Command ssh-keygen -ErrorAction SilentlyContinue
  if (-not $cmd) { Die "MISSING_TOOL: ssh-keygen not found. Install OpenSSH Client." }
  return $cmd.Source
}

function DiscoverEd25519SigningKey([string]$RepoRoot, [string]$RuntimeRoot){
  # IMPORTANT: force arrays at every step (PS5.1 StrictMode safe)
  $candidates = @()

  $repoHits = @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match 'id_ed25519$|ed25519.*\.key$|sign.*ed25519' })
  if ($repoHits.Count -gt 0) { $candidates += $repoHits }

  if (Test-Path -LiteralPath $RuntimeRoot){
    $runHits = @(Get-ChildItem -LiteralPath $RuntimeRoot -Recurse -File -ErrorAction SilentlyContinue |
      Where-Object { $_.Name -match 'id_ed25519$|ed25519.*\.key$|sign.*ed25519' })
    if ($runHits.Count -gt 0) { $candidates += $runHits }
  }

  $homeSsh = Join-Path $env:USERPROFILE ".ssh\id_ed25519"
  if (Test-Path -LiteralPath $homeSsh) { $candidates += @(Get-Item -LiteralPath $homeSsh) }

  $candidates = @($candidates) | Where-Object { $_ -and $_.FullName -and ($_.FullName -notmatch '\.pub$') } | Select-Object -Unique

  $n = @($candidates).Count
  if ($n -eq 0){
    Die "MISSING_SIGNING_KEY: no ed25519 private key found (repo/runtime/.ssh). Put exactly one private key at $env:USERPROFILE\.ssh\id_ed25519 or under C:\ProgramData\CovenantGate\keys\"
  }
  if ($n -gt 1){
    Write-Host "AMBIGUOUS_SIGNING_KEY: found multiple candidates" -ForegroundColor Yellow
    @($candidates) | ForEach-Object { Write-Host ("KEY_CANDIDATE: " + $_.FullName) -ForegroundColor DarkGray }
    Die "AMBIGUOUS_SIGNING_KEY"
  }
  return @($candidates)[0].FullName
}

function PublicKeyFromPrivate([string]$sshKeygen, [string]$privPath, [string]$outPub){
  $pubText = & $sshKeygen -y -f $privPath 2>$null
  if (-not $pubText) { Die ("FAILED_DERIVE_PUBKEY_FROM_PRIV: " + $privPath) }
  WriteUtf8 $outPub ($pubText.Trim() + "`n")
}

function Rfc3339UtcNow(){ (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

function CopyTree([string]$src, [string]$dst, [string[]]$excludeRel){
  EnsureDir $dst
  $srcResolved = (Resolve-Path -LiteralPath $src).Path
  if (-not (Test-Path -LiteralPath $dst)) { EnsureDir $dst }
  $dstResolved = (Resolve-Path -LiteralPath $dst).Path

  $ex = @($excludeRel | ForEach-Object { $_.Replace("/", "\").TrimStart("\") })
  $items = @(Get-ChildItem -LiteralPath $srcResolved -Recurse -Force)

  foreach ($it in $items){
    $rel = $it.FullName.Substring($srcResolved.Length).TrimStart("\")
    $skip = $false
    foreach ($x in $ex){
      if ($rel -like ($x + "*")) { $skip = $true; break }
    }
    if ($skip) { continue }

    $target = Join-Path $dstResolved $rel
    if ($it.PSIsContainer){
      EnsureDir $target
    } else {
      EnsureDir (Split-Path -Parent $target)
      Copy-Item -LiteralPath $it.FullName -Destination $target -Force
    }
  }
}

function WriteSha256Sums([string]$packetRoot){
  $sumPath = Join-Path $packetRoot "sha256sums.txt"
  $files = @(Get-ChildItem -LiteralPath $packetRoot -Recurse -File | Where-Object { $_.Name -ne "sha256sums.txt" })
  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($f in $files){
    $rel = $f.FullName.Substring($packetRoot.Length).TrimStart("\").Replace("\","/")
    $h = Sha256HexFile $f.FullName
    $lines.Add(("{0}  {1}" -f $h, $rel))
  }
  $sorted = $lines | Sort-Object
  WriteUtf8 $sumPath (($sorted -join "`n") + "`n")
}

function BuildManifest([string]$packetRoot, [string]$producer, [string]$producerInstance, [string]$createdAtUtc){
  $files = @(Get-ChildItem -LiteralPath $packetRoot -Recurse -File | Where-Object { $_.Name -ne "manifest.json" })
  $arr = @()
  foreach ($f in $files){
    $rel = $f.FullName.Substring($packetRoot.Length).TrimStart("\").Replace("\","/")
    $arr += [ordered]@{ path=$rel; bytes=[int64]$f.Length; sha256=(Sha256HexFile $f.FullName) }
  }
  $arr = $arr | Sort-Object path

  $manifestNoId = [ordered]@{
    schema = "packet_manifest.v1"
    producer = $producer
    producer_instance = $producerInstance
    created_at_utc = $createdAtUtc
    files = $arr
  }

  $canonNoId = (CanonJson $manifestNoId)
  $packetId = Sha256HexBytes ((Utf8NoBom).GetBytes($canonNoId))

  $manifest = [ordered]@{
    schema = "packet_manifest.v1"
    packet_id = $packetId
    producer = $producer
    producer_instance = $producerInstance
    created_at_utc = $createdAtUtc
    files = $arr
  }

  WriteUtf8 (Join-Path $packetRoot "manifest.json") (CanonJson $manifest)
  return $packetId
}

function SignEnvelope([string]$sshKeygen, [string]$privKey, [string]$namespace, [string]$msgPath, [string]$sigPath){
  EnsureDir (Split-Path -Parent $sigPath)
  & $sshKeygen -Y sign -f $privKey -n $namespace $msgPath | Out-Null
  $produced = ($msgPath + ".sig")
  if (-not (Test-Path -LiteralPath $produced)) { Die ("SIGN_FAILED: expected " + $produced) }
  if (Test-Path -LiteralPath $sigPath) { Remove-Item -LiteralPath $sigPath -Force }
  Move-Item -LiteralPath $produced -Destination $sigPath -Force
  if (-not (Test-Path -LiteralPath $sigPath)) { Die ("SIGN_MOVE_FAILED: " + $sigPath) }
}

function VerifySha256Sums([string]$packetRoot){
  $sumPath = Join-Path $packetRoot "sha256sums.txt"
  if (-not (Test-Path -LiteralPath $sumPath)) { Die ("MISSING_SHA256SUMS: " + $sumPath) }
  $lines = Get-Content -LiteralPath $sumPath
  foreach ($ln in $lines){
    if (-not $ln.Trim()) { continue }
    $parts = $ln.Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries)
    if (@($parts).Count -lt 2) { Die ("BAD_SHA256SUMS_LINE: " + $ln) }
    $h = $parts[0].ToLowerInvariant()
    $rel = $parts[1]
    $p = Join-Path $packetRoot ($rel.Replace("/","\"))
    if (-not (Test-Path -LiteralPath $p)) { Die ("MISSING_FILE_IN_PACKET: " + $rel) }
    $calc = (Sha256HexFile $p).ToLowerInvariant()
    if ($calc -ne $h){ Die ("HASH_MISMATCH: " + $rel + " expected=" + $h + " got=" + $calc) }
  }
}

# --- BEGIN ---
if (-not (Test-Path -LiteralPath $RepoRoot)) { Die ("MISSING_REPO_ROOT: " + $RepoRoot) }
EnsureDir $UsbRoot

$sshKeygen = FindSshKeygen
$privKey = DiscoverEd25519SigningKey $RepoRoot $RuntimeRoot

$producerInstance = ($env:COMPUTERNAME + "-offline-1")
$tenant = "single-tenant"
$principal = ($tenant + "/owner/user/keira")
$createdAt = Rfc3339UtcNow

$work = Join-Path $env:TEMP ("covenant_transfer_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss"))
EnsureDir $work

$usbOut = Join-Path $UsbRoot ("packets_" + (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss"))
EnsureDir $usbOut

Write-Host "== COVENANT TRANSFER PACKETS v1 ==" -ForegroundColor Cyan
Write-Host ("RepoRoot: {0}" -f $RepoRoot) -ForegroundColor DarkGray
Write-Host ("RuntimeRoot: {0}" -f $RuntimeRoot) -ForegroundColor DarkGray
Write-Host ("USB Out: {0}" -f $usbOut) -ForegroundColor DarkGray
Write-Host ("SigningKey: {0}" -f $privKey) -ForegroundColor DarkGray

$pubKeyPath = Join-Path $work "signer_ed25519.pub"
PublicKeyFromPrivate $sshKeygen $privKey $pubKeyPath

function BuildPacket([string]$kind, [string]$payloadSrc, [string]$eventType){
  $packetTemp = Join-Path $work ("packet_" + $kind)
  if (Test-Path -LiteralPath $packetTemp) { Remove-Item -LiteralPath $packetTemp -Recurse -Force }
  EnsureDir $packetTemp

  $payloadDir = Join-Path $packetTemp "payload"
  $sigDir     = Join-Path $packetTemp "signatures"
  EnsureDir $payloadDir
  EnsureDir $sigDir

  CopyTree $payloadSrc (Join-Path $payloadDir $kind) @()

  $commit = [ordered]@{
    schema = "commitment.v1"
    producer = $Producer
    producer_instance = $producerInstance
    tenant = $tenant
    principal = $principal
    event_type = $eventType
    event_time_utc = $createdAt
    prev_links = @()
    content_ref = ("payload/" + $kind)
    strength = "evidence"
    meta = [ordered]@{ snapshot_kind=$kind; host=$env:COMPUTERNAME }
  }

  $commitJson = CanonJson $commit
  WriteUtf8 (Join-Path $payloadDir "commit.payload.json") $commitJson
  $commitHash = Sha256HexBytes ((Utf8NoBom).GetBytes($commitJson))
  WriteUtf8 (Join-Path $payloadDir "commit_hash.txt") ($commitHash + "`n")

  $ingest = [ordered]@{
    schema = "nfl.ingest.v1"
    packet_id = ""
    commit_hash = $commitHash
    producer = $Producer
    producer_instance = $producerInstance
    tenant = $tenant
    principal = $principal
    event_type = $eventType
    event_time_utc = $createdAt
    prev_links = @()
    payload_mode = "pointer_only"
    payload_ref = ("payload/" + $kind)
    producer_key_id = "ed25519:auto"
    producer_sig_ref = "signatures/ingest.sig"
  }
  $ingestPath = Join-Path $payloadDir "nfl.ingest.json"
  WriteUtf8 $ingestPath (CanonJson $ingest)

  $sigEnvelope = [ordered]@{
    schema = "sig_envelope.v1"
    algo = "ed25519"
    key_id = "ed25519:auto"
    signing_context = "nfl.ingest.v1"
    signs = [ordered]@{ commit_hash=$commitHash; packet_id=""; ingest_hash="" }
    principal = $principal
    namespace = "covenant-nfl"
  }
  $sigEnvPath = Join-Path $payloadDir "sig_envelope.json"
  WriteUtf8 $sigEnvPath (CanonJson $sigEnvelope)

  WriteSha256Sums $packetTemp
  $packetId = BuildManifest $packetTemp $Producer $producerInstance $createdAt

  $ingest.packet_id = $packetId
  $ingestCanon = CanonJson $ingest
  WriteUtf8 $ingestPath $ingestCanon
  $ingestHash = Sha256HexBytes ((Utf8NoBom).GetBytes($ingestCanon))

  $sigEnvelope.signs.packet_id = $packetId
  $sigEnvelope.signs.ingest_hash = $ingestHash
  WriteUtf8 $sigEnvPath (CanonJson $sigEnvelope)

  SignEnvelope $sshKeygen $privKey "covenant-nfl" $sigEnvPath (Join-Path $sigDir "ingest.sig")

  WriteSha256Sums $packetTemp
  $packetId2 = BuildManifest $packetTemp $Producer $producerInstance $createdAt
  if ($packetId2 -ne $packetId){ Die ("PACKET_ID_CHANGED_AFTER_FINALIZE: " + $packetId + " -> " + $packetId2) }

  VerifySha256Sums $packetTemp

  $final = Join-Path $usbOut $packetId
  if (Test-Path -LiteralPath $final) { Die ("USB_ALREADY_HAS_PACKET: " + $final) }
  CopyTree $packetTemp $final @()
  Copy-Item -LiteralPath $pubKeyPath -Destination (Join-Path $final "signer_ed25519.pub") -Force

  Write-Host ("PACKET_OK: {0}  kind={1}" -f $packetId, $kind) -ForegroundColor Green
  return $packetId
}

$repoPayloadSrc = Join-Path $work "payload_repo"
EnsureDir $repoPayloadSrc
$exclude = @(".git\objects",".git\logs","node_modules","supabase\.temp","bin","obj","dist",".next",".venv","__pycache__", ".DS_Store")
CopyTree $RepoRoot (Join-Path $repoPayloadSrc "repo_root") $exclude

$runtimePayloadSrc = Join-Path $work "payload_runtime"
EnsureDir $runtimePayloadSrc
if (-not (Test-Path -LiteralPath $RuntimeRoot)) { Die ("MISSING_RUNTIME_ROOT: " + $RuntimeRoot) }

foreach ($d in @("pledges","outbox","keys")){
  $src = Join-Path $RuntimeRoot $d
  if (Test-Path -LiteralPath $src){
    CopyTree $src (Join-Path $runtimePayloadSrc $d) @()
  }
}

if (-not (Test-Path -LiteralPath (Join-Path $RuntimeRoot "pledges\pledges.ndjson"))) { Die "MISSING_RUNTIME: pledges\pledges.ndjson not found" }
if (-not (Test-Path -LiteralPath (Join-Path $RuntimeRoot "outbox"))) { Die "MISSING_RUNTIME: outbox not found" }

$repoPacketId = BuildPacket "repo_snapshot" $repoPayloadSrc "covenant.snapshot.repo.v1"
$runPacketId  = BuildPacket "runtime_snapshot" $runtimePayloadSrc "covenant.snapshot.runtime.v1"

Write-Host "== DONE ==" -ForegroundColor Cyan
Write-Host ("USB Packet Folder: {0}" -f $usbOut) -ForegroundColor Green
Write-Host ("Repo PacketId: {0}" -f $repoPacketId) -ForegroundColor DarkGray
Write-Host ("Runtime PacketId: {0}" -f $runPacketId) -ForegroundColor DarkGray