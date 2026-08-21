# Never Forgetting Ledger (NFL)

Never Forgetting Ledger (NFL) is a permanent integrity ledger for cryptographic hashes.

It allows systems and users to:

- commit a hash once
- store it with a timestamp
- look it up or verify it at any time

NFL ensures that important hashes are never lost and can always be independently verified.

---

## What NFL Does

NFL provides three core operations:

- **Commit** → store a hash with metadata
- **Lookup** → retrieve a previously committed record
- **Verify** → hash a file and check whether it exists in the ledger

Deterministic result tokens:

```text
COMMIT_OK
FOUND
NOT_FOUND
VERIFIED
```

---

## Quickstart

Start the API:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File scripts\nfl_api_v1.ps1 `
  -RepoRoot . `
  -Prefix "http://127.0.0.1:8085/"
```

Test lookup:

```powershell
Invoke-RestMethod -Method Get `
  -Uri "http://127.0.0.1:8085/lookup?hash=abc123"
```

Full API usage: `docs/NFL_API_QUICKSTART.md`

---

## API Overview

| Operation | Method | Route |
|---|---|---|
| Commit | POST | `/commit` |
| Lookup | GET | `/lookup?hash=<hash>` |
| Verify | POST | `/verify` |

---

## CLI Usage

Entry point: `scripts\nfl_cli_v1.ps1`

Commit:

```powershell
.\scripts\nfl_cli_v1.ps1 commit -Hash "abc123" -Artifact "test"
```

Lookup:

```powershell
.\scripts\nfl_cli_v1.ps1 lookup -Hash "abc123"
```

Verify:

```powershell
.\scripts\nfl_cli_v1.ps1 verify -File "C:\Windows\notepad.exe"
```

---

## System Role

NFL is a witness-only system.

It:

- records hashes
- timestamps events
- returns deterministic results

It does not:

- decide trust
- enforce policy
- define truth

It only answers: *"Has this hash been seen before?"*

---

## Packet-law verification (delegated to CPR)

Packet Constitution v1 (Option-A) packet verification is **not** performed inside NFL.
It is delegated to the CPR instrument:

- Authoritative verifier: `C:/dev/cpr/scripts/verify_packet_v1.ps1`
- NFL witness wrapper: `scripts/nfl_witness_cpr_verify_v1.ps1`

NFL's historical local packet-law entrypoints (`scripts/verify_packet_v1.ps1`,
`scripts/_selftest_nfl_tier0_locked_v1.ps1`, and related) are intentionally
quarantined stubs that raise `NFL_PACKET_LAW_MOVED_TO_CPR`. This keeps NFL as the
witness/ledger layer and CPR as the packet-law authority.

---

## Tier-0 Status

Tier-0 is complete and frozen (historical evidence, pre-CPR-migration).

Canonical documents:

- `docs/NFL_TIER0_LOCK.md`
- `docs/NFL_CANONICAL_STATUS.md`

Frozen evidence:

- `test_vectors/tier0_frozen/nfl_tier0_green_20260307`

Canonical tags:

- `nfl-tier0-green-20260307`
- `nfl-tier0-release-hygiene-20260307`

---

## Current public surface

Operational (witness / ledger / API / CLI):

- `scripts/nfl_cli_v1.ps1` — commit / lookup / verify CLI
- `scripts/nfl_api_v1.ps1` — local HTTP API (commit / lookup / verify)
- `scripts/nfl_witness_cpr_verify_v1.ps1` — witness wrapper over the CPR verifier
- `scripts/nfl_export_ledger_packet_v1.ps1` — export ledger as a packet
- `scripts/nfl_sign_ledger_packet_v1.ps1` — sign an exported ledger packet
- `scripts/nfl_ingest_inboxes_v1.ps1` — idempotent inbox ingest

Frozen Tier-0 evidence surface (historical): `scripts/selftest_vectors_v1.ps1`,
`scripts/selftest_verify_packet_v1.ps1`, and the `test_vectors/tier0_frozen/` bundle.

---

## Summary

Never Forgetting Ledger is a simple, durable system:

- hash something
- commit it once
- verify it forever

No interpretation. No mutation. No forgetting.
