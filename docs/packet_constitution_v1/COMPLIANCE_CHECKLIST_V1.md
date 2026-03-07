# Compliance Checklist v1 (Packet Constitution v1)

## Producer checklist
- [ ] Canonical bytes: UTF-8 no BOM, LF newlines
- [ ] Canonical JSON for `manifest.json` (stable ordering, no whitespace, stable escaping)
- [ ] Option A default: `manifest.json` does NOT contain `packet_id`
- [ ] PacketId computed as SHA-256(canonical_bytes(manifest-without-id))
- [ ] PacketId persisted (Option A: `packet_id.txt`)
- [ ] Detached signatures created AFTER payload+manifest exist
- [ ] `sha256sums.txt` generated LAST over final bytes of required files
- [ ] Receipts emitted LAST referencing PacketId + hashes

## Verifier checklist
- [ ] Verifier never mutates packet bytes (no self-heal)
- [ ] Verifier recomputes sha256 over on-disk bytes and matches `sha256sums.txt`
- [ ] Verifier recomputes PacketId from canonical bytes of manifest-without-id and matches `packet_id.txt` (Option A)
- [ ] Verifier checks detached signatures deterministically using trust bundle
- [ ] Any repair output is a separate artifact with its own receipts

## Test vectors checklist
- [ ] Minimal packet exists
- [ ] Golden manifest-without-id bytes exist (exact bytes file)
- [ ] Expected PacketId recorded
- [ ] Golden sha256sums recorded
- [ ] Expected verification result recorded
- [ ] Two independent implementations match the vectors exactly
