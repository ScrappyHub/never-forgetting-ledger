# NFL Durable Ledger v1 — tamper-evidence

**Status:** brick 1 complete and verified on the real machine (2026-08-25).
**Scope:** non-mutating tamper-evidence over `data/ledger.ndjson`. No change to the
commit/write path. Self-contained in NFL — does **not** depend on CPR or any external
service (durable-ledger integrity can be proven even if CPR/SaaS is absent).

## What was added

- `scripts/nfl_ledger_checkpoint_v1.ps1` — `-Mode checkpoint` and `-Mode verify`.
- `scripts/_selftest_nfl_ledger_checkpoint_v1.ps1` — negative proof (temp-dir, non-destructive).

## Chain construction (self-consistent v1)

For each ledger record, in file order:

```
canon_i = ConvertTo-Json(-Compress) of [ordered]{ hash, artifact, timestamp }
rec_i   = sha256_hex( utf8(canon_i) )
head_0  = sha256_hex( utf8( "nfl.ledger.chain.v1" + "\n" + rec_0 ) )
head_i  = sha256_hex( utf8( head_{i-1} + "\n" + rec_i ) )
```

`checkpoint` appends `{ schema, utc, chain_algo, genesis, count, head, ledger_sha256,
first_rec, last_rec }` to `proofs/checkpoints/nfl_ledger_checkpoint_v1.ndjson`
(and writes `proofs/checkpoints/latest.json`). It canonicalizes by *parsing* each JSON
record and re-serializing, so cosmetic differences (CR, spacing, the writer's
blank-line quirk) don't affect the chain, but any semantic change does.

`verify` recomputes the chain over the current ledger's first *N* records (N = the last
checkpoint's `count`) and compares to the checkpoint `head`:

- head matches, count ≥ N → `NFL_LEDGER_VERIFY_OK`, reporting `APPENDED_SINCE_CHECKPOINT`.
- count < N → `NFL_LEDGER_VERIFY_FAIL:LEDGER_TRUNCATED`.
- head differs → `NFL_LEDGER_VERIFY_FAIL:PREFIX_TAMPERED`.

## Verification evidence (run on C:\dev\nfl)

Happy path:

```
checkpoint -> NFL_LEDGER_CHECKPOINT_OK  COUNT=12  HEAD=2bd9837883787679813d6a87a304040622d2e7f7acdd54acd87e71c473d56f07
verify     -> NFL_LEDGER_VERIFY_OK  CHECKPOINT_PREFIX_INTACT=12  APPENDED_SINCE_CHECKPOINT=0
```

Negative proof (`_selftest_nfl_ledger_checkpoint_v1.ps1`):

```
PASS  CLEAN     exit=0
PASS  APPEND    exit=0   (legitimate append accepted, APPENDED=1)
PASS  TAMPER    exit=1   (mutated record rejected: PREFIX_TAMPERED)
PASS  TRUNCATE  exit=1   (dropped record rejected: LEDGER_TRUNCATED)
PASS  REORDER   exit=1   (swapped records rejected: PREFIX_TAMPERED)
RESULT=5/5
NFL_LEDGER_SELFTEST_OK
```

## Deliberate limits (documented, not hidden)

- **Self-consistent, not yet cross-implementation portable.** The chain is defined by
  PowerShell `ConvertTo-Json -Compress` canonicalization. An independent (e.g. Python)
  verifier would need to match that canonicalization exactly. Cross-impl portability is
  export/interop work (a later brick).
- **Checkpoints are not yet signed.** A checkpoint is currently an unsigned anchor.
  Signing/sealing the checkpoint head (reusing the existing ssh-keygen signing lane) is
  the next brick — it turns "the ledger matches my checkpoint" into "the ledger matches
  a checkpoint I cryptographically sealed."
- **Checkpoints/receipts are on-disk runtime** (gitignored), consistent with the ledger
  itself being on-disk data rather than version-controlled.

## Next bricks (in order)

1. **Sign the checkpoint** (seal): sign `head` with `proofs/keys/id_ed25519`, verify the
   seal in `verify`. Negative tests: wrong key, altered head.
2. **Embed chain in commit** (optional): add `seq` + `prev_head` to each new record so the
   ledger is self-chaining at write time, not only via external checkpoint.
3. **Export + independent export verification** (portable canonicalization).
4. **Wire the durable-ledger gate into a standing runner** so integrity is re-proven
   routinely (kept independent of the CPR-requiring CLI full-green so it works offline).
