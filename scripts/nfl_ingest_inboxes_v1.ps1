param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){ throw ("NFL_INGEST_FAIL:" + $m) }

function EnsureDir([string]$p){
  if([string]::IsNullOrWhiteSpace($p)){ return }
  if(-not (Test-Path -LiteralPath $p -PathType Container)){
    New-Item -ItemType Directory -Force -Path $p | Out-Null
  }
}

function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }

function NormalizeLf([string]$t){
  if($null -eq $t){ return "" }
  $u = ($t -replace "`r`n","`n") -replace "`r","`n"
  if(-not $u.EndsWith("`n")){ $u += "`n" }
  return $u
}

function ReadUtf8([string]$Path){
  if(-not (Test-Path -LiteralPath $Path -PathType Leaf)){ Fail ("READ_MISSING:" + $Path) }
  return [System.IO.File]::ReadAllText($Path,(Utf8NoBom))
}

function StartChild([string]$FileName,[string]$Arguments,[string]$WorkingDir){
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

function AppendJsonLine([string]$Path,[hashtable]$Obj){
  $line = (($Obj | ConvertTo-Json -Compress -Depth 20) + "`n")
  Add-Content -LiteralPath $Path -Value $line -Encoding UTF8
}

function Sha256HexFile([string]$Path){
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$ConfigPath = Join-Path $RepoRoot "config\inbox_registry.json"
$CliPath = Join-Path $RepoRoot "scripts\nfl_cli_v1.ps1"
$WitnessPath = Join-Path $RepoRoot "scripts\nfl_witness_cpr_verify_v1.ps1"
$CprVerifier = "C:\dev\cpr\scripts\verify_packet_v1.ps1"
$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source

$ReceiptDir = Join-Path $RepoRoot "proofs\receipts"
$StatePath  = Join-Path $ReceiptDir "nfl_ingest_state.ndjson"
$RunPath    = Join-Path $ReceiptDir "nfl_ingest_runs.ndjson"

EnsureDir $ReceiptDir

if(-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)){ Fail "INBOX_REGISTRY_MISSING" }
if(-not (Test-Path -LiteralPath $CliPath -PathType Leaf)){ Fail "NFL_CLI_MISSING" }
if(-not (Test-Path -LiteralPath $WitnessPath -PathType Leaf)){ Fail "WITNESS_WRAPPER_MISSING" }
if(-not (Test-Path -LiteralPath $CprVerifier -PathType Leaf)){ Fail "CPR_VERIFIER_MISSING" }

$config = (ReadUtf8 $ConfigPath) | ConvertFrom-Json -ErrorAction Stop
if([string]$config.schema -ne "nfl.inbox_registry.v1"){ Fail "BAD_REGISTRY_SCHEMA" }

$Seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
if(Test-Path -LiteralPath $StatePath -PathType Leaf){
  foreach($line in @(Get-Content -LiteralPath $StatePath -Encoding UTF8)){
    if([string]::IsNullOrWhiteSpace($line)){ continue }
    try {
      $obj = $line | ConvertFrom-Json -ErrorAction Stop
      if($null -ne $obj.process_key){ [void]$Seen.Add([string]$obj.process_key) }
    } catch {}
  }
}

$RunId = (Get-Date).ToUniversalTime().ToString("yyyyMMddTHHmmssZ")
$Scanned = 0
$Processed = 0
$Skipped = 0
$Failed = 0

foreach($inbox in @($config.inboxes)){
  $name = [string]$inbox.name
  $path = [string]$inbox.path
  $mode = [string]$inbox.mode

  if([string]::IsNullOrWhiteSpace($name)){ Fail "INBOX_NAME_MISSING" }
  if([string]::IsNullOrWhiteSpace($path)){ Fail ("INBOX_PATH_MISSING:" + $name) }
  if(($mode -ne "packet") -and ($mode -ne "file")){ Fail ("BAD_MODE:" + $name) }

  $fullPath = [System.IO.Path]::GetFullPath($path)
  EnsureDir $fullPath

  if($mode -eq "packet"){
    foreach($dir in @(Get-ChildItem -LiteralPath $fullPath -Directory -ErrorAction SilentlyContinue | Sort-Object Name)){
      $Scanned++
      $key = ("packet|" + $name + "|" + $dir.FullName.ToLowerInvariant())
      if($Seen.Contains($key)){
        $Skipped++
        continue
      }

      $res = StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}" -CprVerifierPath "{2}" -PacketDir "{3}"' -f $WitnessPath,$RepoRoot,$CprVerifier,$dir.FullName) $RepoRoot
      $ok = ($res.ExitCode -eq 0) -and ($res.StdOut -match 'NFL_WITNESS_CPR_VERIFY_OK')

      if($ok){ $Processed++ } else { $Failed++ }

      AppendJsonLine $StatePath ([ordered]@{
        schema = "nfl.ingest.state.v1"
        utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        process_key = $key
        inbox_name = $name
        mode = $mode
        item_path = $dir.FullName
        ok = $ok
        exit_code = [int]$res.ExitCode
        stdout = $res.StdOut
        stderr = $res.StdErr
      })

      [void]$Seen.Add($key)
    }
  }

  if($mode -eq "file"){
    foreach($file in @(Get-ChildItem -LiteralPath $fullPath -File -Recurse -ErrorAction SilentlyContinue | Sort-Object FullName)){
      $Scanned++
      $hash = Sha256HexFile $file.FullName
      $key = ("file|" + $name + "|" + $hash)
      if($Seen.Contains($key)){
        $Skipped++
        continue
      }

      $res = StartChild $PSExe ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" commit -Hash "{1}" -Artifact "{2}"' -f $CliPath,$hash,$file.FullName) $RepoRoot
      $ok = ($res.ExitCode -eq 0) -and ($res.StdOut -match 'COMMIT_OK')

      if($ok){ $Processed++ } else { $Failed++ }

      AppendJsonLine $StatePath ([ordered]@{
        schema = "nfl.ingest.state.v1"
        utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        process_key = $key
        inbox_name = $name
        mode = $mode
        item_path = $file.FullName
        sha256 = $hash
        ok = $ok
        exit_code = [int]$res.ExitCode
        stdout = $res.StdOut
        stderr = $res.StdErr
      })

      [void]$Seen.Add($key)
    }
  }
}

AppendJsonLine $RunPath ([ordered]@{
  schema = "nfl.ingest.run.receipt.v1"
  utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
  run_id = $RunId
  ok = ($Failed -eq 0)
  repo_root = $RepoRoot
  scanned = $Scanned
  processed = $Processed
  skipped = $Skipped
  failed = $Failed
})

Write-Output "NFL_INGEST_INBOXES_OK"
Write-Output ("RUN_ID=" + $RunId)
Write-Output ("SCANNED=" + $Scanned)
Write-Output ("PROCESSED=" + $Processed)
Write-Output ("SKIPPED=" + $Skipped)
Write-Output ("FAILED=" + $Failed)
