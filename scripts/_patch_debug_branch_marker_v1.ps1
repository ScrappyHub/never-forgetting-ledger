$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$target = "C:\dev\nfl\scripts\scan_inbox.ps1"
if (-not (Test-Path -LiteralPath $target)) { throw "Missing: $target" }

$bak = $target + ".bak_" + (Get-Date).ToString("yyyyMMdd_HHmmss")
Copy-Item -LiteralPath $target -Destination $bak -Force
"BACKUP: $bak"

$src = Get-Content -Raw -LiteralPath $target

# Mark ALL index rows (both schema styles) with debug fields.
# IMPORTANT: use single quotes so $p is not expanded during patch execution.
$src2 = [regex]::Replace(
  $src,
  '(?im)(^\s*schema\s*=\s*"nfl\.index_row\.v1"\s*$)',
  '$1' + "`r`n      debug_packet_dir = $p.FullName`r`n      debug_index_block = `"block_hashtable_schema_eq`"`r`n"
)

$src3 = [regex]::Replace(
  $src2,
  '(?im)(^\s*schema\s*=\s*"nfl\.index_row\.v1"\s*$)',
  '$1'
)

$src4 = [regex]::Replace(
  $src3,
  '(?im)(^\s*schema\s*=\s*"nfl\.index_row\.v1"\s*$)',
  '$1'
)

# Also tag the compact schema="..." forms
$src5 = [regex]::Replace(
  $src4,
  '(?im)(^\s*schema\s*=\s*"nfl\.index_row\.v1"\s*$)',
  '$1'
)

$src6 = [regex]::Replace(
  $src5,
  '(?im)(^\s*schema\s*=\s*"nfl\.index_row\.v1"\s*$)',
  '$1'
)

# Tag the compact inline schema="nfl.index_row.v1"
$src7 = [regex]::Replace(
  $src6,
  '(?im)(schema\s*=\s*"nfl\.index_row\.v1"\s*)',
  '$1' + "`r`n      debug_packet_dir = $p.FullName`r`n      debug_index_block = `"block_inline_schema_eq`"`r`n"
)

$src8 = [regex]::Replace(
  $src7,
  '(?im)(schema\s*=\s*"nfl\.index_row\.v1"\s*)',
  '$1'
)

# Also handle schema="nfl.index_row.v1" (no spaces)
$src9 = [regex]::Replace(
  $src8,
  '(?im)(schema\s*=\s*"nfl\.index_row\.v1"\s*)',
  '$1'
)

$src10 = [regex]::Replace(
  $src9,
  '(?im)(schema\s*=\s*"nfl\.index_row\.v1"\s*)',
  '$1'
)

# Now specifically tag the *two* packet_id assignment lines so we can see which block emitted it.
$src11 = [regex]::Replace(
  $src10,
  '(?im)^\s*packet_id\s*=\s*\$r\.packet_id\s*$',
  '      packet_id = $r.packet_id' + "`r`n      debug_packet_id_source = `"r.packet_id`""
)

Set-Content -LiteralPath $target -Value $src11 -Encoding UTF8
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $target)) | Out-Null
"PARSE_OK"
