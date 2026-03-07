# Finalization Law v1 (Packet Constitution v1)

## Option A (default; REQUIRED unless explicitly opted out)
- `manifest.json` MUST NOT include `packet_id`
- `packet_id.txt` contains PacketId
- `sha256sums.txt` hashes final on-disk bytes of required files

## Mandatory finalization order (no reordering)
1) Write all payload bytes (`payload/**`)
2) Write `manifest.json` WITHOUT `packet_id` using canonical JSON bytes
3) Write detached signatures (`signatures/**`) after payload+manifest exist
4) Compute `PacketId = SHA-256(canonical_bytes(manifest-without-id))`
5) Persist PacketId (Option A: `packet_id.txt`; Option B only if hash input remains manifest-without-id)
6) Generate `sha256sums.txt` LAST over final bytes of required files
7) Emit receipts LAST referencing PacketId + hashes

## Verification invariants
- Verifiers MUST NOT mutate packets
- Repairs are explicit separate artifacts + receipts
- Verify uses on-disk bytes only; compares sha256sums + PacketId derivation + detached signatures (trust-bundle based)
