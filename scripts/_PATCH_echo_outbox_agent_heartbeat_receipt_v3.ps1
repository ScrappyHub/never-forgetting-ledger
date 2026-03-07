param([Parameter(Mandatory=$true)][string]$AgentPath)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw ("ECHO_AGENT_PATCH_V3_FAIL: " + $m) }
function ReadAll([string]$p){ return [System.IO.File]::ReadAllText($p,(New-Object System.Text.UTF8Encoding($false))) }
function WriteAll([string]$p,[string]$t){ $enc=New-Object System.Text.UTF8Encoding($false); $norm=$t.Replace("`r`n","`n").Replace("`r","`n"); if(-not $norm.EndsWith("`n")){ $norm+="`n" }; [System.IO.File]::WriteAllText($p,$norm,$enc) }

$AgentPath = (Resolve-Path -LiteralPath $AgentPath).Path
if(-not (Test-Path -LiteralPath $AgentPath -PathType Leaf)){ Die ("MISSING_AGENT: " + $AgentPath) }
$orig = ReadAll $AgentPath
$txt  = $orig.Replace("`r`n","`n").Replace("`r","`n")

# backup
$stamp=(Get-Date).ToString("yyyyMMdd_HHmmss")
$bak=$AgentPath + ".bak_" + $stamp
WriteAll $bak $orig
Write-Host ("BACKUP_OK: " + $bak) -ForegroundColor DarkYellow

# 1) Ensure param(...) exists and includes ReceiptLogPath
$reParam = '(?s)^\s*param\s*\(\s*(?<body>.*?)\s*\)\s*'
$m = [regex]::Match($txt,$reParam)
if(-not $m.Success){ Die "NO_PARAM_BLOCK_FOUND (expected param(...) at top)" }
$body = $m.Groups["body"].Value
if($body -notmatch 'ReceiptLogPath'){
  $ins = '[Parameter(Mandatory=$true)][string]$ReceiptLogPath'
  $b2 = $body.Trim()
  if([string]::IsNullOrWhiteSpace($b2)){ $b2 = $ins } else { $b2 = $b2.TrimEnd() + "," + "`n" + "  " + $ins }
  $paramNew = "param(`n" + $b2 + "`n)"
  $txt = $txt.Substring(0,$m.Index) + $paramNew + $txt.Substring($m.Index + $m.Length)
  Write-Host "PARAM_OK: added ReceiptLogPath" -ForegroundColor Green
} else {
  Write-Host "PARAM_OK: ReceiptLogPath already present" -ForegroundColor Green
}

# 2) Insert heartbeat receipt block near the success anchor
$anchor = 'ECHO_OUTBOX_AGENT_TICK_OK'
$pos = $txt.IndexOf($anchor)
if($pos -lt 0){ Die ("ANCHOR_NOT_FOUND: " + $anchor) }
$lineStart = $txt.LastIndexOf("`n",$pos)
if($lineStart -lt 0){ $lineStart = 0 } else { $lineStart = $lineStart + 1 }
$lineEnd = $txt.IndexOf("`n",$pos)
if($lineEnd -lt 0){ $lineEnd = $txt.Length }
$anchorLine = $txt.Substring($lineStart, $lineEnd-$lineStart)
$indent = ([regex]::Match($anchorLine,'^\s*').Value)

if($txt -match '"event"\s*:\s*"heartbeat"' ){
  Write-Host "NOOP: heartbeat receipt already present" -ForegroundColor Yellow
} else {
  $I = New-Object System.Collections.Generic.List[string]
  [void]$I.Add($indent + "# heartbeat receipt (append-only ndjson)")
  [void]$I.Add($indent + '$ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")')
  [void]$I.Add($indent + '$rec = @{ ts=$ts; agent="echo_outbox_agent.v1"; event="heartbeat"; status="ok"; config_path=$ConfigPath; receipt_path=$ReceiptLogPath } | ConvertTo-Json -Compress')
  [void]$I.Add($indent + '$rec = $rec.Replace("`r`n","`n").Replace("`r","`n")')
  [void]$I.Add($indent + 'if(-not $rec.EndsWith("`n")){ $rec += "`n" }')
  [void]$I.Add($indent + '$rdir = Split-Path -Parent $ReceiptLogPath')
  [void]$I.Add($indent + 'if($rdir -and -not (Test-Path -LiteralPath $rdir -PathType Container)){ New-Item -ItemType Directory -Force -Path $rdir | Out-Null }')
  [void]$I.Add($indent + '$enc = New-Object System.Text.UTF8Encoding($false)')
  [void]$I.Add($indent + '[System.IO.File]::AppendAllText($ReceiptLogPath,$rec,$enc)' )
  $insert = (@($I.ToArray()) -join "`n") + "`n"
  $txt = $txt.Substring(0,$lineStart) + $insert + $txt.Substring($lineStart)
  Write-Host "INSERT_OK: heartbeat receipt inserted" -ForegroundColor Green
}

# write
WriteAll $AgentPath $txt
Write-Host ("WRITE_OK: " + $AgentPath) -ForegroundColor Green
Write-Host "PATCH_OK: heartbeat receipt (v3) applied" -ForegroundColor Green
