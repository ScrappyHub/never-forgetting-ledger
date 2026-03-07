UNIVERSAL TRANSPORT LAW â€” PACKET CONSTITUTION v1 (GLOBAL, PROJECT-AGNOSTIC)

SCOPE (GLOBAL):
This law applies to EVERY project and tool in the ecosystem that produces, moves, ingests, or verifies directory-bundle packets (offline/airgapped or online). No project is exempt.

This law is BELOW application logic (policy, UI, engines) and ABOVE filesystem bytes. It is transport physics.

PURPOSE:
Eliminate PacketId/manifest/sha256sums drift globally by locking:
- canonical bytes rules
- PacketId derivation rule
- finalization ordering
- verification non-mutation rule
- deterministic receipts and test vectors

LOCKED DEFINITIONS:
- Canonical bytes: exact on-disk bytes used for hashing/verification.
  - UTF-8 no BOM
  - LF newlines
  - canonical JSON serialization (stable ordering; no whitespace; stable escaping)
- PacketId: content-addressed identifier derived from manifest-without-id canonical bytes:
  PacketId = SHA-256( canonical_bytes( manifest-without-id ) )

DESIGN CHOICE (LOCK IT):
Option A (RECOMMENDED; default):
- manifest.json MUST NOT contain packet_id
- packet_id.txt contains PacketId
- sha256sums.txt hashes manifest.json, packet_id.txt, signatures, and all required files
Option B (allowed but harder):
- manifest.json MAY contain packet_id
- PacketId MUST still be derived from canonical bytes of 'manifest-without-id'
- sha256sums.txt generated only after final manifest is written
Option A is preferred because it removes 'manifest mutation' as a class of bugs.

LOCKED FINALIZATION PIPELINE (MANDATORY ORDER):
1) Write ALL payload files first (payload/**).
2) Write manifest.json WITHOUT packet_id using canonical JSON bytes.
3) Write detached signatures AFTER payload + manifest exist (signatures/**).
4) Compute PacketId from canonical bytes of manifest-without-id.
5) Persist PacketId:
   - Option A: write packet_id.txt
   - Option B: embed into manifest (ONLY if hash input remains manifest-without-id bytes)
6) Generate sha256sums.txt LAST over final on-disk bytes of ALL required files.
7) Emit receipts LAST, referencing PacketId and hashes (manifest, sha256sums, signatures).

LOCKED VERIFICATION RULES:
- Verifiers MUST NOT mutate packets (no 'self-healing').
- Any repair/rewrite is a separate explicit command producing its own repair artifact + receipts.
- Verification computes hashes from on-disk bytes only and compares to sha256sums + PacketId rule.
- Signature verification must be deterministic and trust-bundle based.

TEST VECTORS (MANDATORY):
Maintain test_vectors/ with:
- minimal packet
- canonical manifest-without-id bytes (golden)
- expected PacketId
- expected sha256sums content (golden)
- expected verification result
Any compliant implementation must match the vectors exactly.

DELIVERABLES:
- Spec doc section: 'Finalization Law v1'
- Canonical byte rules + PacketId derivation rules
- Golden test vectors pack
- Compliance checklist for producers/verifiers
