param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){ throw ("NFL_INSTALL_TASK_FAIL:" + $m) }

$TaskName = "NFL_Ingest_Inboxes_v1"
$PSExe    = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$Runner   = Join-Path $RepoRoot "scripts\nfl_ingest_inboxes_v1.ps1"

if(-not (Test-Path -LiteralPath $Runner)){
  Fail ("MISSING_RUNNER:" + $Runner)
}

# Build command (must be ONE string)
$Cmd = "`"$PSExe`" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Runner`" -RepoRoot `"$RepoRoot`""

# Delete existing task (ignore failure)
& schtasks.exe /Delete /TN $TaskName /F 2>$null | Out-Null

# Create task (runs every 1 minute)
$Create = @(
  "/Create",
  "/SC", "MINUTE",
  "/MO", "1",
  "/TN", $TaskName,
  "/TR", $Cmd,
  "/RL", "HIGHEST",
  "/F"
)

$proc = Start-Process -FilePath "schtasks.exe" -ArgumentList $Create -NoNewWindow -Wait -PassThru

if($proc.ExitCode -ne 0){
  Fail ("SCHTASKS_CREATE_FAILED:EXITCODE=" + $proc.ExitCode)
}

# Verify existence
$verify = schtasks /Query /TN $TaskName 2>$null
if(-not $verify){
  Fail "TASK_NOT_FOUND_AFTER_CREATE"
}

Write-Output "NFL_INSTALL_INGEST_TASK_OK"
Write-Output ("TASK_NAME=" + $TaskName)