$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$Inbox = "C:\ProgramData\NFL\inbox"
if (-not (Test-Path -LiteralPath $Inbox)) { throw "Missing inbox dir: $Inbox" }

$dirs = @(Get-ChildItem -LiteralPath $Inbox -Directory -ErrorAction Stop | Sort-Object Name)
if (-not $dirs -or $dirs.Count -eq 0) { "NFL: inbox empty"; exit 0 }

$rows = foreach ($d in $dirs) {
  $man = Join-Path $d.FullName "manifest.json"
  $sum = Join-Path $d.FullName "sha256sums.txt"
  $pay = Join-Path $d.FullName "payload\commit.payload.json"
  $cht = Join-Path $d.FullName "payload\commit_hash.txt"
  $sig = Join-Path $d.FullName "signatures\ingest.sig"

  [pscustomobject]@{
    packet_dir        = $d.Name
    has_manifest      = (Test-Path -LiteralPath $man)
    has_sha256sums    = (Test-Path -LiteralPath $sum)
    has_commit_payload= (Test-Path -LiteralPath $pay)
    has_commit_hash   = (Test-Path -LiteralPath $cht)
    has_ingest_sig    = (Test-Path -LiteralPath $sig)
  }
}

$rows | Format-Table -AutoSize
