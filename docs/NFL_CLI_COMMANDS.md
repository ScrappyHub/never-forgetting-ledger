# NFL CLI Commands

## 1. Commit
Command:
powershell.exe -File scripts/nfl_cli_v1.ps1 commit -Hash <hash> -Artifact <artifact>

Success token:
COMMIT_OK

## 2. Lookup
Command:
powershell.exe -File scripts/nfl_cli_v1.ps1 lookup -Hash <hash>

Success token:
FOUND

## 3. Verify
Command:
powershell.exe -File scripts/nfl_cli_v1.ps1 verify -File <path>

Success token:
VERIFIED
or
NOT_FOUND

## 4. Export ledger packet
Command:
powershell.exe -File scripts/nfl_export_ledger_packet_v1.ps1 -RepoRoot C:/dev/nfl

Success token:
NFL_EXPORT_LEDGER_PACKET_OK

## 5. Sign packet
Command:
powershell.exe -File scripts/nfl_sign_ledger_packet_v1.ps1 -PacketDir <packetDir> -SigningKeyPath C:/dev/nfl/proofs/keys/id_ed25519 -SignerIdentity nfl.local

Success token:
NFL_SIGN_PACKET_OK

## 6. CPR witness verify
Command:
powershell.exe -File scripts/nfl_witness_cpr_verify_v1.ps1 -RepoRoot C:/dev/nfl -CprVerifierPath C:/dev/cpr/scripts/verify_packet_v1.ps1 -PacketDir <packetDir>

Success token:
NFL_WITNESS_CPR_VERIFY_OK

## 7. Ingest inboxes
Command:
powershell.exe -File scripts/nfl_ingest_inboxes_v1.ps1 -RepoRoot C:/dev/nfl

Success token:
NFL_INGEST_INBOXES_OK

## 8. Install ingest task
Command:
powershell.exe -File scripts/nfl_install_ingest_task_v1.ps1 -RepoRoot C:/dev/nfl

Success token:
NFL_INSTALL_INGEST_TASK_OK

## 9. Full green runner
Command:
powershell.exe -File scripts/_RUN_nfl_cli_full_green_v1.ps1 -RepoRoot C:/dev/nfl

Success token:
NFL_CLI_FULL_GREEN_OK
