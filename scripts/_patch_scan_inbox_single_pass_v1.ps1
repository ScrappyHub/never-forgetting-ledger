$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$target = "C:\dev\nfl\scripts\scan_inbox.ps1"
if (-not (Test-Path -LiteralPath $target)) { throw "Missing: $target" }

$bak = $target + ".bak_" + (Get-Date).ToString("yyyyMMdd_HHmmss")
Copy-Item -LiteralPath $target -Destination $bak -Force
"BACKUP: $bak"

$src = Get-Content -Raw -LiteralPath $target

# After the FIRST occurrence of the final scan status line, exit the script to prevent the duplicate second pass.
# This is deliberately minimal and reversible.
$pattern = '(?m)^\s*"NFL:\s*scanned\s*\$\(\$packets\.Count\)\s*packet\(s\)\.\s*Index\s*appended:\s*\$Index"\s*$'
if ($src -notmatch $pattern) { throw "Could not find scan status line to anchor single-pass exit." }

$src2 = [regex]::Replace(
  $src,
  $pattern,
  '$0' + "`r`nreturn`r`n",
  1
)

Set-Content -LiteralPath $target -Value $src2 -Encoding UTF8
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $target)) | Out-Null
"PARSE_OK"
