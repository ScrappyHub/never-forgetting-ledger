param(
  [Parameter(Mandatory=$true)][string]$AgentPath,
  [Parameter(Mandatory=$true)][string]$ConfigPath,
  [Parameter(Mandatory=$true)][string]$ReceiptLogPath
)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$TaskName = "EchoOutboxAgent_v1"
$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
if (-not (Test-Path -LiteralPath $AgentPath -PathType Leaf)) { throw ("Missing agent: " + $AgentPath) }
if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw ("Missing config: " + $ConfigPath) }
$rdir = Split-Path -Parent $ReceiptLogPath
if ($rdir -and -not (Test-Path -LiteralPath $rdir -PathType Container)) { New-Item -ItemType Directory -Force -Path $rdir | Out-Null }

$args = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}" -ReceiptLogPath "{2}"' -f $AgentPath,$ConfigPath,$ReceiptLogPath
$tr   = '"{0}" {1}' -f $PSExe,$args
Write-Host ("TASK_TR: " + $tr) -ForegroundColor Cyan

try { schtasks.exe /Delete /TN $TaskName /F | Out-Null } catch { }

# Non-admin install: do NOT request HIGHEST.
schtasks.exe /Create /TN $TaskName /SC MINUTE /MO 1 /F /TR $tr | Out-Null
Write-Host ("INSTALLED_TASK: " + $TaskName) -ForegroundColor Green

# Kick once immediately (in-process) so you see it run now
& $PSExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $AgentPath -ConfigPath $ConfigPath -ReceiptLogPath $ReceiptLogPath
Write-Host "KICK_OK" -ForegroundColor Green
