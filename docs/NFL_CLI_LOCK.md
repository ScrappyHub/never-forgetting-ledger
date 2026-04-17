# NFL CLI Lock

Never Forgetting Ledger CLI is the first shippable operational surface for NFL.

Locked public scripts:
- scripts/nfl_cli_v1.ps1
- scripts/nfl_export_ledger_packet_v1.ps1
- scripts/nfl_sign_ledger_packet_v1.ps1
- scripts/nfl_witness_cpr_verify_v1.ps1
- scripts/nfl_ingest_inboxes_v1.ps1
- scripts/nfl_install_ingest_task_v1.ps1
- scripts/_RUN_nfl_cli_full_green_v1.ps1

Authoritative packet-law verifier:
- C:/dev/cpr/scripts/verify_packet_v1.ps1

Locked CLI guarantees:
- deterministic PowerShell 5.1 strict-mode scripts
- append-only receipts
- no in-place verification repair
- packet verification delegated to CPR
- NFL acts as witness/ledger, not packet-law authority
- inbox ingest is idempotent by process key

Definition of CLI full-green:
- commit returns COMMIT_OK
- lookup returns FOUND for committed smoke hash
- verify returns VERIFIED or NOT_FOUND without crashing
- export returns NFL_EXPORT_LEDGER_PACKET_OK
- sign returns NFL_SIGN_PACKET_OK
- CPR verifier returns CPR_VERIFY_OK
- NFL witness wrapper returns NFL_WITNESS_CPR_VERIFY_OK
- inbox ingest returns NFL_INGEST_INBOXES_OK
- _RUN_nfl_cli_full_green_v1.ps1 returns NFL_CLI_FULL_GREEN_OK
