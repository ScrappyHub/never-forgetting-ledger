param([Parameter(Mandatory=$true)][string]$RepoRoot)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }
function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $norm = ($Text -replace "`r`n","`n" -replace "`r","`n")
  if (-not $norm.EndsWith("`n")) { $norm += "`n" }
  [System.IO.File]::WriteAllText($Path,$norm,$enc)
}

$Root = (Resolve-Path -LiteralPath $RepoRoot).Path
$LawDir = Join-Path $Root "docs\packet_constitution_v1"
$VecDir = Join-Path $Root "test_vectors\packet_constitution_v1"
foreach($d in @($LawDir,$VecDir)){ if (-not (Test-Path -LiteralPath $d -PathType Container)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }

$LawPath   = Join-Path $LawDir "PACKET_CONSTITUTION_V1.md"
$FinalPath = Join-Path $LawDir "FINALIZATION_LAW_V1.md"
$ChkPath   = Join-Path $LawDir "COMPLIANCE_CHECKLIST_V1.md"
$ReadmeVec = Join-Path $VecDir "README.md"

$nl = "`n"
$lawLines = @(
  'UNIVERSAL TRANSPORT LAW — PACKET CONSTITUTION v1 (GLOBAL, PROJECT-AGNOSTIC)',
  '',
  'SCOPE (GLOBAL):',
  'This law applies to EVERY project and tool in the ecosystem that produces, moves, ingests, or verifies directory-bundle packets (offline/airgapped or online). No project is exempt.',
  '',
  'This law is BELOW application logic (policy, UI, engines) and ABOVE filesystem bytes. It is transport physics.',
  '',
  'PURPOSE:',
  'Eliminate PacketId/manifest/sha256sums drift globally by locking:',
  '- canonical bytes rules',
  '- PacketId derivation rule',
  '- finalization ordering',
  '- verification non-mutation rule',
  '- deterministic receipts and test vectors',
  '',
  'LOCKED DEFINITIONS:',
  '- Canonical bytes: exact on-disk bytes used for hashing/verification.',
  '  - UTF-8 no BOM',
  '  - LF newlines',
  '  - canonical JSON serialization (stable ordering; no whitespace; stable escaping)',
  '- PacketId: content-addressed identifier derived from manifest-without-id canonical bytes:',
  '  PacketId = SHA-256( canonical_bytes( manifest-without-id ) )',
  '',
  'DESIGN CHOICE (LOCK IT):',
  'Option A (RECOMMENDED; default):',
  '- manifest.json MUST NOT contain packet_id',
  '- packet_id.txt contains PacketId',
  '- sha256sums.txt hashes manifest.json, packet_id.txt, signatures, and all required files',
  'Option B (allowed but harder):',
  '- manifest.json MAY contain packet_id',
  '- PacketId MUST still be derived from canonical bytes of manifest-without-id',
  '- sha256sums.txt generated only after final manifest is written',
  'Option A is preferred because it removes manifest mutation as a class of bugs.',
  '',
  'LOCKED FINALIZATION PIPELINE (MANDATORY ORDER):',
  '1) Write ALL payload files first (payload/**).',
  '2) Write manifest.json WITHOUT packet_id using canonical JSON bytes.',
  '3) Write detached signatures AFTER payload + manifest exist (signatures/**).',
  '4) Compute PacketId from canonical bytes of manifest-without-id.',
  '5) Persist PacketId:',
  '   - Option A: write packet_id.txt',
  '   - Option B: embed into manifest (ONLY if hash input remains manifest-without-id bytes)',
  '6) Generate sha256sums.txt LAST over final on-disk bytes of ALL required files.',
  '7) Emit receipts LAST, referencing PacketId and hashes (manifest, sha256sums, signatures).',
  '',
  'LOCKED VERIFICATION RULES:',
  '- Verifiers MUST NOT mutate packets (no self-healing).',
  '- Any repair/rewrite is a separate explicit command producing its own repair artifact + receipts.',
  '- Verification computes hashes from on-disk bytes only and compares to sha256sums + PacketId rule.',
  '- Signature verification must be deterministic and trust-bundle based.',
  '',
  'TEST VECTORS (MANDATORY):',
  'Maintain test_vectors/ with:',
  '- minimal packet',
  '- canonical manifest-without-id bytes (golden)',
  '- expected PacketId',
  '- expected sha256sums content (golden)',
  '- expected verification result',
  'Any compliant implementation must match the vectors exactly.',
  '',
  'NO OVERSEER PRINCIPLE:',
  'This law has no central service authority.',
  'Compliance is enforced by:',
  '- the written law (spec)',
  '- golden vectors',
  '- deterministic verify receipts',
  'Any two independent implementations must converge.',
  '',
  'DELIVERABLES:',
  '- Spec doc section: Finalization Law v1',
  '- Canonical byte rules + PacketId derivation rules',
  '- Golden test vectors pack',
  '- Compliance checklist for producers/verifiers',
)
$law = ($lawLines -join $nl)

$finalLines = @(
  '# Finalization Law v1 (Packet Constitution v1)',
  '',
  'This file is the operative do-these-steps-in-this-order section.',
  '',
  '## Option A (default; REQUIRED unless explicitly opted out)',
  '- manifest.json MUST NOT include packet_id',
  '- packet_id.txt contains PacketId',
  '- sha256sums.txt hashes final on-disk bytes of: manifest.json, packet_id.txt, signatures/**, required payload files',
  '',
  '## Mandatory finalization order (no reordering)',
  '1) Write all payload bytes (payload/**)',
  '2) Write manifest.json WITHOUT packet_id using canonical JSON bytes',
  '3) Write detached signatures (signatures/**) after payload+manifest exist',
  '4) Compute PacketId = SHA-256(canonical_bytes(manifest-without-id))',
  '5) Persist PacketId (Option A: packet_id.txt; Option B allowed only if hash input remains manifest-without-id)',
  '6) Generate sha256sums.txt LAST over final bytes of required files',
  '7) Emit receipts LAST referencing PacketId + hashes',
  '',
  '## Verification invariants',
  '- Verifiers MUST NOT mutate packets',
  '- Repairs are explicit separate artifacts + receipts',
  '- Verify uses on-disk bytes only; compares sha256sums + PacketId derivation + detached signatures (trust-bundle based)',
)
$final = ($finalLines -join $nl)

$chkLines = @(
  '# Compliance Checklist v1 (Packet Constitution v1)',
  '',
  'This is a go/no-go list. If any item fails, it is non-compliant.',
  '',
  '## Producer checklist',
  '- [ ] Canonical bytes: UTF-8 no BOM, LF newlines',
  '- [ ] Canonical JSON for manifest.json (stable ordering, no whitespace, stable escaping)',
  '- [ ] Option A default: manifest.json does NOT contain packet_id',
  '- [ ] PacketId computed as SHA-256(canonical_bytes(manifest-without-id))',
  '- [ ] PacketId persisted (Option A: packet_id.txt)',
  '- [ ] Detached signatures created AFTER payload+manifest exist',
  '- [ ] sha256sums.txt generated LAST over final bytes of required files',
  '- [ ] Receipts emitted LAST referencing PacketId + hashes',
  '- [ ] test_vectors/packet_constitution_v1 updated only by canonical tools (vectors are convergence mechanism)',
  '',
  '## Verifier checklist',
  '- [ ] Verifier never mutates packet bytes (no self-heal)',
  '- [ ] Verifier recomputes sha256 over on-disk bytes and matches sha256sums.txt',
  '- [ ] Verifier recomputes PacketId from canonical bytes of manifest-without-id and matches packet_id.txt (Option A)',
  '- [ ] Verifier checks detached signatures deterministically using trust bundle',
  '- [ ] Any repair output is a separate artifact with its own receipts',
  '',
  '## Test vectors checklist',
  '- [ ] Minimal packet exists',
  '- [ ] Golden manifest-without-id bytes exist (exact bytes file)',
  '- [ ] Expected PacketId recorded',
  '- [ ] Golden sha256sums recorded',
  '- [ ] Expected verification result recorded',
  '- [ ] Two independent implementations match the vectors exactly',
)
$chk = ($chkLines -join $nl)

$vecLines = @(
  '# Packet Constitution v1 — Test Vectors',
  '',
  'This directory is REQUIRED for compliance. Do not update vectors casually.',
  'Vectors are the convergence mechanism (no overseer principle).',
  '',
  '## Layout (required)',
  '- minimal_packet/',
  '  - payload/** (tiny)',
  '  - manifest.json (Option A: WITHOUT packet_id)',
  '  - packet_id.txt (derived from manifest-without-id canonical bytes)',
  '  - signatures/** (detached)',
  '  - sha256sums.txt (generated LAST)',
  '- golden_manifest_without_id.bytes (exact canonical bytes used as PacketId hash input)',
  '- expected_packet_id.txt',
  '- expected_sha256sums.txt',
  '- expected_verify_result.txt',
  '',
  '## Notes',
  '- Do NOT generate golden files with pretty JSON. Canonical JSON bytes only.',
  '- Do NOT allow verifiers to mutate packets.',
  '- When vectors exist, all implementations must match them byte-for-byte.',
)
$vecReadme = ($vecLines -join $nl)

Write-Utf8NoBomLf -Path $LawPath   -Text $law
Write-Utf8NoBomLf -Path $FinalPath -Text $final
Write-Utf8NoBomLf -Path $ChkPath   -Text $chk
Write-Utf8NoBomLf -Path $ReadmeVec -Text $vecReadme

$min = Join-Path $VecDir "minimal_packet"
$minPayload = Join-Path $min "payload"
$minSigs = Join-Path $min "signatures"
foreach($d in @($min,$minPayload,$minSigs)){ if (-not (Test-Path -LiteralPath $d -PathType Container)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }
$ph = @(
  (Join-Path $VecDir "golden_manifest_without_id.bytes"),
  (Join-Path $VecDir "expected_packet_id.txt"),
  (Join-Path $VecDir "expected_sha256sums.txt"),
  (Join-Path $VecDir "expected_verify_result.txt"),
  (Join-Path $minPayload "payload.bin"),
  (Join-Path $min "manifest.json"),
  (Join-Path $min "packet_id.txt"),
  (Join-Path $min "sha256sums.txt")
)
foreach($f in @(@($ph))){ if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Write-Utf8NoBomLf -Path $f -Text "# TODO: populate via canonical producer/verifier tool; placeholder contains no golden values." } }

Write-Host ("WROTE: " + $LawPath)   -ForegroundColor Green
Write-Host ("WROTE: " + $FinalPath) -ForegroundColor Green
Write-Host ("WROTE: " + $ChkPath)   -ForegroundColor Green
Write-Host ("WROTE: " + $ReadmeVec) -ForegroundColor Green
Write-Host ("WROTE: test_vectors skeleton at " + $VecDir) -ForegroundColor Green
Write-Host "PATCH_DONE: Packet Constitution v1 stamped into NFL (witness-law + vectors skeleton)" -ForegroundColor Green
