param(
  [Parameter(Mandatory=$false)][string]$UiRoot = "C:\ProgramData\EchoOutboxAgent\ui",
  [Parameter(Mandatory=$false)][string]$ReceiptLogPath = "C:\ProgramData\EchoOutboxAgent\receipts\echo_outbox_agent_v1.ndjson",
  [Parameter(Mandatory=$false)][string]$BindHost = "127.0.0.1",
  [Parameter(Mandatory=$false)][int]$BindPort = 8787
)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest
function Die([string]$m){ throw $m }
function EnsureDir([string]$p){ if (-not (Test-Path -LiteralPath $p -PathType Container)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } }
function WriteUtf8NoBomLf([string]$Path,[string]$Text){
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
  if ($errs.Count -gt 0) { Die ("PARSE ERROR: " + $errs[0].Message + " (file: " + $Path + ")") }
}

EnsureDir $UiRoot
$ServerDir = Join-Path $UiRoot "server"
EnsureDir $ServerDir
$IndexPath  = Join-Path $UiRoot "index.html"
$AppJsPath  = Join-Path $UiRoot "app.js"
$SrvPath    = Join-Path $ServerDir "server.py"
$RunUiPath  = Join-Path $UiRoot "run_ui_v1.ps1"
$BundlePath = Join-Path $UiRoot "build_evidence_bundle_v1.ps1"

# Token-safe: avoid PowerShell escaping hell
$rl = $ReceiptLogPath.Replace("\","\\")

# -------------------- server.py --------------------
$pyLines = New-Object System.Collections.Generic.List[string]
[void]$pyLines.Add("import json, os, time")
[void]$pyLines.Add("from http.server import BaseHTTPRequestHandler, HTTPServer")
[void]$pyLines.Add("from urllib.parse import urlparse, parse_qs")
[void]$pyLines.Add("")
[void]$pyLines.Add("RECEIPT_LOG = os.environ.get(""ECHO_RECEIPT_LOG"", r""__RECEIPT_LOG__"")")
[void]$pyLines.Add("BIND_HOST  = os.environ.get(""ECHO_UI_HOST"", r""__BIND_HOST__"")")
[void]$pyLines.Add("BIND_PORT  = int(os.environ.get(""ECHO_UI_PORT"", ""__BIND_PORT__""))")
[void]$pyLines.Add("")
[void]$pyLines.Add("def read_tail(path, max_lines):")
[void]$pyLines.Add("    if not os.path.exists(path):")
[void]$pyLines.Add("        return []")
[void]$pyLines.Add("    with open(path, ""rb"") as f:")
[void]$pyLines.Add("        data = f.read()")
[void]$pyLines.Add("    lines = data.splitlines()")
[void]$pyLines.Add("    if max_lines <= 0:")
[void]$pyLines.Add("        return []")
[void]$pyLines.Add("    tail = lines[-max_lines:] if len(lines) > max_lines else lines")
[void]$pyLines.Add("    out = []")
[void]$pyLines.Add("    for b in tail:")
[void]$pyLines.Add("        if not b:")
[void]$pyLines.Add("            continue")
[void]$pyLines.Add("        try:")
[void]$pyLines.Add("            out.append(json.loads(b.decode(""utf-8"")))")
[void]$pyLines.Add("        except Exception:")
[void]$pyLines.Add("            out.append({""_raw"": b.decode(""utf-8"", errors=""replace"")})")
[void]$pyLines.Add("    return out")
[void]$pyLines.Add("")
[void]$pyLines.Add("def derive_status(events):")
[void]$pyLines.Add("    now = time.time()")
[void]$pyLines.Add("    last_ts = None")
[void]$pyLines.Add("    for ev in reversed(events):")
[void]$pyLines.Add("        ts = ev.get(""ts"") if isinstance(ev, dict) else None")
[void]$pyLines.Add("        if ts:")
[void]$pyLines.Add("            last_ts = ts")
[void]$pyLines.Add("            break")
[void]$pyLines.Add("    sec_since = None")
[void]$pyLines.Add("    if last_ts:")
[void]$pyLines.Add("        try:")
[void]$pyLines.Add("            import datetime")
[void]$pyLines.Add("            s = last_ts.replace(""Z"", ""+00:00"")")
[void]$pyLines.Add("            dt = datetime.datetime.fromisoformat(s)")
[void]$pyLines.Add("            sec_since = max(0.0, now - dt.timestamp())")
[void]$pyLines.Add("        except Exception:")
[void]$pyLines.Add("            sec_since = None")
[void]$pyLines.Add("    streak = 0")
[void]$pyLines.Add("    for ev in reversed(events):")
[void]$pyLines.Add("        st = ev.get(""status"") if isinstance(ev, dict) else None")
[void]$pyLines.Add("        if st and st != ""ok"":")
[void]$pyLines.Add("            streak += 1")
[void]$pyLines.Add("        else:")
[void]$pyLines.Add("            break")
[void]$pyLines.Add("    level = ""err""")
[void]$pyLines.Add("    if sec_since is None:")
[void]$pyLines.Add("        level = ""err""")
[void]$pyLines.Add("    elif sec_since <= 180:")
[void]$pyLines.Add("        level = ""ok""")
[void]$pyLines.Add("    elif sec_since <= 600:")
[void]$pyLines.Add("        level = ""warn""")
[void]$pyLines.Add("    else:")
[void]$pyLines.Add("        level = ""err""")
[void]$pyLines.Add("    return {")
[void]$pyLines.Add("        ""receipt_log"": RECEIPT_LOG,")
[void]$pyLines.Add("        ""last_tick_ts"": last_ts,")
[void]$pyLines.Add("        ""seconds_since_last_tick"": sec_since,")
[void]$pyLines.Add("        ""status"": level,")
[void]$pyLines.Add("        ""error_streak"": streak,")
[void]$pyLines.Add("        ""tail_count"": len(events)")
$pyText = ($pyLines.ToArray() -join "`n")
$pyText = $pyText.Replace("__RECEIPT_LOG__", $rl).Replace("__BIND_HOST__", $BindHost).Replace("__BIND_PORT__", [string]$BindPort)
WriteUtf8NoBomLf -Path $SrvPath -Text ($pyText + "`n")

# -------------------- index.html --------------------
$html = @(
  '<!doctype html>'
  '<html>'
  '<head>'
  '  <meta charset="utf-8"/>'
  '  <meta name="viewport" content="width=device-width,initial-scale=1"/>'
  '  <title>Echo Outbox Agent UI</title>'
  '  <style>'
  '    body{font-family:system-ui,Segoe UI,Arial,sans-serif;margin:16px;}'
  '    .row{display:flex;gap:16px;flex-wrap:wrap;}'
  '    .card{border:1px solid #ddd;border-radius:10px;padding:12px;min-width:260px;}'
  '    .k{color:#555;font-size:12px;text-transform:uppercase;letter-spacing:.04em;}'
  '    .v{font-size:14px;margin-top:2px;word-break:break-word;}'
  '    .ok{color:#0a7;} .warn{color:#c90;} .err{color:#c33;}'
  '    table{border-collapse:collapse;width:100%;}'
  '    th,td{border-bottom:1px solid #eee;padding:6px 4px;text-align:left;font-size:13px;}'
  '    .mono{font-family:ui-monospace,Consolas,monospace;}'
  '  </style>'
  '</head>'
  '<body>'
  '  <h2>Echo Outbox Agent — Proof UI v0</h2>'
  '  <div class="row">'
  '    <div class="card" style="flex:1">'
  '      <div class="k">Status</div>'
  '      <div id="statusLine" class="v mono">loading…</div>'
  '      <div class="k" style="margin-top:10px">Receipt log</div>'
  '      <div id="receiptPath" class="v mono"></div>'
  '    </div>'
  '    <div class="card" style="flex:2">'
  '      <div class="k">Controls</div>'
  '      <div class="v">'
  '        Tail: <input id="tailN" type="number" value="200" min="1" max="5000" style="width:90px"/>'
  '        <button id="refreshBtn">Refresh</button>'
  '      </div>'
  '      <div class="k" style="margin-top:10px">Receipts</div>'
  '      <div class="v"><table><thead><tr><th>ts</th><th>event</th><th>status</th><th>details</th></tr></thead><tbody id="rows"></tbody></table></div>'
  '    </div>'
  '  </div>'
  '  <script src="/app.js"></script>'
  '</body>'
  '</html>'
) -join "`n"
WriteUtf8NoBomLf -Path $IndexPath -Text ($html + "`n")

# -------------------- app.js --------------------
$js = @(
  'async function getJson(u){ const r = await fetch(u,{cache:"no-store"}); if(!r.ok) throw new Error("HTTP "+r.status); return await r.json(); }'
  'function esc(s){ return (s===null||s===undefined) ? "" : String(s); }'
  'function cls(st){ return st==="ok" ? "ok" : (st==="warn" ? "warn" : "err"); }'
  'function fmtSec(x){ if(x===null||x===undefined) return ""; return Math.round(x)+"s"; }'
  'function renderStatus(st){'
  '  const el = document.getElementById("statusLine");'
  '  const rp = document.getElementById("receiptPath");'
  '  rp.textContent = esc(st.receipt_log);'
  '  el.innerHTML = `<span class="${cls(st.status)}">${esc(st.status)}</span>  last=${esc(st.last_tick_ts)}  since=${fmtSec(st.seconds_since_last_tick)}  streak=${esc(st.error_streak)}  tail=${esc(st.tail_count)}`;'
  '}'
  'function renderRows(evs){'
  '  const tb = document.getElementById("rows");'
  '  tb.innerHTML = "";'
  '  for(const ev of evs){'
  '    const tr = document.createElement("tr");'
  '    const ts = esc(ev.ts||"");'
  '    const evn = esc(ev.event||ev._raw||"");'
  '    const st = esc(ev.status||"");'
  '    const details = JSON.stringify(ev);'
  '    tr.innerHTML = `<td class="mono">${ts}</td><td>${evn}</td><td class="${cls(st)}">${st}</td><td class="mono">${esc(details)}</td>`;'
  '    tb.appendChild(tr);'
  '  }'
  '}'
  'async function refresh(){'
  '  const n = parseInt(document.getElementById("tailN").value||"200",10);'
  '  const st = await getJson("/api/status");'
  '  renderStatus(st);'
  '  const evs = await getJson("/api/receipts?tail="+encodeURIComponent(String(n)));'
  '  renderRows(evs);'
  '}'
  'document.getElementById("refreshBtn").addEventListener("click", ()=>{ refresh().catch(e=>alert(e)); });'
  'setInterval(()=>{ refresh().catch(()=>{}); }, 5000);'
  'refresh().catch(e=>alert(e));'
) -join "`n"
WriteUtf8NoBomLf -Path $AppJsPath -Text ($js + "`n")

# -------------------- run_ui_v1.ps1 --------------------
$run = @(
  'param('
  '  [Parameter(Mandatory=$false)][string]$ReceiptLogPath = "C:\ProgramData\EchoOutboxAgent\receipts\echo_outbox_agent_v1.ndjson",'
  '  [Parameter(Mandatory=$false)][string]$Host = "127.0.0.1",'
  '  [Parameter(Mandatory=$false)][int]$Port = 8787'
  ')'
  '$ErrorActionPreference="Stop"'
  'Set-StrictMode -Version Latest'
  'function Die([string]$m){ throw $m }'
  '$Py = (Get-Command python.exe -ErrorAction Stop).Source'
  '$Srv = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "server\server.py"'
  'if (-not (Test-Path -LiteralPath $Srv -PathType Leaf)) { Die ("Missing server.py: " + $Srv) }'
  '$env:ECHO_RECEIPT_LOG = $ReceiptLogPath'
  '$env:ECHO_UI_HOST = $Host'
  '$env:ECHO_UI_PORT = [string]$Port'
  'Write-Host ("[ECHO-UI] starting on http://" + $Host + ":" + $Port) -ForegroundColor Cyan'
  '& $Py $Srv'
  'if ($LASTEXITCODE -ne 0) { throw ("UI server failed exit=" + $LASTEXITCODE) }'
) -join "`n"
WriteUtf8NoBomLf -Path $RunUiPath -Text ($run + "`n")

# -------------------- build_evidence_bundle_v1.ps1 --------------------
$bun = @(
  'param('
  '  [Parameter(Mandatory=$false)][string]$ReceiptLogPath = "C:\ProgramData\EchoOutboxAgent\receipts\echo_outbox_agent_v1.ndjson",'
  '  [Parameter(Mandatory=$false)][string]$OutDir = "C:\ProgramData\EchoOutboxAgent\ui\bundles",'
  '  [Parameter(Mandatory=$false)][int]$Tail = 2000'
  ')'
  '$ErrorActionPreference="Stop"'
  'Set-StrictMode -Version Latest'
  'function Die([string]$m){ throw $m }'
  'function EnsureDir([string]$p){ if (-not (Test-Path -LiteralPath $p -PathType Container)) { New-Item -ItemType Directory -Force -Path $p | Out-Null } }'
  'if (-not (Test-Path -LiteralPath $ReceiptLogPath -PathType Leaf)) { Die ("Missing receipt log: " + $ReceiptLogPath) }'
  'EnsureDir $OutDir'
  '$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")'
  '$Bundle = Join-Path $OutDir ("bundle_" + $stamp)'
  'EnsureDir $Bundle'
  '$ReceiptsOut = Join-Path $Bundle "receipts.ndjson"'
  '$StatusOut   = Join-Path $Bundle "status.json"'
  '$SumsOut     = Join-Path $Bundle "sha256sums.txt"'
  '$lines = Get-Content -LiteralPath $ReceiptLogPath -Tail $Tail'
  '[System.IO.File]::WriteAllLines($ReceiptsOut, $lines, (New-Object System.Text.UTF8Encoding($false)))'
  '$last = $null'
  'for($i=$lines.Count-1; $i -ge 0; $i--){ if($lines[$i]){ $last = $lines[$i]; break } }'
  '$st = @{ generated_utc = (Get-Date).ToUniversalTime().ToString("o"); receipt_log = $ReceiptLogPath; tail = $Tail; last_line = $last } | ConvertTo-Json -Depth 6'
  '[System.IO.File]::WriteAllText($StatusOut, ($st -replace "`r`n","`n" -replace "`r","`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))'
  '$sha = (Get-Command certutil.exe -ErrorAction Stop).Source'
  'function Sha256Hex([string]$p){'
  '  $o = & $sha -hashfile $p SHA256'
  '  if ($LASTEXITCODE -ne 0) { throw ("certutil hash failed exit=" + $LASTEXITCODE) }'
  '  $h = ($o | Select-Object -Skip 1 -First 1).ToString().Replace(" ","").Trim()'
  '  return $h.ToLowerInvariant()'
  '}'
  '$a = @()'
  '$a += (Sha256Hex $ReceiptsOut) + "  receipts.ndjson"'
  '$a += (Sha256Hex $StatusOut)   + "  status.json"'
  '[System.IO.File]::WriteAllLines($SumsOut, $a, (New-Object System.Text.UTF8Encoding($false)))'
  'Write-Host ("BUNDLE_OK: " + $Bundle) -ForegroundColor Green'
  'Write-Host ("  " + $ReceiptsOut) -ForegroundColor DarkGray'
  'Write-Host ("  " + $StatusOut) -ForegroundColor DarkGray'
  'Write-Host ("  " + $SumsOut) -ForegroundColor DarkGray'
) -join "`n"
WriteUtf8NoBomLf -Path $BundlePath -Text ($bun + "`n")

# Parse-gate the emitted PS entrypoints too
ParseGatePs1 $RunUiPath
ParseGatePs1 $BundlePath
Write-Host ("UI_INSTALL_OK: " + $UiRoot) -ForegroundColor Green
Write-Host ("  open: http://" + $BindHost + ":" + $BindPort) -ForegroundColor Cyan
Write-Host ("  run ui: " + $RunUiPath) -ForegroundColor DarkGray
Write-Host ("  build bundle: " + $BundlePath) -ForegroundColor DarkGray
