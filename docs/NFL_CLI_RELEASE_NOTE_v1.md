# NFL CLI Release Note v1

This release freezes the first NFL CLI layer that can:
- commit and look up ledger hashes
- verify file hashes against the ledger
- export a ledger packet
- sign the exported packet with repo-local key material
- verify the signed packet through CPR
- append an NFL witness receipt for CPR verification
- scan configured inboxes and ingest packet/file inputs deterministically

Operational status:
- CLI runtime lane is green
- CPR integration is wired
- NFL witness receipt lane is green
- inbox ingest lane is present
- NFL Explorer UI can observe resulting ledger state

Release markers:
- full green runner: scripts/_RUN_nfl_cli_full_green_v1.ps1
- receipt: proofs/receipts/nfl_cli_full_green.ndjson

This release does not designate NFL as packet-law authority.
Packet verification remains delegated to CPR.
