param([string]$RepoRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Targets = @(
  "scripts\verify_packet_v1.ps1",
  "scripts\nfl_verify_ledger_packet_v1.ps1",
  "scripts\verify_covenant_packet_v1.ps1",
  "scripts\scan_inbox.ps1",
  "scripts\_selftest_nfl_tier0_v1.ps1",
  "scripts\_selftest_nfl_tier0_locked_v1.ps1"
)

$Guard = "throw `"NFL_PACKET_LAW_MOVED_TO_CPR`""

$Patched = @()

foreach($Rel in $Targets){
  $Path = Join-Path $RepoRoot $Rel
  if(Test-Path $Path){
    $Orig = Get-Content $Path -Raw

    if($Orig -notmatch "NFL_PACKET_LAW_MOVED_TO_CPR"){
      $BackupDir = Join-Path $RepoRoot "scripts\_quarantine_legacy_packet_law"
      if(-not (Test-Path $BackupDir)){ New-Item -ItemType Directory -Path $BackupDir | Out-Null }

      $Backup = Join-Path $BackupDir ($Rel.Replace("\","__") + ".bak")
      Set-Content $Backup $Orig

      Set-Content $Path $Guard
    }

    $Patched += $Rel
  }
}

$ReceiptPath = Join-Path $RepoRoot "proofs\receipts\nfl.cpr.transition.ndjson"
$Line = '{"event":"legacy_quarantine","patched_count":' + $Patched.Count + '}'

Add-Content $ReceiptPath $Line

Write-Host "NFL_LEGACY_QUARANTINE_OK"
