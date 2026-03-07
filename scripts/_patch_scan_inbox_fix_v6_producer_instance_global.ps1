$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$target = "C:\dev\nfl\scripts\scan_inbox.ps1"
if (-not (Test-Path -LiteralPath $target)) { throw "Missing: $target" }

$bak = $target + ".bak_" + (Get-Date).ToString("yyyyMMdd_HHmmss")
Copy-Item -LiteralPath $target -Destination $bak -Force
"BACKUP: $bak"

$src = Get-Content -Raw -LiteralPath $target

# Replace *any* $r.producer_instance usage with a hash-safe expression
# (works inside hashtables and outside; never throws)
$src2 = [regex]::Replace(
  $src,
  '(?im)\$r\.producer_instance\b',
  '(& { try { [string]$r.producer_instance } catch { "" } })'
)

Set-Content -LiteralPath $target -Value $src2 -Encoding UTF8
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $target)) | Out-Null

"PARSE_OK"
