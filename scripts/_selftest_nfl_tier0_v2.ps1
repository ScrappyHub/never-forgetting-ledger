param([Parameter(Mandatory=$true)][string]$RepoRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$Target = Join-Path (Join-Path $RepoRoot "scripts") "_selftest_nfl_tier0_locked_v1.ps1"
if(-not (Test-Path -LiteralPath $Target -PathType Leaf)){ throw ("MISSING_LOCKED_RUNNER: " + $Target) }
& (Get-Command powershell.exe -ErrorAction Stop).Source -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Target -RepoRoot $RepoRoot
exit $LASTEXITCODE
