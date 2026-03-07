$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$target = "C:\dev\nfl\scripts\scan_inbox.ps1"
if (-not (Test-Path -LiteralPath $target)) { throw "Missing: $target" }

$bak = $target + ".bak_" + (Get-Date).ToString("yyyyMMdd_HHmmss")
Copy-Item -LiteralPath $target -Destination $bak -Force
"BACKUP: $bak"

$src = Get-Content -Raw -LiteralPath $target

# Replace any bare $declRaw token with a strictmode-safe expression.
# NOTE: This is conservative and only targets the exact token.
$src2 = [regex]::Replace(
  $src,
  '(?im)\$declRaw\b',
  '$(if (Get-Variable -Name declRaw -Scope 0 -ErrorAction SilentlyContinue) { $declRaw } else { "" })'
)

Set-Content -LiteralPath $target -Value $src2 -Encoding UTF8
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $target)) | Out-Null

"PARSE_OK"
