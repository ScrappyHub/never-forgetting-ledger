$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

$target = "C:\dev\nfl\scripts\scan_inbox.ps1"
if (-not (Test-Path -LiteralPath $target)) { throw "Missing: $target" }

$bak = $target + ".bak_" + (Get-Date).ToString("yyyyMMdd_HHmmss")
Copy-Item -LiteralPath $target -Destination $bak -Force
"BACKUP: $bak"

$src = Get-Content -Raw -LiteralPath $target

# 1) producer_instance: remove ALL $r.producer_instance usages without reintroducing the token.
# This is hash-safe and StrictMode-safe.
$src = [regex]::Replace(
  $src,
  '(?im)\$r\.producer_instance\b',
  '(& { param($x) try { [string]$x.producer_instance } catch { "" } } $r)'
)

# 2) declRaw: ensure EVERY Verify-PacketBasic() function initializes $declRaw at top of body.
# We do this by rewriting the function head to include the init immediately after '{'
# only if the next ~200 chars do not already contain a declRaw assignment.
$patternFn = '(?is)(function\s+Verify-PacketBasic\s*\([^\)]*\)\s*\{)(.*?)'
$matches = [regex]::Matches($src, '(?is)function\s+Verify-PacketBasic\s*\([^\)]*\)\s*\{')
if ($matches.Count -lt 1) { throw "No Verify-PacketBasic() found." }

# Insert init after each head if missing near top of that body
$offset = 0
foreach ($m in $matches) {
  $headIndex = $m.Index + $offset
  $headLen   = $m.Length
  $insertAt  = $headIndex + $headLen

  # look ahead a bit to see if declRaw init already exists right after head
  $look = $src.Substring($insertAt, [Math]::Min(220, $src.Length - $insertAt))
  $hasInit = [regex]::IsMatch($look, '(?im)^\s*\$declRaw\s*=')

  if (-not $hasInit) {
    $ins = "`r`n  `$declRaw = `"`"`r`n"
    $src = $src.Insert($insertAt, $ins)
    $offset += $ins.Length
  }
}

Set-Content -LiteralPath $target -Value $src -Encoding UTF8
[ScriptBlock]::Create((Get-Content -Raw -LiteralPath $target)) | Out-Null
"PARSE_OK"
