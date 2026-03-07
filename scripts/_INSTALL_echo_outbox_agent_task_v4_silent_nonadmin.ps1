param(
  [Parameter(Mandatory=$true)][string]$TaskName,
  [Parameter(Mandatory=$true)][string]$RunnerPath
)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }

function Invoke-Schtasks {
  param([Parameter(Mandatory=$true)][string[]]$Args)
  $a = @(@($Args))
  if ($null -eq $a -or $a.Count -eq 0) { Die "Invoke-Schtasks: empty args" }
  for($i=0;$i -lt $a.Count;$i++){ if ($null -eq $a[$i] -or $a[$i].Length -eq 0) { Die ("Invoke-Schtasks: null/empty arg at index " + $i) } }
  Write-Host ("SCHTASKS " + ($a -join " ")) -ForegroundColor DarkGray
  & schtasks.exe @a | Out-Null
  if ($LASTEXITCODE -ne 0) { Die ("schtasks.exe failed exit=" + $LASTEXITCODE + " args=" + ($a -join " ")) }
}

if (-not (Test-Path -LiteralPath $RunnerPath -PathType Leaf)) { Die ("Missing runner: " + $RunnerPath) }

$PSExe = (Get-Command powershell.exe -ErrorAction Stop).Source
# Keep /TR short; still request hidden window style as belt+suspenders.
$tr = ('"{0}" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{1}"' -f $PSExe, $RunnerPath)
Write-Host ("TASK_TR_SHORT: " + $tr) -ForegroundColor Cyan

# Run as current user, but NON-INTERACTIVE: /RU <user> /NP (no stored password)
$ru = ($env:USERDOMAIN + "\" + $env:USERNAME)
Write-Host ("TASK_RU: " + $ru + " (NP=1)") -ForegroundColor Cyan

# Delete (ignore failures)
try { Invoke-Schtasks -Args @("/Delete","/TN",$TaskName,"/F") } catch { }

# Create: every 1 minute; /NP prevents interactive window + avoids password prompts
Invoke-Schtasks -Args @("/Create","/TN",$TaskName,"/SC","MINUTE","/MO","1","/F","/RU",$ru,"/NP","/TR",$tr)
Write-Host ("INSTALLED_TASK_OK: " + $TaskName) -ForegroundColor Green

# Best-effort enable + run once via scheduler
try { Invoke-Schtasks -Args @("/Change","/TN",$TaskName,"/ENABLE") } catch { }
try { Invoke-Schtasks -Args @("/Run","/TN",$TaskName) } catch { }
Write-Host "INSTALL_V4_DONE" -ForegroundColor Green
