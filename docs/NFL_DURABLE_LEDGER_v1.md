# NFL Durable Ledger v1 — tamper-evidence + signed seal

**Status:** bricks 1 and 3 complete and verified on the real machine (2026-08-25).
**Scope:** non-mutating tamper-evidence + cryptographic sealing over `data/ledger.ndjson`.
No change to the commit/write path. Self-contained in NFL — does **not** depend on CPR
or any external service (durable-ledger integrity can be proven offline).

## Components

- `scripts/nfl_ledger_checkpoint_v1.ps1` — `checkpoint` / `verify` (linked hash chain).
- `scripts/_selftest_nfl_ledger_checkpoint_v1.ps1` — tamper-evidence negative proof.
- `scripts/nfl_ledger_seal_v1.ps1` — `seal` / `verify-seal` (ssh-keygen signature over the checkpoint head).
- `scripts/_selftest_nfl_ledger_seal_v1.ps1` — forgery negative proof.
- `scripts/_RUN_nfl_durable_ledger_green_v1.ps1` — one-command standing gate.

## Chain construction (self-consistent v1)

```
canon_i = ConvertTo-Json(-Compress) of [ordered]{ hash, artifact, timestamp }
rec_i   = sha256_hex( utf8(canon_i) )
head_0  = sha256_hex( utf8( "nfl.ledger.chain.v1" + "\n" + rec_0 ) )
head_i  = sha256_hex( utf8( head_{i-1} + "\n" + rec_i ) )
```

`verify` recomputes the chain over the current ledger's first *N* records (N = the last
checkpoint's `count`) and compares to the checkpoint `head`:
match+count≥N → `NFL_LEDGER_VERIFY_OK`; count<N → `LEDGER_TRUNCATED`; head differs → `PREFIX_TAMPERED`.

## Seal (brick 3)

`seal` signs a canonical payload binding `head` / `count` / `ledger_sha256` with
`proofs/keys/id_ed25519` (OpenSSH `ssh-keygen -Y sign`, namespace `nfl/ledger-seal`),
storing the seal under `proofs/checkpoints/seals/<runid>/`, and self-verifies before
declaring OK.

`verify-seal` verifies **against a TRUSTED pinned pubkey** (default
`proofs/keys/id_ed25519.pub`, overridable via `-TrustedPubPath`) — *not* the
`allowed_signers` bundled in the seal, so swapping the whole signature bundle is not
sufficient to forge a seal. It then re-checks that the current ledger still chains to the
sealed head. Both must hold → `NFL_LEDGER_SEAL_VERIFY_OK`.

## Verification evidence (run on C:\dev\nfl)

Tamper-evidence self-test:

```
PASS CLEAN | PASS APPEND | PASS TAMPER | PASS TRUNCATE | PASS REORDER  -> NFL_LEDGER_SELFTEST_OK (5/5)
```

Seal happy path + forgery self-test:

```
seal        -> NFL_LEDGER_SEAL_OK
verify-seal -> NFL_LEDGER_SEAL_VERIFY_OK (SIGNATURE=VALID, LEDGER_MATCHES_SEALED_HEAD=YES)

PASS CLEAN
PASS WRONG_KEY          (forged signer rejected: SIG_INVALID)
PASS TAMPERED_PAYLOAD   (edited payload rejected: SIG_INVALID)
PASS ALTERED_SEAL_HEAD  (edited seal.json rejected: LEDGER_HEAD_MISMATCH)
PASS LEDGER_MUTATED     (mutated ledger rejected: LEDGER_HEAD_MISMATCH)
-> NFL_LEDGER_SEAL_SELFTEST_OK (5/5)
```

Standing gate: `_RUN_nfl_durable_ledger_green_v1.ps1` → `NFL_DURABLE_LEDGER_GREEN_OK`.

## Deliberate limits (documented, not hidden)

- **Self-consistent, not yet cross-implementation portable.** The chain is defined by
  PowerShell `ConvertTo-Json -Compress` canonicalization; an independent (e.g. Python)
  verifier would need to match it. Portability is export/interop work (a later brick).
- **Trust anchor is local.** `verify-seal` pins to the repo's `id_ed25519.pub`. A fully
  independent verifier must obtain the authorized pubkey out-of-band — this is exactly
  where NeverLost / a trust-bundle belongs (WBS 10). Today the anchor is the local key.
- **Checkpoints/seals/receipts are on-disk runtime** (gitignored), consistent with the
  ledger itself being on-disk data rather than version-controlled.

## Next bricks

1. **Export + independent portable verification** — define a byte-canonical record form
   (independent of PowerShell JSON) and a small standalone verifier so a third party can
   verify a sealed export without running the NFL environment.
2. **Trust-bundle input** — let `verify-seal` accept an authorized-signer bundle
   (NeverLost) instead of the local pinned key.
3. **Embed chain in commit (optional)** — add `seq` + `prev_head` at write time so the
   ledger is self-chaining, not only via external checkpoint.
