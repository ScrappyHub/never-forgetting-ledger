param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m) {
  throw ("NFL_INGEST_FAIL:" + $m)
}

function Ensure-Dir([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return }
  if (-not (Test-Path -LiteralPath $p -PathType Container)) {
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}

function New-Utf8NoBom() {
  return New-Object System.Text.UTF8Encoding($false)
}

function Normalize-Lf([string]$t) {
  if ($null -eq $t) { return "" }
  $u = ($t -replace "`r`n", "`n") -replace "`r", "`n"
  if (-not $u.EndsWith("`n")) { $u += "`n" }
  return $u
}

function Read-Utf8([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Fail ("READ_MISSING:" + $Path)
  }
  return [System.IO.File]::ReadAllText($Path, (New-Utf8NoBom))
}

function Write-Utf8NoBomLf([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if ($dir) { Ensure-Dir $dir }
  $u = Normalize-Lf $Text
  [System.IO.File]::WriteAllBytes($Path, (New-Utf8NoBom).GetBytes($u))
}

function Append-JsonLine([string]$Path, [hashtable]$Obj) {
  $line = (($Obj | ConvertTo-Json -Compress -Depth 20) + "`n")
  Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Resolve-FullPath([string]$PathValue) {
  if ([string]::IsNullOrWhiteSpace($PathValue)) {
    Fail "EMPTY_PATH"
  }
  return [System.IO.Path]::GetFullPath($PathValue)
}

function Get-ProcessKeyPacket([string]$InboxName, [string]$FullPath) {
  return ("packet|" + $InboxName + "|" + $FullPath.ToLowerInvariant())
}

function Get-ProcessKeyFile([string]$InboxName, [string]$Hash) {
  return ("file|" + $InboxName + "|" + $Hash.ToLowerInvariant())
}

function Get-Sha256HexFile([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    Fail ("HASH_MISSING:" + $Path)
  }
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Start-Child([string]$FileName, [string]$Arguments, [string]$WorkingDir) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FileName
  $psi.Arguments = $Arguments
  $psi.WorkingDirectory = $WorkingDir
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true

  $p = New-Object System.Diagnostics.Process
  $p.StartInfo = $psi
  [void]$p.Start()

  $stdout = $p.StandardOutput.ReadToEnd()
  $stderr = $p.StandardError.ReadToEnd()
  $p.WaitForExit()

  return [pscustomobject]@{
    ExitCode = [int]$p.ExitCode
    StdOut   = $stdout
    StdErr   = $stderr
  }
}

function Load-SeenKeys([string]$StatePath) {
  $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

  if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) {
    return $set
  }

  $lines = Get-Content -LiteralPath $StatePath -Encoding UTF8
  foreach ($line in @(@($lines))) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }

    try {
      $obj = $line | ConvertFrom-Json -ErrorAction Stop
      if ($null -ne $obj.process_key) {
        [void]$set.Add([string]$obj.process_key)
      }
    }
    catch {
      continue
    }
  }

  return $set
}

function Assert-InboxMode([string]$Mode, [string]$InboxName) {
  if (($Mode -ne "packet") -and ($Mode -ne "file")) {
    Fail ("BAD_MODE:" + $InboxName + ":" + $Mode)
  }
}

function Invoke-PacketIngest(
  [string]$RepoRoot,
  [string]$InboxName,
  [string]$PacketDir,
  [string]$WitnessPath,
  [string]$CprVerifier,
  [string]$PSExe
) {
  $args = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}" -CprVerifierPath "{2}" -PacketDir "{3}"' -f $WitnessPath, $RepoRoot, $CprVerifier, $PacketDir)
  $res = Start-Child -FileName $PSExe -Arguments $args -WorkingDir $RepoRoot

  $ok = ($res.ExitCode -eq 0) -and ($res.StdOut -match 'NFL_WITNESS_CPR_VERIFY_OK')

  return [pscustomobject]@{
    Ok       = $ok
    ExitCode = [int]$res.ExitCode
    StdOut   = $res.StdOut
    StdErr   = $res.StdErr
    Mode     = "packet"
    Inbox    = $InboxName
    ItemPath = $PacketDir
  }
}

function Invoke-FileIngest(
  [string]$RepoRoot,
  [string]$InboxName,
  [string]$FilePath,
  [string]$CliPath,
  [string]$PSExe
) {
  $hash = Get-Sha256HexFile $FilePath
  $args = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" commit -Hash "{1}" -Artifact "{2}"' -f $CliPath, $hash, $FilePath)
  $res = Start-Child -FileName $PSExe -Arguments $args -WorkingDir $RepoRoot

  $ok = ($res.ExitCode -eq 0) -and ($res.StdOut -match 'COMMIT_OK')

  return [pscustomobject]@{
    Ok       = $ok
    ExitCode = [int]$res.ExitCode
    StdOut   = $res.StdOut
    StdErr   = $res.StdErr
    Mode     = "file"
    Inbox    = $InboxName
    ItemPath = $FilePath
    Sha256   = $hash
  }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$ConfigPath   = Join-Path $RepoRoot "config\inbox_registry.json"
$CliPath      = Join-Path $RepoRoot "scripts\nfl_cli_v1.ps1"
$WitnessPath  = Join-Path $RepoRoot "scripts\nfl_witness_cpr_verify_v1.ps1"
$CprVerifier  = "C:\dev\cpr\scripts\verify_packet_v1.ps1"
$PSExe        = (Get-Command powershell.exe -ErrorAction Stop).Source

$ReceiptDir   = Join-Path $RepoRoot "proofs\receipts"
$StatePath    = Join-Path $ReceiptDir "nfl_ingest_state.ndjson"
$RunPath      = Join-Path $ReceiptDir "nfl_ingest_runs.ndjson"

Ensure-Dir $ReceiptDir

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { Fail "INBOX_REGISTRY_MISSING" }
if (-not (Test-Path -LiteralPath $CliPath -PathType Leaf)) { Fail "NFL_CLI_MISSING" }
if (-not (Test-Path -LiteralPath $WitnessPath -PathType Leaf)) { Fail "WITNESS_WRAPPER_MISSING" }
if (-not (Test-Path -LiteralPath $CprVerifier -PathType Leaf)) { Fail "CPR_VERIFIER_MISSING" }

$config = (Read-Utf8 $ConfigPath) | ConvertFrom-Json -ErrorAction Stop
if ([string]$config.schema -ne "nfl.inbox_registry.v1") { Fail "BAD_REGISTRY_SCHEMA" }
if ($null -eq $config.inboxes) { Fail "INBOXES_MISSING" }

$Seen = Load-SeenKeys $StatePath

$RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$Scanned = 0
$Processed = 0
$Skipped = 0
$Failed = 0

foreach ($inbox in @($config.inboxes)) {
  $name = [string]$inbox.name
  $path = [string]$inbox.path
  $mode = [string]$inbox.mode

  if ([string]::IsNullOrWhiteSpace($name)) { Fail "INBOX_NAME_MISSING" }
  if ([string]::IsNullOrWhiteSpace($path)) { Fail ("INBOX_PATH_MISSING:" + $name) }

  Assert-InboxMode -Mode $mode -InboxName $name

  $fullPath = Resolve-FullPath $path
  Ensure-Dir $fullPath

  if ($mode -eq "packet") {
    $packetDirs = @(Get-ChildItem -LiteralPath $fullPath -Directory -ErrorAction SilentlyContinue | Sort-Object Name)

    foreach ($dir in @(@($packetDirs))) {
      $Scanned++
      $processKey = Get-ProcessKeyPacket -InboxName $name -FullPath $dir.FullName

      if ($Seen.Contains($processKey)) {
        $Skipped++
        continue
      }

      $result = Invoke-PacketIngest -RepoRoot $RepoRoot -InboxName $name -PacketDir $dir.FullName -WitnessPath $WitnessPath -CprVerifier $CprVerifier -PSExe $PSExe

      if ($result.Ok) { $Processed++ } else { $Failed++ }

      Append-JsonLine $StatePath ([ordered]@{
        schema      = "nfl.ingest.state.v1"
        utc         = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        process_key = $processKey
        inbox_name  = $result.Inbox
        mode        = $result.Mode
        item_path   = $result.ItemPath
        ok          = $result.Ok
        exit_code   = $result.ExitCode
        stdout      = $result.StdOut
        stderr      = $result.StdErr
      })

      [void]$Seen.Add($processKey)
    }
  }

  if ($mode -eq "file") {
    $files = @(Get-ChildItem -LiteralPath $fullPath -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)

    foreach ($file in @(@($files))) {
      $Scanned++
      $hash = Get-Sha256HexFile $file.FullName
      $processKey = Get-ProcessKeyFile -InboxName $name -Hash $hash

      if ($Seen.Contains($processKey)) {
        $Skipped++
        continue
      }

      $result = Invoke-FileIngest -RepoRoot $RepoRoot -InboxName $name -FilePath $file.FullName -CliPath $CliPath -PSExe $PSExe

      if ($result.Ok) { $Processed++ } else { $Failed++ }

      Append-JsonLine $StatePath ([ordered]@{
        schema      = "nfl.ingest.state.v1"
        utc         = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        process_key = $processKey
        inbox_name  = $result.Inbox
        mode        = $result.Mode
        item_path   = $result.ItemPath
        sha256      = $result.Sha256
        ok          = $result.Ok
        exit_code   = $result.ExitCode
        stdout      = $result.StdOut
        stderr      = $result.StdErr
      })

      [void]$Seen.Add($processKey)
    }
  }
}

Append-JsonLine $RunPath ([ordered]@{
  schema    = "nfl.ingest.run.receipt.v1"
  utc       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  run_id    = $RunId
  ok        = ($Failed -eq 0)
  repo_root = $RepoRoot
  scanned   = $Scanned
  processed = $Processed
  skipped   = $Skipped
  failed    = $Failed
})

# Persist last-run state for CLI/UI
$RuntimeDir = Join-Path $RepoRoot "runtime\ingest"
Ensure-Dir $RuntimeDir

$LastRunPath = Join-Path $RuntimeDir "last_run.json"

$lastRun = [ordered]@{
  schema    = "nfl.ingest.last_run.v1"
  run_id    = $RunId
  utc       = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  scanned   = [int]$Scanned
  processed = [int]$Processed
  skipped   = [int]$Skipped
  failed    = [int]$Failed
  ok        = ($Failed -eq 0)
}

$lastRunJson = ($lastRun | ConvertTo-Json -Depth 10)
[System.IO.File]::WriteAllText(
  $LastRunPath,
  (Normalize-Lf $lastRunJson),
  (New-Utf8NoBom)
)

Write-Output "NFL_INGEST_INBOXES_OK"
Write-Output ("RUN_ID=" + $RunId)
Write-Output ("SCANNED=" + $Scanned)
Write-Output ("PROCESSED=" + $Processed)
Write-Output ("SKIPPED=" + $Skipped)
Write-Output ("FAILED=" + $Failed)