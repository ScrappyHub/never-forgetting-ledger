$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Get-Sha256Hex([string]$Path) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Read-Json([string]$Path) {
  Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Write-Json([string]$Path, $Obj) {
  $json = $Obj | ConvertTo-Json -Depth 100
  Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Parse-Sha256Sums([string]$Path) {
  $lines = Get-Content -LiteralPath $Path
  $pairs = @()
  foreach ($line in $lines) {
    if (-not $line) { continue }
    $m = [regex]::Match($line, '^(?<h>[0-9a-fA-F]{64})\s\s(?<p>.+)$')
    if (-not $m.Success) { throw "Bad sha256sums line: $line" }
    $pairs += [pscustomobject]@{
      hash = $m.Groups["h"].Value.ToLowerInvariant()
      rel  = $m.Groups["p"].Value
    }
  }
  $pairs
}

function Ensure-Dir([string]$Path) {
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Canon-NdjsonLineHash([string]$Line) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Line)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
  } finally {
    $sha.Dispose()
  }
}

function Append-PledgeLine([string]$LogPath, [hashtable]$Obj) {
  Ensure-Dir (Split-Path -Parent $LogPath)

  # Determine prev_log_hash
  $prev = "GENESIS"
  if (Test-Path -LiteralPath $LogPath) {
    $tail = Get-Content -LiteralPath $LogPath -Tail 1 -ErrorAction SilentlyContinue
    if ($tail) {
      try {
        $t = $tail | ConvertFrom-Json
        if ($t.log_hash) { $prev = [string]$t.log_hash }
      } catch { }
    }
  }

  # Determine seq
  $seq = 1
  if (Test-Path -LiteralPath $LogPath) {
    $tail2 = Get-Content -LiteralPath $LogPath -Tail 1 -ErrorAction SilentlyContinue
    if ($tail2) {
      try {
        $t2 = $tail2 | ConvertFrom-Json
        if ($t2.seq) { $seq = ([int]$t2.seq) + 1 }
      } catch { }
    }
  }

  $Obj.prev_log_hash = $prev
  $Obj.seq = $seq

  # Compute log_hash over canonical NDJSON line WITHOUT log_hash field (bytes of compressed JSON)
  $Obj2 = [ordered]@{}
  foreach ($k in $Obj.Keys) { if ($k -ne "log_hash") { $Obj2[$k] = $Obj[$k] } }

  $lineNoHash = ([pscustomobject]$Obj2) | ConvertTo-Json -Compress -Depth 50
  $logHash = Canon-NdjsonLineHash $lineNoHash

  $Obj.log_hash = $logHash
  $finalLine = ([pscustomobject]$Obj) | ConvertTo-Json -Compress -Depth 50
  Add-Content -LiteralPath $LogPath -Value $finalLine -Encoding UTF8
  return $Obj
}
function Verify-PacketBasic([string]$PacketDir, [string]$PacketIdDirName) {
  $manifestPath = Join-Path $PacketDir "manifest.json"
  $sumsPath     = Join-Path $PacketDir "sha256sums.txt"

  if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Missing manifest.json" }
  if (-not (Test-Path -LiteralPath $sumsPath))     { throw "Missing sha256sums.txt" }

  # sha256sums validates referenced files
  $pairs = Parse-Sha256Sums -Path $sumsPath
  foreach ($p in $pairs) {
    $rel = $p.rel -replace "/", "\"
    $fp  = Join-Path $PacketDir $rel
    if (-not (Test-Path -LiteralPath $fp)) { throw "sha256sums references missing file: $($p.rel)" }
    $actual = Get-Sha256Hex -Path $fp
    if ($actual -ne $p.hash) { throw "sha256 mismatch: $($p.rel) expected=$($p.hash) actual=$actual" }
  }

  $m = Read-Json -Path $manifestPath

  # Accept both schema spellings
  $okSchemas = @("packet.manifest.v1","packet_manifest.v1")
  if (-not ($okSchemas -contains [string]$m.schema)) { throw ("manifest schema mismatch: " + [string]$m.schema) }

  $payloadDir    = Join-Path $PacketDir "payload"
  $commitPayload = Join-Path $payloadDir "commit.payload.json"
  $commitHashTxt = Join-Path $payloadDir "commit_hash.txt"
  if (-not (Test-Path -LiteralPath $commitPayload)) { throw "Missing payload/commit.payload.json" }
  if (-not (Test-Path -LiteralPath $commitHashTxt)) { throw "Missing payload/commit_hash.txt" }

  $decl = (Get-Content -Raw -LiteralPath $commitHashTxt).Trim().ToLowerInvariant()
  $recomputed = Get-Sha256Hex -Path $commitPayload
  if ($recomputed -ne $decl) { throw "CommitHash mismatch: declared=$decl recomputed=$recomputed" }

  # Identity source-of-truth: inbox directory name
  $pid = [string]$PacketIdDirName

  # Optional evidence from manifest (do not rely on it)
  $declared = $null
  try { $declared = $m.packet_id } catch { }

  [pscustomobject]@{
    packet_id          = $pid
    declared_packet_id = $declared
    commit_hash        = $decl
    producer           = [string]$m.producer
    producer_instance  = [string]$m.producer_instance
    created_at_utc     = [string]$m.created_at_utc
    manifest_schema    = [string]$m.schema
  }
}function Emit-NflReceivePacket(
  [string]$NflOutboxRoot,
  [string]$PacketId,
  [string]$CommitHash,
  [string]$Status,
  [string]$VerifiedAtUtc
) {
  Ensure-Dir $NflOutbox
Ensure-Dir $SeenDirRoot

  # NFL "receive" commitment payload (NFL is the producer of THIS commitment)
  $commit = [ordered]@{
    schema = "commitment.v1"
    producer = "nfl"
    producer_instance = "nfl-local-1"
    tenant = "single-tenant"
    principal = "single-tenant/nfl_authority/authority/nfl"
    event_type = "nfl.packet.received.v1"
    event_time_utc = $VerifiedAtUtc
    prev_links = @($PacketId, $CommitHash)
    content_ref = "sealed"
    strength = "evidence"
    meta = [ordered]@{
      observed_packet_id = $PacketId
      observed_commit_hash = $CommitHash
      observed_status = $Status
    }
  }

  # Write packet files
  $tmp = Join-Path $env:TEMP ("nfl_receive_" + [guid]::NewGuid().ToString("n") )
  Ensure-Dir $tmp
  Ensure-Dir (Join-Path $tmp "payload")
  Ensure-Dir (Join-Path $tmp "signatures")

  $commitPath = Join-Path $tmp "payload\commit.payload.json"
  ($commit | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $commitPath -Encoding UTF8

  $commitHash = Get-Sha256Hex -Path $commitPath
  Set-Content -LiteralPath (Join-Path $tmp "payload\commit_hash.txt") -Value $commitHash -Encoding UTF8

  # Minimal ingest envelope (no signature yet; signature verification/issuance is next lock)
  $ing = [ordered]@{
    schema="nfl.ingest.v1"
    packet_id=""   # filled after manifest
    commit_hash=$commitHash
    producer="nfl"
    producer_instance="nfl-local-1"
    tenant="single-tenant"
    principal="single-tenant/nfl_authority/authority/nfl"
    event_type="nfl.packet.received.v1"
    event_time_utc=$VerifiedAtUtc
    prev_links=@($PacketId,$CommitHash)
    payload_mode="inline_sealed"
    payload_ref="payload/commit.payload.json"
    producer_key_id="nfl-authority-ed25519"
    producer_sig_ref="signatures/ingest.sig"
  }
  ($ing | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath (Join-Path $tmp "payload\nfl.ingest.json") -Encoding UTF8

  $sigEnv = [ordered]@{
    schema="sig_envelope.v1"
    algo="ed25519"
    key_id="nfl-authority-ed25519"
    signing_context="nfl.ingest.v1"
    signs=[ordered]@{
      commit_hash=$commitHash
      packet_id="(pending)"
      ingest_hash="(pending)"
    }
  }
  ($sigEnv | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath (Join-Path $tmp "payload\sig_envelope.json") -Encoding UTF8

  # Placeholder signature file until keys/signing are locked
  Set-Content -LiteralPath (Join-Path $tmp "signatures\ingest.sig") -Value "UNSIGNED" -Encoding UTF8

  # Manifest + sha256sums
  $files = @(
    "manifest.json",
    "sha256sums.txt",
    "payload/commit.payload.json",
    "payload/commit_hash.txt",
    "payload/nfl.ingest.json",
    "payload/sig_envelope.json",
    "signatures/ingest.sig"
  )

  # Create preliminary manifest (packet_id filled after we hash manifest itself)
  $man = [ordered]@{
    schema="packet_manifest.v1"
    packet_id="(pending)"
    producer="nfl"
    producer_instance="nfl-local-1"
    created_at_utc=$VerifiedAtUtc
    files=@()
  }

  foreach ($f in $files | Where-Object { $_ -ne "manifest.json" -and $_ -ne "sha256sums.txt" }) {
    $fp = Join-Path $tmp ($f -replace "/", "\")
    $man.files += [ordered]@{ path=$f; bytes=(Get-Item -LiteralPath $fp).Length; sha256=(Get-Sha256Hex -Path $fp) }
  }

  # Write manifest with pending packet_id, compute packet_id as hash(manifest bytes)
  $manPath = Join-Path $tmp "manifest.json"
  ($man | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $manPath -Encoding UTF8
  $packetId = Get-Sha256Hex -Path $manPath

  # Rewrite manifest with real packet_id
  $man.packet_id = $packetId
  ($man | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $manPath -Encoding UTF8

  # Rewrite ingest + sig envelope with packet_id and ingest_hash
  $ing.packet_id = $packetId
  $ingPath = Join-Path $tmp "payload\nfl.ingest.json"
  ($ing | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $ingPath -Encoding UTF8
  $ingHash = Get-Sha256Hex -Path $ingPath

  $sigEnv.signs.packet_id = $packetId
  $sigEnv.signs.ingest_hash = $ingHash
  ($sigEnv | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath (Join-Path $tmp "payload\sig_envelope.json") -Encoding UTF8

  # Write sha256sums.txt
  $sumLines = @()
  foreach ($f in $files | Where-Object { $_ -ne "sha256sums.txt" }) {
    $fp = Join-Path $tmp ($f -replace "/", "\")
    $h = Get-Sha256Hex -Path $fp
    $sumLines += ($h + "  " + $f)
  }
  Set-Content -LiteralPath (Join-Path $tmp "sha256sums.txt") -Value ($sumLines -join "`n") -Encoding UTF8

  # Move to outbox under PacketId
  $dest = Join-Path $NflOutboxRoot $packetId
  if (Test-Path -LiteralPath $dest) { return $packetId } # idempotent
  Move-Item -LiteralPath $tmp -Destination $dest
  return $packetId
}

# Paths
$Inbox        = "C:\ProgramData\NFL\inbox"
$Index        = "C:\ProgramData\NFL\index\index.ndjson"
$ReportsDir   = "C:\ProgramData\NFL\reports"
$NflPledges   = "C:\ProgramData\NFL\pledges\pledges.ndjson"
$NflOutbox    = "C:\ProgramData\NFL\outbox"
$SeenDir      = "C:\ProgramData\NFL\state\seen"

Ensure-Dir $Inbox
Ensure-Dir (Split-Path -Parent $Index)
Ensure-Dir $ReportsDir
Ensure-Dir (Split-Path -Parent $NflPledges)
Ensure-Dir $NflOutbox
Ensure-Dir $SeenDir

$packets = @(Get-ChildItem -LiteralPath $Inbox -Directory -ErrorAction Stop)

if (-not $packets -or $packets.Count -eq 0) {
  "NFL: inbox empty"
  exit 0
}

$outLines = @()
foreach ($p in $packets) {
  $packetIdDir = $p.Name

  # Idempotency: process each inbox packet once
  $seenMarker = Join-Path $SeenDir ($packetIdDir + ".seen")
  if (Test-Path -LiteralPath $seenMarker) {
    continue
  }
  $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  try {
    $r = Verify-PacketBasic -PacketDir $p.FullName -PacketIdDirName $packetIdDir
    # Index row
    $row = [ordered]@{
      schema            = "nfl.index_row.v1"
      packet_id         = $packetIdDir
      commit_hash       = $r.commit_hash
      producer          = $r.producer
      producer_instance = $r.producer_instance
      created_at_utc    = $r.created_at_utc
      verified_at_utc   = $now
      status            = "verified_basic"
    }
    $outLines += (([pscustomobject]$row) | ConvertTo-Json -Compress -Depth 50)

    # NFL pledge: "received + processed"
    $pledge = [ordered]@{
      schema="nfl.local_pledge.v1"
      created_at_utc=$now
      producer="nfl"
      producer_instance="nfl-local-1"
      tenant="single-tenant"
      principal="single-tenant/nfl_authority/authority/nfl"
      key_id="nfl-authority-ed25519"
      commit_hash=$r.commit_hash
      observed_packet_id=$packetIdDir
      observed_producer=$r.producer
      observed_producer_instance=$r.producer_instance
      status="received_verified_basic"
      sig_path=("outbox/(pending)/signatures/ingest.sig")
    }
    $pledgeWritten = Append-PledgeLine -LogPath $NflPledges -Obj $pledge

    # Emit NFL receive packet (artifact) and backfill sig_path to the new outbox packet
    $nflPacketId = Emit-NflReceivePacket -NflOutboxRoot $NflOutbox -PacketId $packetIdDir -CommitHash $r.commit_hash -Status "received_verified_basic" -VerifiedAtUtc $now

    # Append a second pledge line that binds the outbox packet id deterministically
    $pledge2 = [ordered]@{
      schema="nfl.local_pledge.v1"
      created_at_utc=$now
      producer="nfl"
      producer_instance="nfl-local-1"
      tenant="single-tenant"
      principal="single-tenant/nfl_authority/authority/nfl"
      key_id="nfl-authority-ed25519"
      commit_hash=$r.commit_hash
      observed_packet_id=$packetIdDir
      status="nfl_receive_packet_emitted"
      nfl_packet_id=$nflPacketId
      sig_path=("outbox/" + $nflPacketId + "/signatures/ingest.sig")
    }
    [void](Append-PledgeLine -LogPath $NflPledges -Obj $pledge2)

# Mark as seen only after we have indexed + pledged + emitted NFL receive packet
Set-Content -LiteralPath $seenMarker -Value $now -Encoding UTF8

  } catch {
    $err = $ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Get-Sha256Hex([string]$Path) {
  (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant()
}

function Read-Json([string]$Path) {
  Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Write-Json([string]$Path, $Obj) {
  $json = $Obj | ConvertTo-Json -Depth 100
  Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Parse-Sha256Sums([string]$Path) {
  $lines = Get-Content -LiteralPath $Path
  $pairs = @()
  foreach ($line in $lines) {
    if (-not $line) { continue }
    $m = [regex]::Match($line, '^(?<h>[0-9a-fA-F]{64})\s\s(?<p>.+)$')
    if (-not $m.Success) { throw "Bad sha256sums line: $line" }
    $pairs += [pscustomobject]@{
      hash = $m.Groups["h"].Value.ToLowerInvariant()
      rel  = $m.Groups["p"].Value
    }
  }
  $pairs
}

function Ensure-Dir([string]$Path) {
  New-Item -ItemType Directory -Force -Path $Path | Out-Null
}

function Canon-NdjsonLineHash([string]$Line) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Line)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString("x2") }) -join ""
  } finally {
    $sha.Dispose()
  }
}

function Append-PledgeLine([string]$LogPath, [hashtable]$Obj) {
  Ensure-Dir (Split-Path -Parent $LogPath)

  # Determine prev_log_hash
  $prev = "GENESIS"
  if (Test-Path -LiteralPath $LogPath) {
    $tail = Get-Content -LiteralPath $LogPath -Tail 1 -ErrorAction SilentlyContinue
    if ($tail) {
      try {
        $t = $tail | ConvertFrom-Json
        if ($t.log_hash) { $prev = [string]$t.log_hash }
      } catch { }
    }
  }

  # Determine seq
  $seq = 1
  if (Test-Path -LiteralPath $LogPath) {
    $tail2 = Get-Content -LiteralPath $LogPath -Tail 1 -ErrorAction SilentlyContinue
    if ($tail2) {
      try {
        $t2 = $tail2 | ConvertFrom-Json
        if ($t2.seq) { $seq = ([int]$t2.seq) + 1 }
      } catch { }
    }
  }

  $Obj.prev_log_hash = $prev
  $Obj.seq = $seq

  # Compute log_hash over canonical NDJSON line WITHOUT log_hash field (bytes of compressed JSON)
  $Obj2 = [ordered]@{}
  foreach ($k in $Obj.Keys) { if ($k -ne "log_hash") { $Obj2[$k] = $Obj[$k] } }

  $lineNoHash = ([pscustomobject]$Obj2) | ConvertTo-Json -Compress -Depth 50
  $logHash = Canon-NdjsonLineHash $lineNoHash

  $Obj.log_hash = $logHash
  $finalLine = ([pscustomobject]$Obj) | ConvertTo-Json -Compress -Depth 50
  Add-Content -LiteralPath $LogPath -Value $finalLine -Encoding UTF8
  return $Obj
}
function Verify-PacketBasic([string]$PacketDir, [string]$PacketIdDirName) {
  $manifestPath = Join-Path $PacketDir "manifest.json"
  $sumsPath     = Join-Path $PacketDir "sha256sums.txt"

  if (-not (Test-Path -LiteralPath $manifestPath)) { throw "Missing manifest.json" }
  if (-not (Test-Path -LiteralPath $sumsPath))     { throw "Missing sha256sums.txt" }

  # sha256sums validates referenced files
  $pairs = Parse-Sha256Sums -Path $sumsPath
  foreach ($p in $pairs) {
    $rel = $p.rel -replace "/", "\"
    $fp  = Join-Path $PacketDir $rel
    if (-not (Test-Path -LiteralPath $fp)) { throw "sha256sums references missing file: $($p.rel)" }
    $actual = Get-Sha256Hex -Path $fp
    if ($actual -ne $p.hash) { throw "sha256 mismatch: $($p.rel) expected=$($p.hash) actual=$actual" }
  }

  $m = Read-Json -Path $manifestPath

  # Accept both schema spellings
  $okSchemas = @("packet.manifest.v1","packet_manifest.v1")
  if (-not ($okSchemas -contains [string]$m.schema)) { throw ("manifest schema mismatch: " + [string]$m.schema) }

  $payloadDir    = Join-Path $PacketDir "payload"
  $commitPayload = Join-Path $payloadDir "commit.payload.json"
  $commitHashTxt = Join-Path $payloadDir "commit_hash.txt"
  if (-not (Test-Path -LiteralPath $commitPayload)) { throw "Missing payload/commit.payload.json" }
  if (-not (Test-Path -LiteralPath $commitHashTxt)) { throw "Missing payload/commit_hash.txt" }

  $decl = (Get-Content -Raw -LiteralPath $commitHashTxt).Trim().ToLowerInvariant()
  $recomputed = Get-Sha256Hex -Path $commitPayload
  if ($recomputed -ne $decl) { throw "CommitHash mismatch: declared=$decl recomputed=$recomputed" }

  # Identity source-of-truth: inbox directory name
  $pid = [string]$PacketIdDirName

  # Optional evidence from manifest (do not rely on it)
  $declared = $null
  try { $declared = $m.packet_id } catch { }

  [pscustomobject]@{
    packet_id          = $pid
    declared_packet_id = $declared
    commit_hash        = $decl
    producer           = [string]$m.producer
    producer_instance  = [string]$m.producer_instance
    created_at_utc     = [string]$m.created_at_utc
    manifest_schema    = [string]$m.schema
  }
}function Emit-NflReceivePacket(
  [string]$NflOutboxRoot,
  [string]$PacketId,
  [string]$CommitHash,
  [string]$Status,
  [string]$VerifiedAtUtc
) {
  Ensure-Dir $NflOutbox
Ensure-Dir $SeenDirRoot

  # NFL "receive" commitment payload (NFL is the producer of THIS commitment)
  $commit = [ordered]@{
    schema = "commitment.v1"
    producer = "nfl"
    producer_instance = "nfl-local-1"
    tenant = "single-tenant"
    principal = "single-tenant/nfl_authority/authority/nfl"
    event_type = "nfl.packet.received.v1"
    event_time_utc = $VerifiedAtUtc
    prev_links = @($PacketId, $CommitHash)
    content_ref = "sealed"
    strength = "evidence"
    meta = [ordered]@{
      observed_packet_id = $PacketId
      observed_commit_hash = $CommitHash
      observed_status = $Status
    }
  }

  # Write packet files
  $tmp = Join-Path $env:TEMP ("nfl_receive_" + [guid]::NewGuid().ToString("n") )
  Ensure-Dir $tmp
  Ensure-Dir (Join-Path $tmp "payload")
  Ensure-Dir (Join-Path $tmp "signatures")

  $commitPath = Join-Path $tmp "payload\commit.payload.json"
  ($commit | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $commitPath -Encoding UTF8

  $commitHash = Get-Sha256Hex -Path $commitPath
  Set-Content -LiteralPath (Join-Path $tmp "payload\commit_hash.txt") -Value $commitHash -Encoding UTF8

  # Minimal ingest envelope (no signature yet; signature verification/issuance is next lock)
  $ing = [ordered]@{
    schema="nfl.ingest.v1"
    packet_id=""   # filled after manifest
    commit_hash=$commitHash
    producer="nfl"
    producer_instance="nfl-local-1"
    tenant="single-tenant"
    principal="single-tenant/nfl_authority/authority/nfl"
    event_type="nfl.packet.received.v1"
    event_time_utc=$VerifiedAtUtc
    prev_links=@($PacketId,$CommitHash)
    payload_mode="inline_sealed"
    payload_ref="payload/commit.payload.json"
    producer_key_id="nfl-authority-ed25519"
    producer_sig_ref="signatures/ingest.sig"
  }
  ($ing | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath (Join-Path $tmp "payload\nfl.ingest.json") -Encoding UTF8

  $sigEnv = [ordered]@{
    schema="sig_envelope.v1"
    algo="ed25519"
    key_id="nfl-authority-ed25519"
    signing_context="nfl.ingest.v1"
    signs=[ordered]@{
      commit_hash=$commitHash
      packet_id="(pending)"
      ingest_hash="(pending)"
    }
  }
  ($sigEnv | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath (Join-Path $tmp "payload\sig_envelope.json") -Encoding UTF8

  # Placeholder signature file until keys/signing are locked
  Set-Content -LiteralPath (Join-Path $tmp "signatures\ingest.sig") -Value "UNSIGNED" -Encoding UTF8

  # Manifest + sha256sums
  $files = @(
    "manifest.json",
    "sha256sums.txt",
    "payload/commit.payload.json",
    "payload/commit_hash.txt",
    "payload/nfl.ingest.json",
    "payload/sig_envelope.json",
    "signatures/ingest.sig"
  )

  # Create preliminary manifest (packet_id filled after we hash manifest itself)
  $man = [ordered]@{
    schema="packet_manifest.v1"
    packet_id="(pending)"
    producer="nfl"
    producer_instance="nfl-local-1"
    created_at_utc=$VerifiedAtUtc
    files=@()
  }

  foreach ($f in $files | Where-Object { $_ -ne "manifest.json" -and $_ -ne "sha256sums.txt" }) {
    $fp = Join-Path $tmp ($f -replace "/", "\")
    $man.files += [ordered]@{ path=$f; bytes=(Get-Item -LiteralPath $fp).Length; sha256=(Get-Sha256Hex -Path $fp) }
  }

  # Write manifest with pending packet_id, compute packet_id as hash(manifest bytes)
  $manPath = Join-Path $tmp "manifest.json"
  ($man | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $manPath -Encoding UTF8
  $packetId = Get-Sha256Hex -Path $manPath

  # Rewrite manifest with real packet_id
  $man.packet_id = $packetId
  ($man | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $manPath -Encoding UTF8

  # Rewrite ingest + sig envelope with packet_id and ingest_hash
  $ing.packet_id = $packetId
  $ingPath = Join-Path $tmp "payload\nfl.ingest.json"
  ($ing | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $ingPath -Encoding UTF8
  $ingHash = Get-Sha256Hex -Path $ingPath

  $sigEnv.signs.packet_id = $packetId
  $sigEnv.signs.ingest_hash = $ingHash
  ($sigEnv | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath (Join-Path $tmp "payload\sig_envelope.json") -Encoding UTF8

  # Write sha256sums.txt
  $sumLines = @()
  foreach ($f in $files | Where-Object { $_ -ne "sha256sums.txt" }) {
    $fp = Join-Path $tmp ($f -replace "/", "\")
    $h = Get-Sha256Hex -Path $fp
    $sumLines += ($h + "  " + $f)
  }
  Set-Content -LiteralPath (Join-Path $tmp "sha256sums.txt") -Value ($sumLines -join "`n") -Encoding UTF8

  # Move to outbox under PacketId
  $dest = Join-Path $NflOutboxRoot $packetId
  if (Test-Path -LiteralPath $dest) { return $packetId } # idempotent
  Move-Item -LiteralPath $tmp -Destination $dest
  return $packetId
}

# Paths
$Inbox        = "C:\ProgramData\NFL\inbox"
$Index        = "C:\ProgramData\NFL\index\index.ndjson"
$ReportsDir   = "C:\ProgramData\NFL\reports"
$NflPledges   = "C:\ProgramData\NFL\pledges\pledges.ndjson"
$NflOutbox    = "C:\ProgramData\NFL\outbox"
$SeenDir      = "C:\ProgramData\NFL\state\seen"

Ensure-Dir $Inbox
Ensure-Dir (Split-Path -Parent $Index)
Ensure-Dir $ReportsDir
Ensure-Dir (Split-Path -Parent $NflPledges)
Ensure-Dir $NflOutbox
Ensure-Dir $SeenDir

$packets = @(Get-ChildItem -LiteralPath $Inbox -Directory -ErrorAction Stop)

if (-not $packets -or $packets.Count -eq 0) {
  "NFL: inbox empty"
  exit 0
}

$outLines = @()
foreach ($p in $packets) {
  $packetIdDir = $p.Name

  # Idempotency: process each inbox packet once
  $seenMarker = Join-Path $SeenDir ($packetIdDir + ".seen")
  if (Test-Path -LiteralPath $seenMarker) {
    continue
  }
  $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  try {
    $r = Verify-PacketBasic -PacketDir $p.FullName -PacketIdDirName $packetIdDir
    # Index row
    $row = [ordered]@{
      schema            = "nfl.index_row.v1"
      packet_id         = $packetIdDir
      commit_hash       = $r.commit_hash
      producer          = $r.producer
      producer_instance = $r.producer_instance
      created_at_utc    = $r.created_at_utc
      verified_at_utc   = $now
      status            = "verified_basic"
    }
    $outLines += (([pscustomobject]$row) | ConvertTo-Json -Compress -Depth 50)

    # NFL pledge: "received + processed"
    $pledge = [ordered]@{
      schema="nfl.local_pledge.v1"
      created_at_utc=$now
      producer="nfl"
      producer_instance="nfl-local-1"
      tenant="single-tenant"
      principal="single-tenant/nfl_authority/authority/nfl"
      key_id="nfl-authority-ed25519"
      commit_hash=$r.commit_hash
      observed_packet_id=$packetIdDir
      observed_producer=$r.producer
      observed_producer_instance=$r.producer_instance
      status="received_verified_basic"
      sig_path=("outbox/(pending)/signatures/ingest.sig")
    }
    $pledgeWritten = Append-PledgeLine -LogPath $NflPledges -Obj $pledge

    # Emit NFL receive packet (artifact) and backfill sig_path to the new outbox packet
    $nflPacketId = Emit-NflReceivePacket -NflOutboxRoot $NflOutbox -PacketId $packetIdDir -CommitHash $r.commit_hash -Status "received_verified_basic" -VerifiedAtUtc $now

    # Append a second pledge line that binds the outbox packet id deterministically
    $pledge2 = [ordered]@{
      schema="nfl.local_pledge.v1"
      created_at_utc=$now
      producer="nfl"
      producer_instance="nfl-local-1"
      tenant="single-tenant"
      principal="single-tenant/nfl_authority/authority/nfl"
      key_id="nfl-authority-ed25519"
      commit_hash=$r.commit_hash
      observed_packet_id=$packetIdDir
      status="nfl_receive_packet_emitted"
      nfl_packet_id=$nflPacketId
      sig_path=("outbox/" + $nflPacketId + "/signatures/ingest.sig")
    }
    [void](Append-PledgeLine -LogPath $NflPledges -Obj $pledge2)

# Mark as seen only after we have indexed + pledged + emitted NFL receive packet
Set-Content -LiteralPath $seenMarker -Value $now -Encoding UTF8

  } catch {
    $err = $_.Exception.Message
    $rep = Join-Path $ReportsDir ("verify_fail_" + $packetIdDir + ".json")

    # Idempotency for failures: mark seen so broken packets don't spam the ledger
    try { Set-Content -LiteralPath $seenMarker -Value $now -Encoding UTF8 } catch { }
    Write-Json -Path $rep -Obj ([ordered]@{
      schema="nfl.verify_fail.v1"
      packet_id=$packetIdDir
      error=$err
      at_utc=$now
    })
    $outLines += (([pscustomobject]([ordered]@{
      schema="nfl.index_row.v1"
      packet_id=$packetIdDir
      status="failed"
      error=$err
      verified_at_utc=$now
    })) | ConvertTo-Json -Compress -Depth 50)
  }
}

if ($outLines.Count -gt 0) {
  Add-Content -LiteralPath $Index -Value ($outLines -join "`n") -Encoding UTF8
}
"NFL: scanned $($packets.Count) packet(s). Index appended: $Index"
    # NFL failure pledge (witness receipt + failure)
    try {
      $now2 = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
      $failPledge = [ordered]@{
        schema="nfl.local_pledge.v1"
        created_at_utc=$now2
        producer="nfl"
        producer_instance="nfl-local-1"
        tenant="single-tenant"
        principal="single-tenant/nfl_authority/authority/nfl"
        key_id="nfl-authority-ed25519"
        commit_hash="(unknown)"
        observed_packet_id=$packetIdDir
        status="received_failed_verify"
        error=$err
        sig_path="(none)"
      }
      [void](Append-PledgeLine -LogPath $NflPledges -Obj $failPledge)
    } catch { }
    $rep = Join-Path $ReportsDir ("verify_fail_" + $packetIdDir + ".json")

    # Idempotency for failures: mark seen so broken packets don't spam the ledger
    try { Set-Content -LiteralPath $seenMarker -Value $now -Encoding UTF8 } catch { }
    Write-Json -Path $rep -Obj ([ordered]@{
      schema="nfl.verify_fail.v1"
      packet_id=$packetIdDir
      error=$err
      at_utc=$now
    })
    $outLines += (([pscustomobject]([ordered]@{
      schema="nfl.index_row.v1"
      packet_id=$packetIdDir
      status="failed"
      error=$err
      verified_at_utc=$now
    })) | ConvertTo-Json -Compress -Depth 50)
  }
}

if ($outLines.Count -gt 0) {
  Add-Content -LiteralPath $Index -Value ($outLines -join "`n") -Encoding UTF8
}
"NFL: scanned $($packets.Count) packet(s). Index appended: $Index"











