$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$target = "C:\dev\nfl\scripts\scan_inbox.ps1"
if (-not (Test-Path -LiteralPath $target)) { throw "Missing: $target" }

$bak = $target + ".bak_" + (Get-Date).ToString("yyyyMMdd_HHmmss")
Copy-Item -LiteralPath $target -Destination $bak -Force
"BACKUP: $bak"

$src = Get-Content -Raw -LiteralPath $target

# 1) Kill any SeenDirRoot usage (undefined variable leak)
$src = [regex]::Replace($src, '(?im)\$SeenDirRoot\b', '$SeenDir')

# 2) Make producer_instance safe in index row construction:
# Replace "producer_instance = $r.producer_instance" with safe precompute + assignment.
$src = [regex]::Replace(
  $src,
  '(?im)^\s*producer_instance\s*=\s*\$r\.producer_instance\s*$',
  '      $prodInst = ""' + "`r`n" +
  '      try { $prodInst = [string]$r.producer_instance } catch { $prodInst = "" }' + "`r`n" +
  '      producer_instance = $prodInst'
)

# 3) Ensure Verify-PacketBasic initializes $declRaw early (so error strings never reference unset var).
# Insert '$declRaw = ""' at the top of Verify-PacketBasic body if not present.
$fnHead = [regex]::Match($src, '(?is)function\s+Verify-PacketBasic\s*\([^\)]*\)\s*\{')
if (-not $fnHead.Success) { throw "Could not find Verify-PacketBasic head." }

# If declRaw already exists somewhere in the function, we still want a safe init at top.
$insertAt = $fnHead.Index + $fnHead.Length
$src = $src.Insert($insertAt, "`r`n  `$declRaw = `"`"`r`n")

Set-Content -LiteralPath $target -Value $src -Encoding UTF8
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $target)) | Out-Null
"PARSE_OK"
