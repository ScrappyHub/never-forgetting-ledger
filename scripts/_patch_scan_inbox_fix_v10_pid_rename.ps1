$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$target = "C:\dev\nfl\scripts\scan_inbox.ps1"
if (-not (Test-Path -LiteralPath $target)) { throw "Missing: $target" }

$bak = $target + ".bak_" + (Get-Date).ToString("yyyyMMdd_HHmmss")
Copy-Item -LiteralPath $target -Destination $bak -Force
"BACKUP: $bak"

$src = Get-Content -Raw -LiteralPath $target

# Replace variable token $PID with $ProcId (PowerShell automatic variable PID is read-only).
# Token-based: $PID followed by non-identifier char or end.
$src2 = [regex]::Replace($src, '(?i)\$PID(?![A-Za-z0-9_])', '$ProcId')

Set-Content -LiteralPath $target -Value $src2 -Encoding UTF8
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $target)) | Out-Null
"PARSE_OK"
