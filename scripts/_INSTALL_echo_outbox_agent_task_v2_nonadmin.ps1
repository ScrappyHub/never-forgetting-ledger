param(
  [Parameter(Mandatory=$true)][string]$TaskName,
  [Parameter(Mandatory=$true)][string]$RunnerPath
)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

function Invoke-Schtasks {
  param([Parameter(Mandatory=$true)][string[]]$Args)
  if ($null -eq $Args -or $Args.Count -eq 0) { Die "Invoke-Schtasks: empty args" }
  for($i=0;$i -lt $Args.Count;$i++){
    if ($null -eq $Args[$i] -or $Args[$i].Length -eq 0) { Die ("Invoke-Schtasks: null/empty arg at index " + $i) }
  }
  Write-Host ("SCHTASKS " + ($Args -join " ")) -ForegroundColor DarkGray
  & schtasks.exe @Args | Out-Null
  if ($LASTEXITCODE -ne 0) { Die ("schtasks.exe failed exit=" + $LASTEXITCODE + " args=" + ($Args -join " ")) }
}

if (-not (Test-Path -LiteralPath $RunnerPath -PathType Leaf)) { Die ("Missing runner: " + $RunnerPath) }
$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$tr = ('"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{1}"' -f $PSExe, $RunnerPath)
Write-Host ("TASK_TR_SHORT: " + $tr) -ForegroundColor Cyan

# Delete (ignore failures)
try { Invoke-Schtasks -Args @("/Delete","/TN",$TaskName,"/F") } catch { }

# Create (MUST succeed)
Invoke-Schtasks -Args @("/Create","/TN",$TaskName,"/SC","MINUTE","/MO","1","/F","/TR",$tr)
Write-Host ("INSTALLED_TASK_OK: " + $TaskName) -ForegroundColor Green

# Kick once now (runner -> agent)
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $RunnerPath
if ($LASTEXITCODE -ne 0) { Die ("Kick failed exit=" + $LASTEXITCODE) }
Write-Host "KICK_OK" -ForegroundColor Green
