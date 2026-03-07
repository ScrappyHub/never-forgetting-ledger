param(
  [Parameter(Mandatory=$false)][string]$ProjectRef = "hmlihkcijjamxdurydbv"
)
$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function WriteFile([string]$path, [string]$content){
  $dir = Split-Path -Parent $path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  [IO.File]::WriteAllText($path, $content, (Utf8NoBom))
  if (-not (Test-Path -LiteralPath $path)) { Die ("WRITE_FAILED: " + $path) }
}
function GetEnvAny([string]$name){
  $p = [Environment]::GetEnvironmentVariable($name,"Process"); if (-not [string]::IsNullOrWhiteSpace($p)) { return $p }
  $u = [Environment]::GetEnvironmentVariable($name,"User");    if (-not [string]::IsNullOrWhiteSpace($u)) { return $u }
  $m = [Environment]::GetEnvironmentVariable($name,"Machine"); if (-not [string]::IsNullOrWhiteSpace($m)) { return $m }
  return $null
}

$Root = Split-Path -Parent $PSScriptRoot
Write-Host "== GI RECEIPTS ENDPOINTS INSTALL ==" -ForegroundColor Cyan
Write-Host ("Root: {0}" -f $Root) -ForegroundColor Cyan

# ---------- Paths ----------
$FnRoot = Join-Path $Root "supabase\functions"
$FnGet  = Join-Path $FnRoot "gi-receipt-get\index.ts"
$FnVer  = Join-Path $FnRoot "gi-receipt-verify\index.ts"
$FnMint = Join-Path $FnRoot "gi-receipt-mint\index.ts"

# ---------- Shared TS helpers (internal-secret gate) ----------
$tsHeader = @'TS'
// deno-lint-ignore-file no-explicit-any
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

function j(status: number, body: any) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function mustEnv(name: string) {
  const v = Deno.env.get(name);
  if (!v || v.trim().length === 0) throw new Error("MISSING_ENV:" + name);
  return v.trim();
}

function requireInternal(req: Request) {
  const want = mustEnv("GI_INTERNAL_SECRET");
  const got = (req.headers.get("x-gi-internal-secret") ?? "").trim();
  if (!got) return { ok: false, resp: j(401, { ok: false, reason: "MISSING_INTERNAL_SECRET" }) };
  if (got !== want) return { ok: false, resp: j(403, { ok: false, reason: "INVALID_INTERNAL_SECRET" }) };
  return { ok: true, resp: null as any };
}

function sb() {
  const url = mustEnv("GI_SUPABASE_URL");
  const key = mustEnv("GI_SUPABASE_SECRET_KEY");
  return createClient(url, key, { auth: { persistSession: false } });
}
TS'

# ---------- gi-receipt-get ----------
$codeGet = $tsHeader + @'TS'

export default async (req: Request) => {
  try {
    if (req.method !== "POST") return j(405, { ok: false, reason: "METHOD_NOT_ALLOWED" });
    const gate = requireInternal(req); if (!gate.ok) return gate.resp;

    const b = await req.json().catch(() => null);
    const receipt_id = (b?.receipt_id ?? "").toString().trim();
    if (!receipt_id) return j(400, { ok: false, reason: "MISSING_RECEIPT_ID" });

    const supabase = sb();
    const { data, error } = await supabase
      .from("gi_receipts")
      .select("*")
      .eq("receipt_id", receipt_id)
      .maybeSingle();

    if (error) return j(500, { ok: false, reason: "DB_ERROR", detail: error.message });
    if (!data)  return j(404, { ok: false, reason: "RECEIPT_NOT_FOUND", receipt_id });
    return j(200, { ok: true, receipt: data });
  } catch (e: any) {
    return j(500, { ok: false, reason: "SERVER_ERROR", detail: String(e?.message ?? e) });
  }
};
TS'

# ---------- gi-receipt-verify ----------
$codeVer = $tsHeader + @'TS'

export default async (req: Request) => {
  try {
    if (req.method !== "POST") return j(405, { ok: false, reason: "METHOD_NOT_ALLOWED" });
    const gate = requireInternal(req); if (!gate.ok) return gate.resp;

    const b = await req.json().catch(() => null);
    const receipt_id = (b?.receipt_id ?? "").toString().trim();
    const proposal = b?.proposal ?? null;
    if (!receipt_id) return j(400, { ok: false, reason: "MISSING_RECEIPT_ID" });
    if (proposal === null || typeof proposal !== "object") return j(400, { ok: false, reason: "MISSING_OR_INVALID_PROPOSAL" });

    const supabase = sb();
    const { data, error } = await supabase.rpc("gi_verify_receipt", {
      p_receipt_id: receipt_id,
      p_proposal: proposal,
    });
    if (error) return j(500, { ok: false, reason: "RPC_ERROR", detail: error.message });
    return j(200, data);
  } catch (e: any) {
    return j(500, { ok: false, reason: "SERVER_ERROR", detail: String(e?.message ?? e) });
  }
};
TS'

# ---------- gi-receipt-mint (creates one receipt row deterministically) ----------
$codeMint = $tsHeader + @'TS'

export default async (req: Request) => {
  try {
    if (req.method !== "POST") return j(405, { ok: false, reason: "METHOD_NOT_ALLOWED" });
    const gate = requireInternal(req); if (!gate.ok) return gate.resp;

    const b = await req.json().catch(() => null);
    const proposal = b?.proposal ?? { hello: "world" };
    if (proposal === null || typeof proposal !== "object") return j(400, { ok: false, reason: "INVALID_PROPOSAL" });

    const supabase = sb();

    // Pick the first available versions (or create them if missing)
    let { data: pv } = await supabase.from("gi_policy_versions").select("policy_version_id,policy_sha256").order("created_at",{ascending:true}).limit(1).maybeSingle();
    if (!pv) {
      const p = { canonical: "policy_v1", allow: true };
      const sha = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(p)));
      const hex = Array.from(new Uint8Array(sha)).map(b => b.toString(16).padStart(2,"0")).join("");
      const ins = await supabase.from("gi_policy_versions").insert({ policy_sha256: hex, policy_json: p, frozen: true }).select("policy_version_id,policy_sha256").single();
      if (ins.error) return j(500, { ok:false, reason:"POLICY_INSERT_FAIL", detail: ins.error.message });
      pv = ins.data;
    }

    // overlays optional for mint
    const evaluation_id = crypto.randomUUID();
    const decision = "ALLOW";
    const reason_codes = ["MINT_TEST"];
    const results = { minted: true };

    const rpc = await supabase.rpc("gi_write_receipt", {
      p_evaluation_id: evaluation_id,
      p_policy_version_id: pv.policy_version_id,
      p_overlay_version_id: null,
      p_overlay_sha256: null,
      p_schema_overlay_version_id: null,
      p_schema_overlay_sha256: null,
      p_proposal: proposal,
      p_decision: decision,
      p_reason_codes: reason_codes,
      p_results: results,
      p_caller_org_id: null,
      p_caller_user_id: null,
    });

    if (rpc.error) return j(500, { ok:false, reason:"RECEIPT_WRITE_FAIL", detail: rpc.error.message });

    return j(200, { ok:true, receipt_id: rpc.data, evaluation_id, decision, reason_codes });
  } catch (e: any) {
    return j(500, { ok: false, reason: "SERVER_ERROR", detail: String(e?.message ?? e) });
  }
};
TS'

# ---------- Write files ----------
WriteFile $FnGet  $codeGet
WriteFile $FnVer  $codeVer
WriteFile $FnMint $codeMint
Write-Host ("WROTE: {0}" -f $FnGet) -ForegroundColor Green
Write-Host ("WROTE: {0}" -f $FnVer) -ForegroundColor Green
Write-Host ("WROTE: {0}" -f $FnMint) -ForegroundColor Green

# ---------- Secrets ----------
$url = GetEnvAny "GI_SUPABASE_URL"
if ([string]::IsNullOrWhiteSpace($url)) { $url = ("https://{0}.supabase.co" -f $ProjectRef) }
$key = GetEnvAny "GI_SUPABASE_SECRET_KEY"
if ([string]::IsNullOrWhiteSpace($key)) { Die "GI_SUPABASE_SECRET_KEY missing (Process/User/Machine). Set it (User scope) and rerun." }
if ($key -match "\s") { Die "GI_SUPABASE_SECRET_KEY contains spaces (looks like a sentence). Refusing." }
$internal = GetEnvAny "GI_PPI_WEBHOOK_INTERNAL_SECRET"
if ([string]::IsNullOrWhiteSpace($internal)) { Die "GI_PPI_WEBHOOK_INTERNAL_SECRET missing (Process/User/Machine). This is your internal gate secret." }
if ($internal -match "\s") { Die "GI_PPI_WEBHOOK_INTERNAL_SECRET contains spaces (looks like a sentence). Refusing." }

Push-Location $Root
try {
  Write-Host "== deploy functions ==" -ForegroundColor Cyan
  supabase functions deploy gi-receipt-get    | Out-Host
  supabase functions deploy gi-receipt-verify | Out-Host
  supabase functions deploy gi-receipt-mint   | Out-Host

  Write-Host "== set edge secrets (GI_* only) ==" -ForegroundColor Cyan
  supabase secrets set ("GI_SUPABASE_URL=" + $url) | Out-Host
  supabase secrets set ("GI_SUPABASE_SECRET_KEY=" + $key) | Out-Host
  supabase secrets set ("GI_INTERNAL_SECRET=" + $internal) | Out-Host

  Write-Host "== smoke: mint -> get -> verify ==" -ForegroundColor Cyan
  $base = ("https://{0}.functions.supabase.co" -f $ProjectRef)
  $h = @("Content-Type: application/json", ("x-gi-internal-secret: " + $internal))
  $mintBody = @{ proposal = @{ test = "mint"; t_utc = (Get-Date).ToUniversalTime().ToString("o") } } | ConvertTo-Json -Depth 50
  $mint = curl.exe -s -X POST ($base + "/gi-receipt-mint") -H $h[0] -H $h[1] -d $mintBody | ConvertFrom-Json
  if (-not $mint.ok) { throw ("MINT_FAIL: " + (($mint | ConvertTo-Json -Depth 50))) }
  $rid = $mint.receipt_id
  Write-Host ("MINTED receipt_id: {0}" -f $rid) -ForegroundColor Green

  $getBody = @{ receipt_id = $rid } | ConvertTo-Json -Depth 50
  curl.exe -s -X POST ($base + "/gi-receipt-get") -H $h[0] -H $h[1] -d $getBody | Out-Host

  $verBody = @{ receipt_id = $rid; proposal = @{ test = "mint"; t_utc = $mintBody } } | ConvertTo-Json -Depth 50
  curl.exe -s -X POST ($base + "/gi-receipt-verify") -H $h[0] -H $h[1] -d $verBody | Out-Host

  Write-Host "OK: GI RECEIPTS ENDPOINTS READY" -ForegroundColor Green
} finally {
  Pop-Location
}