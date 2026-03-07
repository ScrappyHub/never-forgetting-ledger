$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$target = "C:\dev\nfl\scripts\scan_inbox.ps1"
if (-not (Test-Path -LiteralPath $target)) { throw "Missing: $target" }

$bak = $target + ".bak_" + (Get-Date).ToString("yyyyMMdd_HHmmss")
Copy-Item -LiteralPath $target -Destination $bak -Force
"BACKUP: $bak"

$src = Get-Content -Raw -LiteralPath $target

# A) Kill any SeenDirRoot usage (undefined var leak)
$src = [regex]::Replace($src, '(?im)\$SeenDirRoot\b', '$SeenDir')

# B) Make producer_instance safe WITHOUT injecting statements.
# Replace:
#   producer_instance = $r.producer_instance
# With:
#   producer_instance = (& { try { [string]$r.producer_instance } catch { "" } })
$src = [regex]::Replace(
  $src,
  '(?im)^\s*producer_instance\s*=\s*\$r\.producer_instance\s*$',
  '      producer_instance = (& { try { [string]$r.producer_instance } catch { "" } })'
)

# C) Ensure Verify-PacketBasic initializes $declRaw early (outside hash literals)
$fnHead = [regex]::Match($src, '(?is)function\s+Verify-PacketBasic\s*\([^\)]*\)\s*\{')
if (-not $fnHead.Success) { throw "Could not find Verify-PacketBasic head." }

$insertAt = $fnHead.Index + $fnHead.Length

# Only insert once (avoid stacking if you re-run patch)
$already = [regex]::IsMatch($src.Substring($insertAt, [Math]::Min(200, $src.Length - $insertAt)), '(?im)^\s*\$declRaw\s*=')
if (-not $already) {
  $src = $src.Insert($insertAt, "`r`n  `$declRaw = `"`"`r`n")
}

Set-Content -LiteralPath $target -Value $src -Encoding UTF8
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $target)) | Out-Null
"PARSE_OK"
