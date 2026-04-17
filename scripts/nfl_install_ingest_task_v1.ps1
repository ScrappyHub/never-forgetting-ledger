param(
  [Parameter(Mandatory=$true)][string]$RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){ throw ("NFL_INSTALL_INGEST_TASK_FAIL:" + $m) }

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$Runner = Join-Path $RepoRoot "scripts\nfl_ingest_inboxes_v1.ps1"
if(-not (Test-Path -LiteralPath $Runner -PathType Leaf)){ Fail "RUNNER_MISSING" }

$TaskName = "NFL_Ingest_Inboxes_v1"
$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source

$Action = New-ScheduledTaskAction `
  -Execute $PSExe `
  -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -RepoRoot "{1}"' -f $Runner,$RepoRoot)

$Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1)
$Trigger.Repetition = (New-TimeSpan -Minutes 1)
$Trigger.RepetitionDuration = ([TimeSpan]::MaxValue)

$Principal = New-ScheduledTaskPrincipal `
  -UserId $env:USERNAME `
  -LogonType Interactive `
  -RunLevel Limited

$Settings = New-ScheduledTaskSettingsSet `
  -AllowStartIfOnBatteries `
  -DontStopIfGoingOnBatteries

Register-ScheduledTask `
  -TaskName $TaskName `
  -Action $Action `
  -Trigger $Trigger `
  -Principal $Principal `
  -Settings $Settings `
  -Force | Out-Null

Write-Output "NFL_INSTALL_INGEST_TASK_OK"
Write-Output ("TASK_NAME=" + $TaskName)