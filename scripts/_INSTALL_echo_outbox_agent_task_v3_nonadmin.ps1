param(
  [Parameter(Mandatory=$true)][string]$TaskName,
  [Parameter(Mandatory=$true)][string]$RunnerPath,
  [Parameter(Mandatory=$true)][string]$ReceiptLogPath
)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

function Invoke-Schtasks {
  param([Parameter(Mandatory=$true)][string[]]$Args)
  if ($null -eq $Args -or $Args.Count -eq 0) { Die "Invoke-Schtasks: empty args" }
  for($i=0;$i -lt $Args.Count;$i++){ if ($null -eq $Args[$i] -or $Args[$i].Length -eq 0) { Die ("Invoke-Schtasks: null/empty arg at index " + $i) } }
  Write-Host ("SCHTASKS " + ($Args -join " ")) -ForegroundColor DarkGray
  & schtasks.exe @Args | Out-Null
  if ($LASTEXITCODE -ne 0) { Die ("schtasks.exe failed exit=" + $LASTEXITCODE + " args=" + ($Args -join " ")) }
}

if (-not (Test-Path -LiteralPath $RunnerPath -PathType Leaf)) { Die ("Missing runner: " + $RunnerPath) }
$rdir = Split-Path -Parent $ReceiptLogPath
if ($rdir -and -not (Test-Path -LiteralPath $rdir -PathType Container)) { New-Item -ItemType Directory -Force -Path $rdir | Out-Null }

$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
$tr = ('"{0}" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{1}"' -f $PSExe, $RunnerPath)
Write-Host ("TASK_TR_SHORT: " + $tr) -ForegroundColor Cyan

# Delete (ignore failures)
try { Invoke-Schtasks -Args @("/Delete","/TN",$TaskName,"/F") } catch { }

# Create (MUST succeed)
Invoke-Schtasks -Args @("/Create","/TN",$TaskName,"/SC","MINUTE","/MO","1","/F","/TR",$tr)
Write-Host ("INSTALLED_TASK_OK: " + $TaskName) -ForegroundColor Green

# Try to reduce common non-run causes (best-effort; may fail on some SKUs)
try { Invoke-Schtasks -Args @("/Change","/TN",$TaskName,"/DISABLE") ; Invoke-Schtasks -Args @("/Change","/TN",$TaskName,"/ENABLE") } catch { }

# Force a scheduler run (this is the proof path, not the manual kick)
Invoke-Schtasks -Args @("/Run","/TN",$TaskName)
Start-Sleep -Seconds 2

# Receipt is ground truth
if (Test-Path -LiteralPath $ReceiptLogPath -PathType Leaf) {
  $tail = Get-Content -LiteralPath $ReceiptLogPath -Tail 20
  Write-Host "RECEIPTS_TAIL:" -ForegroundColor Cyan
  $tail | ForEach-Object { Write-Host $_ }
} else {
  Write-Host ("MISSING_RECEIPT_LOG: " + $ReceiptLogPath) -ForegroundColor Yellow
}
Write-Host "INSTALL_V3_DONE" -ForegroundColor Green
