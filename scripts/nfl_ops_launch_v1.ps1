param(
  [string]$RepoRoot = "C:\dev\nfl",
  [string]$ExplorerRoot = "C:\dev\nfl-explorer\nfl-explorer",
  [string]$ApiPrefix = "http://127.0.0.1:8086/"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$PSExe = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$ApiScript = Join-Path $RepoRoot "scripts\nfl_api_v1.ps1"

if(-not (Test-Path $ApiScript)){ throw "MISSING_API_SCRIPT:$ApiScript" }
if(-not (Test-Path $ExplorerRoot)){ throw "MISSING_EXPLORER_ROOT:$ExplorerRoot" }

Start-Process -WindowStyle Hidden -FilePath $PSExe -ArgumentList @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", "`"$ApiScript`"",
  "-RepoRoot", "`"$RepoRoot`"",
  "-Prefix", "`"$ApiPrefix`""
)

Start-Sleep -Seconds 2

Start-Process -WindowStyle Hidden -FilePath "cmd.exe" -ArgumentList @(
  "/c",
  "cd /d `"$ExplorerRoot`" && npm run dev"
)

Start-Sleep -Seconds 2

Start-Process "http://localhost:5173/"

Write-Output "NFL_OPS_LAUNCH_OK"
Write-Output ("API=" + $ApiPrefix)
Write-Output "UI=http://localhost:5173/"