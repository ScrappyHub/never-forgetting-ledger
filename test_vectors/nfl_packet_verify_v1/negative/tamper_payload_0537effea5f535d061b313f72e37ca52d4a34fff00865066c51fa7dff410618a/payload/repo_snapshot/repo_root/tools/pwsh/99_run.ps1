#requires -Version 7.0
[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$ScriptRelPath,
  [Parameter()][string[]]$Args = @(),
  [Parameter()][switch]$VerboseOn
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..\..")).Path
$pwsh7    = (Get-Command pwsh).Source

$scriptPath = (Resolve-Path -LiteralPath (Join-Path $repoRoot $ScriptRelPath)).Path
$tmpDir     = Join-Path $repoRoot "tools\tmp"
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$base  = [IO.Path]::GetFileNameWithoutExtension($scriptPath)
$log   = Join-Path $tmpDir ("{0}_{1}.log" -f $base, $stamp)

Write-Host ("RUNNER: pwsh={0}" -f $pwsh7)
Write-Host ("RUNNER: script={0}" -f $scriptPath)
Write-Host ("RUNNER: log={0}" -f $log)

# Build an argument array for pwsh itself (NOT a string)
$pwshArgs = @(
  "-NoProfile",
  "-ExecutionPolicy","Bypass",
  "-File", $scriptPath
)

if ($VerboseOn) { $pwshArgs += "-Verbose" }
if ($Args -and $Args.Count -gt 0) { $pwshArgs += $Args }

# Transcript happens in the child process so it always captures script output
$env:GI_PPI_TRANSCRIPT_PATH = $log

& $pwsh7 @pwshArgs
exit $LASTEXITCODE
