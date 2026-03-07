# Packet Constitution v1 â€” Test Vectors

## Layout (required)
- `minimal_packet/`
  - `payload/**` (tiny)
  - `manifest.json` (Option A: WITHOUT packet_id)
  - `packet_id.txt` (derived from manifest-without-id canonical bytes)
  - `signatures/**` (detached)
  - `sha256sums.txt` (generated LAST)
- `golden_manifest_without_id.bytes` (exact canonical bytes input to PacketId hash)
- `expected_packet_id.txt`
- `expected_sha256sums.txt`
- `expected_verify_result.txt`
