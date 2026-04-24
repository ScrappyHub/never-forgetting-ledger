param(
  [Parameter(Mandatory=$true)]
  [ValidateSet("start","stop","run-once","status")]
  [string]$Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Fail([string]$m){
  throw ("NFL_INGEST_CONTROL_FAIL:" + $m)
}

$TaskName = "NFL_Ingest_Inboxes_v1"

function Get-TaskOrNull([string]$Name){
  try {
    return Get-ScheduledTask -TaskName $Name -ErrorAction Stop
  } catch {
    return $null
  }
}

$task = Get-TaskOrNull $TaskName
if($null -eq $task){
  Fail ("TASK_MISSING:" + $TaskName)
}

switch($Action){
  "start" {
    Enable-ScheduledTask -TaskName $TaskName | Out-Null
    Write-Output "NFL_INGEST_STARTED"
  }
  "stop" {
    Disable-ScheduledTask -TaskName $TaskName | Out-Null
    Write-Output "NFL_INGEST_STOPPED"
  }
  "run-once" {
    Start-ScheduledTask -TaskName $TaskName
    Write-Output "NFL_INGEST_TRIGGERED"
  }
  "status" {
    $fresh = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    Write-Output ("STATE=" + $fresh.State)
  }
}