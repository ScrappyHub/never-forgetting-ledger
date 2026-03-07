param([Parameter(Mandatory=$true)][string]$AgentPath)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function Write-Utf8NoBomLf([string]$Path,[string]$Text){
  $enc = New-Object System.Text.UTF8Encoding($false)
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $norm = ($Text -replace "`r`n","`n" -replace "`r","`n")
  if (-not $norm.EndsWith("`n")) { $norm += "`n" }
  [System.IO.File]::WriteAllText($Path,$norm,$enc)
}
function ParseGatePs1([string]$Path){
  $tk=$null; $er=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($Path,[ref]$tk,[ref]$er)
  $errs = @(@($er))
  if ($errs.Count -gt 0) { throw ("PARSE ERROR: " + $errs[0].Message + " (file: " + $Path + ")") }
}

if (-not (Test-Path -LiteralPath $AgentPath -PathType Leaf)) { Die ("Missing agent: " + $AgentPath) }
$raw = Get-Content -Raw -LiteralPath $AgentPath -Encoding UTF8
if ($raw -match "ECHO_OUTBOX_AGENT_HEARTBEAT_RECEIPT_V1") { Write-Host "SKIP: heartbeat already present" -ForegroundColor Yellow; return }

# Insert BEFORE tick-ok line so it runs even when no packets are found.
$pat = "(?m)^[\t ]*Write-Host\s+`"ECHO_OUTBOX_AGENT_TICK_OK`""
$m = [regex]::Match($raw, $pat)
if (-not $m.Success) { Die "PATCH_V1: anchor not found: Write-Host \"ECHO_OUTBOX_AGENT_TICK_OK\"" }
$pos = $m.Index

$ins = New-Object System.Collections.Generic.List[string]
[void]$ins.Add("")
[void]$ins.Add("# ECHO_OUTBOX_AGENT_HEARTBEAT_RECEIPT_V1")
[void]$ins.Add("try {")
[void]$ins.Add("  if ($PSBoundParameters.ContainsKey('ReceiptLogPath') -and $ReceiptLogPath) {")
[void]$ins.Add("    $rdir = Split-Path -Parent $ReceiptLogPath")
[void]$ins.Add("    if ($rdir -and -not (Test-Path -LiteralPath $rdir -PathType Container)) { New-Item -ItemType Directory -Force -Path $rdir | Out-Null }")
[void]$ins.Add("    $j = ""{""""ts"""":"""""" + (NowIso) + """""",""""agent"""":""""echo_outbox_agent.v1"""",""""event"""":""""heartbeat"""",""""status"""":""""ok"""",""""config_path"""":"""""" + (JsonEscape $ConfigPath) + """"""}""")
[void]$ins.Add("    Append-Ndjson -Path $ReceiptLogPath -JsonLine $j")
[void]$ins.Add("  }")
[void]$ins.Add("} catch { }")
[void]$ins.Add("")
$insText = ($ins.ToArray() -join "`n")
$new = $raw.Substring(0,$pos) + $insText + $raw.Substring($pos)
Write-Utf8NoBomLf -Path $AgentPath -Text $new
ParseGatePs1 $AgentPath
Write-Host ("PATCH_OK: heartbeat receipt inserted into " + $AgentPath) -ForegroundColor Green
