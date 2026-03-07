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

$raw = Get-Content -Raw -LiteralPath $AgentPath -Encoding UTF8
if ($raw -match "ECHO_OUTBOX_AGENT_RECEIPT_BOOTSTRAP_V2") { Write-Host "SKIP: already patched" -ForegroundColor Yellow; exit 0 }

# Insert after Set-StrictMode line if present; else insert after param(...) if present; else at top.
$pos = -1
$m1 = [regex]::Match($raw, "(?m)^[\t ]*Set-StrictMode[^\r\n]*\r?$")
if ($m1.Success) { $pos = $m1.Index + $m1.Length }
if ($pos -lt 0) {
  $m2 = [regex]::Match($raw, "(?s)\A\s*param\s*\(.*?\)\s*")
  if ($m2.Success) { $pos = $m2.Index + $m2.Length } else { $pos = 0 }
}

# Self-contained ndjson append (no dependency on agent helpers)
$boot = @(
  ""
  "# ECHO_OUTBOX_AGENT_RECEIPT_BOOTSTRAP_V2"
  "function _IsoNow(){ (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffffffZ') }"
  "function _JsonEsc([string]$s){ if($null -eq $s){return ''}; $t=$s.Replace('\','\\').Replace('""','\"').Replace(""`r"",""\r"").Replace(""`n"",""\n""); return $t }"
  "function _AppendNd([string]$path,[string]$line){"
  "  $dir = Split-Path -Parent $path"
  "  if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }"
  "  $enc = New-Object System.Text.UTF8Encoding($false)"
  "  $norm = ($line -replace ""`r`n"",""`n"" -replace ""`r"",""`n"")"
  "  if (-not $norm.EndsWith(""`n"")) { $norm += ""`n"" }"
  "  [System.IO.File]::AppendAllText($path,$norm,$enc)"
  "}"
  "try {"
  "  if ($PSBoundParameters.ContainsKey('ReceiptLogPath') -and $ReceiptLogPath) {"
  "    $j = '{""ts"":""' + (_IsoNow) + '"",""agent"":""echo_outbox_agent.v1"",""event"":""start"",""receipt_path"":""' + (_JsonEsc $ReceiptLogPath) + '"",""config_path"":""' + (_JsonEsc $ConfigPath) + '""}'"
  "    _AppendNd -path $ReceiptLogPath -line $j"
  "  }"
  "} catch { }"
  ""
) -join "`n"

$new = $raw.Substring(0,$pos) + $boot + $raw.Substring($pos)
Write-Utf8NoBomLf -Path $AgentPath -Text $new
ParseGatePs1 $AgentPath
Write-Host ("PATCH_OK: receipts bootstrap inserted into " + $AgentPath) -ForegroundColor Green
