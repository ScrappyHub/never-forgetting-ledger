# NFL — Current Canonical Handoff (reconciled)

**Repository:** `C:\dev\nfl`
**Reconciled:** 2026-08-21
**Supersedes:** the earlier "~78% / WBS-6 next" Tier-0 handoff, which described the
project *before* the CPR migration and is now historically inaccurate.

---

## 1. What NFL is today

NFL (Never Forgetting Ledger) is a **witness / integrity ledger** with an
operational CLI + local HTTP API. Its core promise is unchanged: hash something,
commit it once, verify it forever — append-only, non-mutating, deterministic.

What changed since the old handoff: **packet-law verification was moved out of NFL
into a separate instrument, CPR** (`C:\dev\cpr`). NFL no longer owns the Packet
Constitution verifier; it *witnesses* CPR's verdicts and records them. NFL's own
former packet-law entrypoints are now intentional quarantine stubs that raise
`NFL_PACKET_LAW_MOVED_TO_CPR`.

So the accurate one-line role is:

> NFL is the append-only witness ledger and operational surface (CLI/API/ingest).
> CPR is the packet-law authority. NeverLost (future) is the trust authority.

---

## 2. Timeline reconciliation (why the old doc is stale)

1. Tier-0 verifier + negative taxonomy were proven GREEN and **frozen on 2026-03-07**
   (`test_vectors/tier0_frozen/nfl_tier0_green_20260307`, tags `nfl-tier0-green-20260307`,
   `nfl-tier0-release-hygiene-20260307`). This is the milestone the old handoff's WBS-6
   was pointing at — it is **done and frozen**.
2. **After** the freeze, packet-law verification was delegated to CPR
   (commits `cddbe00`, `545fe46`, `446a652`). The local Tier-0 verifier scripts
   (`verify_packet_v1.ps1`, `_selftest_nfl_tier0_locked_v1.ps1`, `scan_inbox.ps1`,
   `nfl_verify_ledger_packet_v1.ps1`, `verify_covenant_packet_v1.ps1`) became
   `throw "NFL_PACKET_LAW_MOVED_TO_CPR"` stubs.
3. A **CLI + operational layer** was built on top: `nfl_cli_v1.ps1`, ledger
   export/sign, CPR witness wrapper, inbox ingest, an ingest scheduled task, and a
   local HTTP API (`nfl_api_v1.ps1`) with project-aware ledger commits.

The Tier-0 lock docs and (until this pass) the README still described the
pre-migration surface. That is the stale-doc gap this reconciliation closes.

---

## 3. Canonical repository surface (after 2026-08-21 hygiene pass)

`scripts/` was reduced from 219 files to ~38 canonical files. ~220 development
artifacts (one-shot `_PATCH_*` / `_RUN_*` / `_AUDIT_*` scripts, `*.bak_*` backups,
dated `_bk_neverlost_*` dirs, and accidental `C:\Users\alecm\` path-bug dirs) were
archived to the gitignored `_to_delete/` folder pending manual deletion.

**Operational (witness / ledger / API / CLI):**
- `scripts/nfl_cli_v1.ps1` — `commit` / `lookup` / `verify`; failures as `NFL_CLI_FAIL:*`
- `scripts/nfl_api_v1.ps1` — local HTTP API: `POST /commit`, `GET /lookup?hash=`, `POST /verify`
- `scripts/nfl_witness_cpr_verify_v1.ps1` — witness wrapper over the CPR verifier
- `scripts/nfl_export_ledger_packet_v1.ps1` / `nfl_sign_ledger_packet_v1.ps1` — export + sign ledger packets
- `scripts/nfl_ingest_inboxes_v1.ps1` / `nfl_ingest_control_v1.ps1` / `nfl_install_ingest_task_v1.ps1` — idempotent inbox ingest + scheduled task
- `scripts/nfl_ops_launch_v1.ps1`, `scripts/nfl.ps1` — operator entrypoints

**Tier-0 frozen evidence surface (historical, keep):**
- `scripts/selftest_vectors_v1.ps1`, `scripts/selftest_verify_packet_v1.ps1`,
  `scripts/_selftest_nfl_tier0_v2.ps1`, and `test_vectors/tier0_frozen/`

**Quarantine stubs (intentional):** `verify_packet_v1.ps1`, `verify_covenant_packet_v1.ps1`,
`_selftest_nfl_tier0_v1.ps1`, `_selftest_nfl_tier0_locked_v1.ps1`,
`nfl_verify_ledger_packet_v1.ps1`, `scan_inbox.ps1` → all raise `NFL_PACKET_LAW_MOVED_TO_CPR`.

**Future-trust scaffolding (kept, not yet wired):** `_bootstrap_neverlost_v1_nfl*.ps1`,
`_lib_neverlost_v1.ps1`.

---

## 4. The ledger and its receipts

- Authoritative ledger: `data/ledger.ndjson` — append-only, one record per commit:
  `{"hash","artifact","timestamp"}`. Untracked in git (the ledger is on-disk data,
  not source), consistent with append-only durability living on disk.
- CLI result tokens: `COMMIT_OK`, `FOUND`, `NOT_FOUND`, `VERIFIED`.
- Frozen Tier-0 evidence bundles under `proofs/receipts/<timestamp>/` (stdout/stderr,
  `nfl.tier0.selftest.v1.ndjson`, `sha256sums.txt`) — tracked, immutable evidence.
- Runtime telemetry logs under `proofs/receipts/*.ndjson` (e.g. `nfl_ingest_runs.ndjson`,
  `nfl.cpr_verify_witness.ndjson`) — high-churn operational output.

**Known operational issue (flagged this pass):** `nfl_ingest_runs.ndjson` had grown to
~310,000 lines / ~28.8 MB because an installed ingest scheduled task fires every few
minutes and appends a run receipt each time (run history spans 2026-04-15 → present).
This telemetry log should not be git-tracked; it is being untracked + gitignored
(the file itself is left intact on disk — append-only is preserved). The scheduled
task's cadence is worth reviewing separately.

---

## 5. Boundaries (unchanged constitution, current owners)

| Concern | Owner |
|---|---|
| Packet-law / Option-A verification | **CPR** (`C:\dev\cpr`) |
| Trust authority (which key/principal is authorized) | **NeverLost** (future integration) |
| Policy / permit decisions | Covenant Gate / Arbiter |
| Witnessing, append-only receipts, ledger | **NFL** |
| Commit/lookup/verify operational surface | **NFL** |

NFL witnesses evidence; it does not manufacture truth, decide trust, or enforce policy.

---

## 6. Accurate WBS status

| Area | Status |
|---|---|
| Tier-0 verifier + negative taxonomy | ✅ frozen 2026-03-07 (now delegated to CPR) |
| CPR delegation of packet-law | ✅ done |
| Ledger CLI (commit/lookup/verify) | ✅ locked |
| Local HTTP API | ✅ present (restored this pass; had been accidentally deleted uncommitted) |
| Ledger export + sign | ✅ present |
| Inbox ingest + scheduled task | ✅ present (telemetry log needs untracking) |
| Repo hygiene | ✅ done this pass (219→38 canonical scripts) |
| Docs reconciled to reality | ✅ this pass (README + this handoff + ecosystem classification) |
| NeverLost trust integration | ⬜ scaffolding only; not wired |
| Durable ledger hardening (hash-chain / checkpoints / export verify) | ⬜ not started |
| Quarantine lane for invalid ingest | ⬜ partial (`packets/quarantine/` exists) |

---

## 7. Real next steps (in order)

1. **Commit the reconciliation baseline** (README fix, hygiene deletions, ingest-log
   untrack, refreshed docs, restored API script).
2. **Review the ingest scheduled task** cadence; rotate/cap `nfl_ingest_runs.ndjson`.
3. **NeverLost trust integration** — replace self-asserted signer trust with an
   authorized-signer resolution (`trust_bundle.json`), with negative tests for
   unknown principal / untrusted key / wrong namespace / revoked signer. Scaffolding
   already exists in `_bootstrap_neverlost_v1_nfl*.ps1` / `_lib_neverlost_v1.ps1`.
4. **Durable ledger hardening** — receipt IDs, canonical serialization, hash-chaining
   or checkpoint roots, checkpoint sealing, export + independent export verification.
5. **Quarantine lane** — deterministic rejection receipts for invalid ingest that never
   enter the valid ledger lane.

Do not start SaaS / licensing / UI work before the standalone instrument (items 3–5)
is independently sealed.
