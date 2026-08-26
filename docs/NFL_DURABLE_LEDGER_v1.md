# NFL Durable Ledger v1 — tamper-evidence, signed seal, portable export

**Status:** bricks 1, 3, and portable-export complete and verified (2026-08-26).
**Scope:** non-mutating tamper-evidence, cryptographic sealing, and an independently
verifiable export over `data/ledger.ndjson`. No change to the commit/write path.
Self-contained in NFL — no dependency on CPR or any network/SaaS.

## Components

- `scripts/nfl_ledger_checkpoint_v1.ps1` — `checkpoint` / `verify` (linked hash chain).
- `scripts/_selftest_nfl_ledger_checkpoint_v1.ps1` — tamper-evidence negative proof (5/5).
- `scripts/nfl_ledger_seal_v1.ps1` — `seal` / `verify-seal` (ssh-keygen signature; verify pins a trusted pubkey).
- `scripts/_selftest_nfl_ledger_seal_v1.ps1` — forgery negative proof (5/5).
- `scripts/nfl_ledger_export_v1.ps1` — produce a portable, signed export bundle.
- `scripts/verify_nfl_export_v1.py` — **language/OS-neutral** verifier (python3 + OpenSSH).
- `scripts/_RUN_nfl_durable_ledger_green_v1.ps1` — one-command standing gate.

## Internal chain (checkpoint/seal) — self-consistent v1

```
canon_i = ConvertTo-Json(-Compress) of [ordered]{ hash, artifact, timestamp }
rec_i   = sha256_hex(utf8(canon_i))
head_0  = sha256_hex(utf8("nfl.ledger.chain.v1" + "\n" + rec_0))
head_i  = sha256_hex(utf8(head_{i-1} + "\n" + rec_i))
```

`verify` recomputes over the current ledger's first N records vs the checkpoint head:
match → `NFL_LEDGER_VERIFY_OK`; count<N → `LEDGER_TRUNCATED`; head differs → `PREFIX_TAMPERED`.

## Seal (brick 3)

`seal` signs a payload binding head/count/ledger_sha256 with `id_ed25519`
(`ssh-keygen -Y sign`, namespace `nfl/ledger-seal`) and self-verifies.
`verify-seal` verifies against a **trusted pinned pubkey** (default `id_ed25519.pub`,
`-TrustedPubPath` to override) — not the bundled `allowed_signers` — then re-checks that
the ledger still chains to the sealed head. Both hold → `NFL_LEDGER_SEAL_VERIFY_OK`.

## Portable export (brick, done)

The export uses a **language-neutral canonicalization** (no PowerShell-JSON dependency),
so any language can recompute the head:

```
canon_i = "hash=" + hash + "\n" + "artifact=" + artifact + "\n" + "timestamp=" + timestamp
rec_i   = sha256_hex(utf8(canon_i))
head_0  = sha256_hex(utf8("nfl.ledger.export.v1" + "\n" + rec_0))
head_i  = sha256_hex(utf8(head_{i-1} + "\n" + rec_i))
payload = "nfl.ledger.export.v1\ncount=<N>\nexport_head=<head>\nledger_sha256=<sha>\n"   (signed)
```

Bundle: `records.ndjson`, `export_manifest.json`, `export_payload.txt(.sig)`, `signer.pub`,
`allowed_signers`. `verify_nfl_export_v1.py <dir> --trusted-pub <pub>` recomputes the head,
checks the payload binds it, and verifies the signature with `ssh-keygen -Y verify`.

## Verification evidence

- Checkpoint tamper-evidence self-test: **5/5** (CLEAN, APPEND, TAMPER, TRUNCATE, REORDER) → `NFL_LEDGER_SELFTEST_OK`.
- Seal forgery self-test: **5/5** (CLEAN, WRONG_KEY, TAMPERED_PAYLOAD, ALTERED_SEAL_HEAD, LEDGER_MUTATED) → `NFL_LEDGER_SEAL_SELFTEST_OK`.
- Standing gate: `NFL_DURABLE_LEDGER_GREEN_OK`.
- **Cross-platform export proof:** export signed on Windows/PowerShell (head
  `c999a021…`, 12 records) verified independently on **Linux/Python3 + OpenSSH** →
  recomputed head matched byte-for-byte, signature `Good`, `NFL_EXPORT_VERIFY_OK`.
  A single-character mutation of a record was rejected with `EXPORT_HEAD_MISMATCH`.

## Deliberate limits (documented, not hidden)

- **Trust anchor is local.** Seal/export `verify` pin to `id_ed25519.pub`. A fully
  independent verifier must obtain the authorized pubkey out-of-band — this is where
  NeverLost / a trust-bundle belongs (WBS 10). Today the anchor is the local key.
- **Checkpoints/seals/exports/receipts are on-disk runtime** (gitignored), consistent
  with the ledger itself being on-disk data.

## Next bricks

1. **Trust-bundle input** — let seal/export `verify` accept an authorized-signer bundle
   (NeverLost) instead of a locally-supplied pin. This is the WBS 10 milestone.
2. **Embed chain in commit (optional)** — add `seq` + `prev_head` at write time so the
   ledger is self-chaining, not only via external checkpoint/export.
