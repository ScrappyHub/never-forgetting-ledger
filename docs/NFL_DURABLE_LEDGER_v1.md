# NFL Durable Ledger v1 — tamper-evidence, signed seal, portable export, trust-bundle

**Status:** tamper-evidence, seal, portable export, and trust-bundle authorization all
complete and verified (2026-08-26). No change to the commit/write path. Self-contained in
NFL — no dependency on CPR, a running NeverLost service, or any network/SaaS.

## Components

- `scripts/nfl_ledger_checkpoint_v1.ps1` — `checkpoint` / `verify` (linked hash chain).
- `scripts/_selftest_nfl_ledger_checkpoint_v1.ps1` — tamper-evidence negative proof (5/5).
- `scripts/nfl_ledger_seal_v1.ps1` — `seal` / `verify-seal` (ssh-keygen signature; pins trusted pubkey).
- `scripts/_selftest_nfl_ledger_seal_v1.ps1` — forgery negative proof (5/5).
- `scripts/nfl_ledger_export_v1.ps1` — produce a portable, signed export bundle.
- `scripts/verify_nfl_export_v1.py` — language/OS-neutral verifier (python3 + OpenSSH); supports `--trusted-pub` and `--trust-bundle`.
- `scripts/_selftest_nfl_export_v1.py` — portable export + trust-bundle negative proof (6/6).
- `scripts/_RUN_nfl_durable_ledger_green_v1.ps1` — one-command standing gate.

## Internal chain (checkpoint/seal) — self-consistent v1

```
canon_i = ConvertTo-Json(-Compress) of [ordered]{ hash, artifact, timestamp }
rec_i   = sha256_hex(utf8(canon_i))
head_0  = sha256_hex(utf8("nfl.ledger.chain.v1" + "\n" + rec_0))
head_i  = sha256_hex(utf8(head_{i-1} + "\n" + rec_i))
```

## Seal

`seal` signs head/count/ledger_sha256 with `id_ed25519` (`ssh-keygen -Y sign`, namespace
`nfl/ledger-seal`) and self-verifies. `verify-seal` verifies against a trusted pinned
pubkey, then re-checks the ledger still chains to the sealed head.

## Portable export + trust-bundle

Export uses a language-neutral canonicalization (`"hash="+h+"\n"+"artifact="+a+"\n"+"timestamp="+t`,
genesis `nfl.ledger.export.v1`), signed with `ssh-keygen`. The verifier recomputes the
head, checks the signed payload binds it, and verifies the signature under one of two
trust models:

- `--trusted-pub <pub>` — pin to a single out-of-band public key.
- `--trust-bundle <neverlost.trust_bundle.v1>` — **authorize** the signer: it must be a
  key the bundle lists for the export's namespace. This is the trust-separation the spec
  (§19) requires — "signature valid" vs "signer authorized" — and consumes the existing
  `proofs/trust/trust_bundle.json` contract without NFL owning NeverLost.

## Verification evidence (all run for real)

- Checkpoint tamper self-test: **5/5** → `NFL_LEDGER_SELFTEST_OK`.
- Seal forgery self-test: **5/5** → `NFL_LEDGER_SEAL_SELFTEST_OK`.
- Standing gate: `NFL_DURABLE_LEDGER_GREEN_OK`.
- Cross-platform export: signed on Windows/PowerShell (head `c999a021…`, 12 records),
  verified independently on Linux/Python3+OpenSSH — head matched byte-for-byte, signature
  `Good`, single-char mutation rejected with `EXPORT_HEAD_MISMATCH`.
- Export + trust-bundle self-test: **6/6** (PIN_CLEAN, PIN_WRONG_KEY, TAMPER_RECORD,
  BUNDLE_OK, BUNDLE_UNKNOWN_KEY, BUNDLE_WRONG_NS) → `NFL_EXPORT_SELFTEST_OK`.
- Real repo bundle (`proofs/trust/trust_bundle.json`, schema `neverlost.trust_bundle.v1`)
  parsed and resolved correctly (authorizes 1 key for `nfl/ingest-receipt`).

## Deliberate limits (documented, not hidden)

- **Bundle root-of-trust not yet verified.** `--trust-bundle` trusts the bundle's contents;
  it does not yet verify the bundle's own signature (`trust_bundle.json.sig`) against a
  NeverLost root key. That (root-of-trust anchoring) is the next trust brick.
- **Trust-bundle consumption is currently in the portable (Python) verifier.** PS-side
  `verify-seal` still pins a single key; adding `-TrustBundlePath` there is a parity follow-up.
- **Checkpoints/seals/exports/receipts are on-disk runtime** (gitignored).

## Next bricks

1. **Verify the trust bundle's own signature** against a NeverLost root/anchor key, so the
   authorized-signer list is itself cryptographically trusted (full WBS 10 root-of-trust).
2. **PS-side trust-bundle parity** — `-TrustBundlePath` on `verify-seal`.
3. **Embed chain in commit (optional)** — `seq` + `prev_head` at write time.
