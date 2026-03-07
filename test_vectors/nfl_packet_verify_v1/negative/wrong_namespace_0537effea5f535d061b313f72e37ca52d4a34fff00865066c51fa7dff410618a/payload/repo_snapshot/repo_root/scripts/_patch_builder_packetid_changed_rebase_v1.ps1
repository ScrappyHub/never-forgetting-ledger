param([Parameter(Mandatory=$true)][string]$TargetPath)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function ReadUtf8NoBom([string]$p){
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Die ("MISSING_FILE: " + $p) }
  [System.IO.File]::ReadAllText($p, (New-Object System.Text.UTF8Encoding($false)))
}
function WriteUtf8NoBomLf([string]$p, [string]$t){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $t = $t.Replace("`r`n","`n").Replace("`r","`n")
  if (-not $t.EndsWith("`n")) { $t += "`n" }
  [System.IO.File]::WriteAllText($p, $t, $enc)
  if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { Die ("WRITE_FAILED: " + $p) }
}
function ParseGateUtf8NoBomText([string]$text,[string]$label){
  $sb = [ScriptBlock]::Create($text) | Out-Null
}

if (-not (Test-Path -LiteralPath $TargetPath -PathType Leaf)) { Die ("MISSING_TARGET: " + $TargetPath) }
$src = ReadUtf8NoBom $TargetPath

$marker = "PACKET_ID_CHANGED_AFTER_FINALIZE"
$idx = $src.IndexOf($marker, [System.StringComparison]::Ordinal)
if ($idx -lt 0) { Die ("MARKER_NOT_FOUND: " + $marker + " in " + $TargetPath) }

# Backup first
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
$bak = $TargetPath + ".bak_packetidrebase_" + $stamp
[System.IO.File]::Copy($TargetPath, $bak, $true)

# Find enclosing if-block start near marker (best-effort, anchor-based).
$ifStart = $src.LastIndexOf("if", $idx, [System.StringComparison]::OrdinalIgnoreCase)
if ($ifStart -lt 0) { Die ("IF_START_NOT_FOUND near marker in " + $TargetPath) }
$braceOpen = $src.IndexOf("{", $ifStart)
if ($braceOpen -lt 0) { Die ("IF_BRACE_OPEN_NOT_FOUND near marker in " + $TargetPath) }
$braceClose = $src.IndexOf("}", $idx)
if ($braceClose -lt 0) { Die ("IF_BRACE_CLOSE_NOT_FOUND after marker in " + $TargetPath) }
$braceClose = $braceClose + 1

$block = $src.Substring($ifStart, $braceClose - $ifStart)
if ($block.IndexOf($marker, [System.StringComparison]::Ordinal) -lt 0) { Die ("SANITY_FAIL: extracted block does not contain marker") }

# Extract 2 distinct variable names from block (expect PacketId vars).
$vrx = New-Object System.Text.RegularExpressions.Regex("\$[A-Za-z_][A-Za-z0-9_]*")
$ms = @($vrx.Matches($block))
$vars = New-Object System.Collections.Generic.List[string]
foreach ($m in $ms) {
  $v = $m.Value
  if (-not $vars.Contains($v)) { [void]$vars.Add($v) }
}
if ($vars.Count -lt 2) { Die ("VARS_NOT_FOUND: need 2 vars in marker block, found " + $vars.Count) }
$v1 = $vars[0]
$v2 = $vars[1]

# Replacement: warn + rebase to final packet id (do NOT throw).
$repl = @(
  ("if (" + $v1 + " -ne " + $v2 + ") {")
  ("  Write-Host (""WARN_PACKET_ID_CHANGED_AFTER_FINALIZE: "" + " + $v1 + " + "" -> "" + " + $v2 + ") -ForegroundColor Yellow")
  ("  " + $v1 + " = " + $v2)
  "}"
) -join "`n"

$before = $src.Substring(0, $ifStart)
$after  = $src.Substring($braceClose)
$dst = $before + $repl + "`n" + $after
WriteUtf8NoBomLf $TargetPath $dst

# Must parse after patch (in this host).
$check = ReadUtf8NoBom $TargetPath
ParseGateUtf8NoBomText $check $TargetPath
Write-Host ("PATCH_OK_PACKETID_REBASE: " + $TargetPath + "  vars=" + $v1 + "," + $v2) -ForegroundColor Green
Write-Host ("BACKUP: " + $bak) -ForegroundColor DarkGray
