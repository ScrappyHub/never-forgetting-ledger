param(
  [Parameter(Mandatory=$false)][string]$UiRoot = "C:\ProgramData\EchoOutboxAgent\ui"
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

$SrvPath  = Join-Path (Join-Path $UiRoot "server") "server.py"
$Index    = Join-Path $UiRoot "index.html"
$AppJs    = Join-Path $UiRoot "app.js"
$BundlePs = Join-Path $UiRoot "build_evidence_bundle_v1.ps1"
if (-not (Test-Path -LiteralPath $SrvPath -PathType Leaf))  { Die ("Missing: " + $SrvPath) }
if (-not (Test-Path -LiteralPath $Index  -PathType Leaf))  { Die ("Missing: " + $Index) }
if (-not (Test-Path -LiteralPath $AppJs  -PathType Leaf))  { Die ("Missing: " + $AppJs) }
if (-not (Test-Path -LiteralPath $BundlePs -PathType Leaf)) { Die ("Missing: " + $BundlePs) }

# Backups
$bakDir = Join-Path $UiRoot "_bak"
EnsureDir $bakDir
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd_HHmmss")
$bakSrv = Join-Path $bakDir ("server.py." + $stamp + ".pre_bundle_api.bak")
$bakIdx = Join-Path $bakDir ("index.html." + $stamp + ".pre_bundle_api.bak")
$bakJs  = Join-Path $bakDir ("app.js." + $stamp + ".pre_bundle_api.bak")
Copy-Item -LiteralPath $SrvPath -Destination $bakSrv -Force
Copy-Item -LiteralPath $Index  -Destination $bakIdx -Force
Copy-Item -LiteralPath $AppJs  -Destination $bakJs  -Force
Write-Host ("BACKUP_OK: " + $bakDir) -ForegroundColor DarkGray

# -------------------- Patch server.py --------------------
$py = Get-Content -Raw -LiteralPath $SrvPath -Encoding UTF8

# Idempotency: if bundle endpoints already present, we still rewrite deterministically by replacing an anchor block.
$anchor = "# --- BUNDLE_API_V1 ---"
$has = ($py -like ("*" + $anchor + "*"))

if ($has) {
  # Remove existing bundle api block (between anchors)
  $py = [System.Text.RegularExpressions.Regex]::Replace($py, "(?s)# --- BUNDLE_API_V1 ---.*?# --- END_BUNDLE_API_V1 ---\s*", "", "IgnoreCase")
}

# Insert bundle API helpers just after imports (after the first blank line following imports)
$m = [System.Text.RegularExpressions.Regex]::Match($py, "(?s)\A(.*?\n)\n")
if (-not $m.Success) { Die "PATCH_FAIL: could not find import header blank line in server.py" }
$hdr = $m.Groups[1].Value + "`n"
$rest = $py.Substring($hdr.Length)

$bundleBlock = @(
  "# --- BUNDLE_API_V1 ---",
  "import subprocess",
  "",
  "def _ui_root_dir():",
  "    return os.path.abspath(os.path.join(os.path.dirname(__file__), "".."" ))",
  "",
  "def _bundle_ps_path():",
  "    return os.path.join(_ui_root_dir(), ""build_evidence_bundle_v1.ps1"")",
  "",
  "def _bundles_dir():",
  "    return os.path.join(_ui_root_dir(), ""bundles"")",
  "",
  "def _latest_bundle_dir():",
  "    d = _bundles_dir()",
  "    if not os.path.isdir(d):",
  "        return None",
  "    names = [n for n in os.listdir(d) if n.startswith(""bundle_"")]",
  "    if not names:",
  "        return None",
  "    names.sort()",
  "    return os.path.join(d, names[-1])",
  "",
  "def _bundle_info(bundle_dir):",
  "    if not bundle_dir:",
  "        return None",
  "    out = {""bundle_dir"": bundle_dir}",
  "    want = [(""receipts.ndjson"",""application/x-ndjson""), (""status.json"",""application/json""), (""sha256sums.txt"",""text/plain"")]",
  "    files = []",
  "    for (fn, ct) in want:",
  "        p = os.path.join(bundle_dir, fn)",
  "        files.append({""name"": fn, ""path"": p, ""exists"": os.path.exists(p), ""content_type"": ct, ""url"": ""/api/bundle/file?f="" + fn})",
  "    out[""files""] = files",
  "    return out",
  "",
  "def _run_bundle_build(tail):",
  "    ps = _bundle_ps_path()",
  "    if not os.path.exists(ps):",
  "        return {""ok"": False, ""error"": ""missing build script"", ""path"": ps}",
  "    exe = ""powershell.exe""",
  "    args = [exe, ""-NoProfile"", ""-NonInteractive"", ""-ExecutionPolicy"", ""Bypass"", ""-File"", ps, ""-Tail"", str(tail)]",
  "    try:",
  "        r = subprocess.run(args, capture_output=True, text=True)",
  "        return {""ok"": (r.returncode==0), ""exit_code"": r.returncode, ""stdout"": r.stdout, ""stderr"": r.stderr}",
  "    except Exception as e:",
  "        return {""ok"": False, ""error"": str(e)}",
  "",
  "# --- END_BUNDLE_API_V1 ---",
) -join "`n"

$py2 = $hdr + $bundleBlock + "`n" + $rest

# Now patch request handler: insert endpoints near top of do_GET (right after u = urlparse(self.path))
$needle = "        u = urlparse(self.path)"
$pos = $py2.IndexOf($needle)
if ($pos -lt 0) { Die "PATCH_FAIL: could not find handler line: u = urlparse(self.path)" }

$insert2 = @(
  "        # bundle api",
  "        if u.path == ""/api/bundle/latest"":",
  "            bdir = _latest_bundle_dir()",
  "            info = _bundle_info(bdir) if bdir else {""bundle_dir"": None, ""files"": []}",
  "            self._send(200, ""application/json; charset=utf-8"", json.dumps(info))",
  "            return",
  "        if u.path == ""/api/bundle/build"":",
  "            qs = parse_qs(u.query)",
  "            tail = 2000",
  "            try:",
  "                if ""tail"" in qs: tail = int(qs[""tail""][0])",
  "            except Exception:",
  "                tail = 2000",
  "            tail = max(1, min(5000, tail))",
  "            r = _run_bundle_build(tail)",
  "            # after build, report latest",
  "            bdir = _latest_bundle_dir()",
  "            info = _bundle_info(bdir) if bdir else {""bundle_dir"": None, ""files"": []}",
  "            out = {""build"": r, ""latest"": info}",
  "            self._send(200, ""application/json; charset=utf-8"", json.dumps(out))",
  "            return",
  "        if u.path == ""/api/bundle/file"":",
  "            qs = parse_qs(u.query)",
  "            fn = qs.get(""f"", [""""])[0]",
  "            allow = set([""receipts.ndjson"", ""status.json"", ""sha256sums.txt""])",
  "            if fn not in allow:",
  "                self._send(400, ""application/json; charset=utf-8"", json.dumps({""error"": ""bad file""}))",
  "                return",
  "            bdir = _latest_bundle_dir()",
  "            if not bdir:",
  "                self._send(404, ""application/json; charset=utf-8"", json.dumps({""error"": ""no bundles""}))",
  "                return",
  "            p = os.path.join(bdir, fn)",
  "            if not os.path.exists(p):",
  "                self._send(404, ""application/json; charset=utf-8"", json.dumps({""error"": ""missing"", ""path"": p}))",
  "                return",
  "            # content types",
  "            ct = ""application/octet-stream""",
  "            if fn.endswith("".json""): ct = ""application/json; charset=utf-8""",
  "            elif fn.endswith("".ndjson""): ct = ""application/x-ndjson; charset=utf-8""",
  "            elif fn.endswith("".txt""): ct = ""text/plain; charset=utf-8""",
  "            with open(p, ""rb"") as f:",
  "                self._send(200, ct, f.read())",
  "            return",
) -join "`n"

# Insert immediately after the urlparse line
$replNeedle = $needle + "`n" + $insert2
$py3 = $py2.Replace($needle, $replNeedle)
WriteUtf8NoBomLf -Path $SrvPath -Text ($py3 + "`n")
Write-Host ("PATCH_OK: server.py bundle API installed") -ForegroundColor Green

# Proof: python compile-check (no f-string quoting hazards)
$PyExe = (Get-Command python.exe -ErrorAction Stop).Source
$SrvEsc = $SrvPath.Replace("\","\\")
$cmd = "import py_compile; py_compile.compile(r""" + $SrvEsc + """, doraise=True); print(""PY_COMPILE_OK"")"
& $PyExe -c $cmd
if ($LASTEXITCODE -ne 0) { Die ("python compile-check failed exit=" + $LASTEXITCODE) }
Write-Host "PY_COMPILE_OK" -ForegroundColor Green

# -------------------- Patch index.html --------------------
$html = Get-Content -Raw -LiteralPath $Index -Encoding UTF8
if ($html -notmatch "id=""refreshBtn""") { Die "PATCH_FAIL: index.html missing refreshBtn anchor" }
if ($html -notmatch "id=""tailN""") { Die "PATCH_FAIL: index.html missing tailN anchor" }

# Add build button + latest bundle panel (idempotent)
if ($html -notmatch "id=""buildBtn""") {
  $html2 = $html.Replace(
    '        <button id="refreshBtn">Refresh</button>',
    '        <button id="refreshBtn">Refresh</button> <button id="buildBtn">Build Bundle</button>'
  )
} else { $html2 = $html }

if ($html2 -notmatch "id=""bundleLine""") {
  $needle2 = '      <div class="k" style="margin-top:10px">Receipts</div>'
  $ins = @(
    '      <div class="k" style="margin-top:10px">Latest bundle</div>',
    '      <div id="bundleLine" class="v mono">loading…</div>',
    '      <div id="bundleLinks" class="v mono"></div>',
    $needle2
  ) -join "`n"
  $html2 = $html2.Replace($needle2, $ins)
}

WriteUtf8NoBomLf -Path $Index -Text ($html2 + "`n")
Write-Host "PATCH_OK: index.html bundle button/panel installed" -ForegroundColor Green

# -------------------- Patch app.js --------------------
$js = Get-Content -Raw -LiteralPath $AppJs -Encoding UTF8

# Replace refresh() to also fetch latest bundle and wire build button. Idempotent: detect marker.
$marker = "/* BUNDLE_UI_V1 */"
if ($js -notmatch [regex]::Escape($marker)) {
  $add = @(
    $marker,
    'async function getLatestBundle(){ return await getJson("/api/bundle/latest"); }',
    'async function buildBundle(tail){ return await getJson("/api/bundle/build?tail="+encodeURIComponent(String(tail))); }',
    'function renderBundle(info){',
    '  const line = document.getElementById("bundleLine");',
    '  const links = document.getElementById("bundleLinks");',
    '  if(!line || !links) return;',
    '  if(!info || !info.bundle_dir){ line.textContent = "none"; links.textContent=""; return; }',
    '  line.textContent = info.bundle_dir;',
    '  const fs = (info.files||[]).filter(x=>x && x.exists);',
    '  let html="";',
    '  for(const f of fs){ html += `<div><a href="${f.url}" target="_blank" rel="noreferrer">${esc(f.name)}</a></div>`; }',
    '  links.innerHTML = html || "<div>(no files)</div>";',
    '}',
  ) -join "`n"

  # Insert helper block after esc()/cls()/fmtSec() region: place after fmtSec definition line
  $re = [System.Text.RegularExpressions.Regex]::Match($js, "(?m)^function fmtSec\\(x\\)\\{[^\\n]*\\}\\s*$")
  if (-not $re.Success) { Die "PATCH_FAIL: app.js missing fmtSec() anchor" }
  $pos2 = $re.Index + $re.Length
  $js = $js.Substring(0,$pos2) + "`n" + $add + "`n" + $js.Substring($pos2)
}

# Patch refresh() to call latest bundle each time
if ($js -notmatch "getLatestBundle") { Die "PATCH_FAIL: expected getLatestBundle helper missing after insertion" }

# Add bundle fetch inside refresh(): after renderRows(evs);
if ($js -notmatch "renderRows\\(evs\\);\\s*\\n\\}") {
  # nothing
}
$js2 = $js
$js2 = [System.Text.RegularExpressions.Regex]::Replace($js2, "(?s)renderRows\\(evs\\);\\s*\\n\\}", "renderRows(evs);`n  const bi = await getLatestBundle();`n  renderBundle(bi);`n}", 1)

# Wire build button once
if ($js2 -notmatch "buildBtn") {
  $needle3 = 'document.getElementById("refreshBtn").addEventListener("click", ()=>{ refresh().catch(e=>alert(e)); });'
  if ($js2 -notlike ("*" + $needle3 + "*")) { Die "PATCH_FAIL: app.js missing refreshBtn wiring anchor" }
  $ins3 = @(
    $needle3,
    'const bb = document.getElementById("buildBtn");',
    'if(bb){ bb.addEventListener("click", ()=>{ const n = parseInt(document.getElementById("tailN").value||"2000",10); buildBundle(n).then(()=>refresh()).catch(e=>alert(e)); }); }'
  ) -join "`n"
  $js2 = $js2.Replace($needle3, $ins3)
}

WriteUtf8NoBomLf -Path $AppJs -Text ($js2 + "`n")
Write-Host "PATCH_OK: app.js bundle button + latest panel wiring installed" -ForegroundColor Green

# Parse-gate run_ui and build script remain; only patching assets + server
Write-Host ("DONE_OK: bundle endpoints live at /api/bundle/latest and /api/bundle/build") -ForegroundColor Green
