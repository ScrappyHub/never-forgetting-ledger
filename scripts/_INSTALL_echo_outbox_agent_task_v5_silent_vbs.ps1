param([Parameter(Mandatory=$true)][string]$TaskName)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function Invoke-Schtasks { param([Parameter(Mandatory=$true)][string[]]$Args)
  $a = @(@($Args))
  if ($null -eq $a -or $a.Count -eq 0) { Die "Invoke-Schtasks: empty args" }
  for($i=0;$i -lt $a.Count;$i++){ if ($null -eq $a[$i] -or $a[$i].Length -eq 0) { Die ("Invoke-Schtasks: null/empty arg at index " + $i) } }
  Write-Host ("SCHTASKS " + ($a -join " ")) -ForegroundColor DarkGray
  & schtasks.exe @a | Out-Null
  if ($LASTEXITCODE -ne 0) { Die ("schtasks.exe failed exit=" + $LASTEXITCODE + " args=" + ($a -join " ")) }
}

$VbsPath    = "C:\ProgramData\EchoOutboxAgent\run_echo_outbox_agent_v1.vbs"
if (-not (Test-Path -LiteralPath $VbsPath -PathType Leaf)) { Die ("Missing VBS: " + $VbsPath) }

$WScript = Join-Path $env:WINDIR "System32\wscript.exe"
if (-not (Test-Path -LiteralPath $WScript -PathType Leaf)) { Die ("Missing wscript.exe: " + $WScript) }

# /TR must be short; run hidden via wscript //B //Nologo
$tr = ('"{0}" //B //Nologo "{1}"' -f $WScript, $VbsPath)
Write-Host ("TASK_TR_SILENT: " + $tr) -ForegroundColor Cyan

try { Invoke-Schtasks -Args @("/Delete","/TN",$TaskName,"/F") } catch { }
Invoke-Schtasks -Args @("/Create","/TN",$TaskName,"/SC","MINUTE","/MO","1","/F","/TR",$tr)
Write-Host ("INSTALLED_TASK_OK: " + $TaskName) -ForegroundColor Green
Invoke-Schtasks -Args @("/Run","/TN",$TaskName)
Write-Host "INSTALL_V5_DONE" -ForegroundColor Green
