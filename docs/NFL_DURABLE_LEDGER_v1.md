# NFL Durable Ledger v1 — tamper-evidence, seal, portable export, trust-bundle + root-of-trust

**Status:** tamper-evidence, seal, portable export, trust-bundle authorization, and
bundle root-of-trust all complete and verified (2026-08-26). No change to the
commit/write path. Self-contained in NFL — no dependency on CPR, a running NeverLost
service, or any network/SaaS.

## Components

- `scripts/nfl_ledger_checkpoint_v1.ps1` / `_selftest_nfl_ledger_checkpoint_v1.ps1` — chain tamper-evidence (5/5).
- `scripts/nfl_ledger_seal_v1.ps1` / `_selftest_nfl_ledger_seal_v1.ps1` — signed seal + forgery proof (5/5).
- `scripts/nfl_ledger_export_v1.ps1` — produce a portable, signed export bundle.
- `scripts/verify_nfl_export_v1.py` — language/OS-neutral verifier (python3 + OpenSSH):
  `--trusted-pub`, `--trust-bundle`, `--root-pub`/`--bundle-namespace`.
- `scripts/_selftest_nfl_export_v1.py` — portable negative proof (9/9).
- `scripts/_RUN_nfl_durable_ledger_green_v1.ps1` — one-command standing gate.

## Trust model (three layers, all enforced by verify_nfl_export_v1.py)

1. **Integrity** — recompute the language-neutral chain head from records; the signed
   payload must bind it. (`EXPORT_HEAD_MISMATCH` / `PAYLOAD_DOES_NOT_BIND_HEAD`)
2. **Authenticity + authorization** — the export signature must be by a key the trust
   bundle lists **for the export's namespace** (`--trust-bundle`). Distinguishes
   "signature valid" from "signer authorized" (spec §19). (`SIGNER_NOT_IN_BUNDLE` /
   `NAMESPACE_NOT_AUTHORIZED`)
3. **Root-of-trust** — the trust bundle's **own** signature is verified against a
   NeverLost root pubkey pinned out-of-band (`--root-pub`), under the bundle-signing
   namespace, before the bundle is trusted. (`BUNDLE_SIG_INVALID`; `BUNDLE_UNVERIFIED`
   warning if no root pinned.) NFL consumes NeverLost's bundle; it does not own it.

The current NeverLost dev bundle (`proofs/trust/trust_bundle.json`) is self-signed by its
listed key under namespace `nfl/ingest-receipt`; pinning that key as `--root-pub` is a
valid anchor.

## Verification evidence (all run for real)

- Checkpoint tamper self-test **5/5**; seal forgery self-test **5/5**; standing gate `NFL_DURABLE_LEDGER_GREEN_OK`.
- Cross-platform export: signed on Windows/PowerShell (head `c999a021…`), verified on
  Linux/Python3+OpenSSH **and** natively on Windows (`python`), head byte-identical.
- Export negative self-test **9/9**: PIN_CLEAN, PIN_WRONG_KEY, TAMPER_RECORD, BUNDLE_OK,
  BUNDLE_UNKNOWN_KEY, BUNDLE_WRONG_NS, ROOT_OK, ROOT_WRONG, ROOT_TAMPER → `NFL_EXPORT_SELFTEST_OK`.
- **Real NeverLost bundle signature** verified against the pinned root under
  `nfl/ingest-receipt` (`Good "nfl/ingest-receipt" signature`), and correctly rejected
  under a wrong namespace.

## Deliberate limits (documented, not hidden)

- **Trust-bundle + root-of-trust are in the portable (Python) verifier.** The PS-side
  `verify-seal` still pins a single key; `-TrustBundlePath` there is a parity follow-up.
- **The dev bundle is self-signed** (no separate NeverLost root key yet). Root-of-trust
  works by pinning that key out-of-band; a distinct root key is a NeverLost-side change.
- **Checkpoints/seals/exports/receipts are on-disk runtime** (gitignored).

## Next bricks (optional)

1. **PS-side trust-bundle + root-of-trust parity** on `verify-seal`.
2. **Embed chain in commit** — `seq` + `prev_head` at write time (self-chaining ledger).
