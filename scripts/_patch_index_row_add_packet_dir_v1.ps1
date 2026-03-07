$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$target = "C:\dev\nfl\scripts\scan_inbox.ps1"
$bak = $target + ".bak_" + (Get-Date).ToString("yyyyMMdd_HHmmss")
Copy-Item -LiteralPath $target -Destination $bak -Force
"BACKUP: $bak"

$src = Get-Content -Raw -LiteralPath $target

# Inject packet_dir + script_version right after schema="nfl.index_row.v1" inside the index row hash/object.
# This assumes your index row is built as a hashtable-like literal containing schema="nfl.index_row.v1".
$src2 = [regex]::Replace(
  $src,
  '(?is)(schema\s*=\s*"nfl\.index_row\.v1"\s*[,;]?\s*)',
  '$1' + "`r`n      packet_dir = $p.FullName`r`n      script_version = `"scan_inbox.ps1::debug_index_v1`"`r`n"
)

Set-Content -LiteralPath $target -Value $src2 -Encoding UTF8
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $target)) | Out-Null
"PARSE_OK"
