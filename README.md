# Never Forgetting Ledger (NFL)

NFL is the canonical **witness-only** layer in the Covenant Systems stack.

It is responsible for:
- Packet Constitution v1 Option-A verification
- signature namespace verification
- append-only deterministic receipt recording

NFL does **not** own trust authority, policy authority, or truth authority.

## Tier-0 Locked State

Tier-0 is complete and frozen.

Canonical lock documents:
- docs/NFL_TIER0_LOCK.md
- docs/NFL_CANONICAL_STATUS.md

Canonical frozen evidence:
- test_vectors/tier0_frozen/nfl_tier0_green_20260307

Canonical tags:
- nfl-tier0-green-20260307
- nfl-tier0-release-hygiene-20260307

Tier-0 public surface:
- scripts/verify_packet_v1.ps1
- scripts/selftest_verify_packet_v1.ps1
- scripts/selftest_vectors_v1.ps1
- scripts/_selftest_nfl_tier0_locked_v1.ps1
