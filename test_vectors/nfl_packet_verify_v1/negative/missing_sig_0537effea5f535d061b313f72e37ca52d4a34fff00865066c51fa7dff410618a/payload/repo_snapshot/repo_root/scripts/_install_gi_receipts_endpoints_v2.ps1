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
Write-Host "== GI RECEIPTS ENDPOINTS INSTALL (V2) ==" -ForegroundColor Cyan
Write-Host ("Root: {0}" -f $Root) -ForegroundColor Cyan

$FnRoot = Join-Path $Root "supabase\functions"
$FnGet  = Join-Path $FnRoot "gi-receipt-get\index.ts"
$FnVer  = Join-Path $FnRoot "gi-receipt-verify\index.ts"
$FnMint = Join-Path $FnRoot "gi-receipt-mint\index.ts"

$TSH = @()
$TSH += '// deno-lint-ignore-file no-explicit-any'
$TSH += 'import { createClient } from "https://esm.sh/@supabase/supabase-js@2";'
$TSH += ''
$TSH += 'function j(status: number, body: any) {'
$TSH += '  return new Response(JSON.stringify(body, null, 2), {'
$TSH += '    status,'
$TSH += '    headers: { "content-type": "application/json" },'
$TSH += '  });'
$TSH += '}'
$TSH += ''
$TSH += 'function mustEnv(name: string) {'
$TSH += '  const v = Deno.env.get(name);'
$TSH += '  if (!v || v.trim().length === 0) throw new Error("MISSING_ENV:" + name);'
$TSH += '  return v.trim();'
$TSH += '}'
$TSH += ''
$TSH += 'function requireInternal(req: Request) {'
$TSH += '  const want = mustEnv("GI_INTERNAL_SECRET");'
$TSH += '  const got = (req.headers.get("x-gi-internal-secret") ?? "").trim();'
$TSH += '  if (!got) return { ok: false, resp: j(401, { ok: false, reason: "MISSING_INTERNAL_SECRET" }) };'
$TSH += '  if (got !== want) return { ok: false, resp: j(403, { ok: false, reason: "INVALID_INTERNAL_SECRET" }) };'
$TSH += '  return { ok: true, resp: null as any };'
$TSH += '}'
$TSH += ''
$TSH += 'function sb() {'
$TSH += '  const url = mustEnv("GI_SUPABASE_URL");'
$TSH += '  const key = mustEnv("GI_SUPABASE_SECRET_KEY");'
$TSH += '  return createClient(url, key, { auth: { persistSession: false } });'
$TSH += '}'

$TS = @(); $TS += $TSH
$TS += ''
$TS += 'export default async (req: Request) => {'
$TS += '  try {'
$TS += '    if (req.method !== "POST") return j(405, { ok: false, reason: "METHOD_NOT_ALLOWED" });'
$TS += '    const gate = requireInternal(req); if (!gate.ok) return gate.resp;'
$TS += ''
$TS += '    const b = await req.json().catch(() => null);'
$TS += '    const receipt_id = (b?.receipt_id ?? "").toString().trim();'
$TS += '    if (!receipt_id) return j(400, { ok: false, reason: "MISSING_RECEIPT_ID" });'
$TS += ''
$TS += '    const supabase = sb();'
$TS += '    const { data, error } = await supabase'
$TS += '      .from("gi_receipts")'
$TS += '      .select("*")'
$TS += '      .eq("receipt_id", receipt_id)'
$TS += '      .maybeSingle();'
$TS += ''
$TS += '    if (error) return j(500, { ok: false, reason: "DB_ERROR", detail: error.message });'
$TS += '    if (!data)  return j(404, { ok: false, reason: "RECEIPT_NOT_FOUND", receipt_id });'
$TS += '    return j(200, { ok: true, receipt: data });'
$TS += '  } catch (e: any) {'
$TS += '    return j(500, { ok: false, reason: "SERVER_ERROR", detail: String(e?.message ?? e) });'
$TS += '  }'
$TS += '};'
WriteFile $FnGet ($TS -join "`r`n")
Write-Host ("WROTE: {0}" -f $FnGet) -ForegroundColor Green

$TS = @(); $TS += $TSH
$TS += ''
$TS += 'export default async (req: Request) => {'
$TS += '  try {'
$TS += '    if (req.method !== "POST") return j(405, { ok: false, reason: "METHOD_NOT_ALLOWED" });'
$TS += '    const gate = requireInternal(req); if (!gate.ok) return gate.resp;'
$TS += ''
$TS += '    const b = await req.json().catch(() => null);'
$TS += '    const receipt_id = (b?.receipt_id ?? "").toString().trim();'
$TS += '    const proposal = b?.proposal ?? null;'
$TS += '    if (!receipt_id) return j(400, { ok: false, reason: "MISSING_RECEIPT_ID" });'
$TS += '    if (proposal === null || typeof proposal !== "object") return j(400, { ok: false, reason: "MISSING_OR_INVALID_PROPOSAL" });'
$TS += ''
$TS += '    const supabase = sb();'
$TS += '    const { data, error } = await supabase.rpc("gi_verify_receipt", {'
$TS += '      p_receipt_id: receipt_id,'
$TS += '      p_proposal: proposal,'
$TS += '    });'
$TS += '    if (error) return j(500, { ok: false, reason: "RPC_ERROR", detail: error.message });'
$TS += '    return j(200, data);'
$TS += '  } catch (e: any) {'
$TS += '    return j(500, { ok: false, reason: "SERVER_ERROR", detail: String(e?.message ?? e) });'
$TS += '  }'
$TS += '};'
WriteFile $FnVer ($TS -join "`r`n")
Write-Host ("WROTE: {0}" -f $FnVer) -ForegroundColor Green

$TS = @(); $TS += $TSH
$TS += ''
$TS += 'export default async (req: Request) => {'
$TS += '  try {'
$TS += '    if (req.method !== "POST") return j(405, { ok: false, reason: "METHOD_NOT_ALLOWED" });'
$TS += '    const gate = requireInternal(req); if (!gate.ok) return gate.resp;'
$TS += ''
$TS += '    const b = await req.json().catch(() => null);'
$TS += '    const proposal = b?.proposal ?? { hello: "world" };'
$TS += '    if (proposal === null || typeof proposal !== "object") return j(400, { ok: false, reason: "INVALID_PROPOSAL" });'
$TS += ''
$TS += '    const supabase = sb();'
$TS += '    let { data: pv } = await supabase.from("gi_policy_versions")'
$TS += '      .select("policy_version_id,policy_sha256")'
$TS += '      .order("created_at",{ascending:true})'
$TS += '      .limit(1).maybeSingle();'
$TS += '    if (!pv) {'
$TS += '      const p = { canonical: "policy_v1", allow: true };'
$TS += '      const sha = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(p)));'
$TS += '      const hex = Array.from(new Uint8Array(sha)).map(b => b.toString(16).padStart(2,"0")).join("");'
$TS += '      const ins = await supabase.from("gi_policy_versions").insert({ policy_sha256: hex, policy_json: p, frozen: true })'
$TS += '        .select("policy_version_id,policy_sha256").single();'
$TS += '      if (ins.error) return j(500, { ok:false, reason:"POLICY_INSERT_FAIL", detail: ins.error.message });'
$TS += '      pv = ins.data;'
$TS += '    }'
$TS += '    const evaluation_id = crypto.randomUUID();'
$TS += '    const rpc = await supabase.rpc("gi_write_receipt", {'
$TS += '      p_evaluation_id: evaluation_id,'
$TS += '      p_policy_version_id: pv.policy_version_id,'
$TS += '      p_overlay_version_id: null, p_overlay_sha256: null,'
$TS += '      p_schema_overlay_version_id: null, p_schema_overlay_sha256: null,'
$TS += '      p_proposal: proposal,'
$TS += '      p_decision: "ALLOW",'
$TS += '      p_reason_codes: ["MINT_TEST"],'
$TS += '      p_results: { minted: true },'
$TS += '      p_caller_org_id: null, p_caller_user_id: null,'
$TS += '    });'
$TS += '    if (rpc.error) return j(500, { ok:false, reason:"RECEIPT_WRITE_FAIL", detail: rpc.error.message });'
$TS += '    return j(200, { ok:true, receipt_id: rpc.data, evaluation_id });'
$TS += '  } catch (e: any) {'
$TS += '    return j(500, { ok: false, reason: "SERVER_ERROR", detail: String(e?.message ?? e) });'
$TS += '  }'
$TS += '};'
WriteFile $FnMint ($TS -join "`r`n")
Write-Host ("WROTE: {0}" -f $FnMint) -ForegroundColor Green

$url = GetEnvAny "GI_SUPABASE_URL"
if ([string]::IsNullOrWhiteSpace($url)) { $url = ("https://{0}.supabase.co" -f $ProjectRef) }
$key = GetEnvAny "GI_SUPABASE_SECRET_KEY"
if ([string]::IsNullOrWhiteSpace($key)) { Die "GI_SUPABASE_SECRET_KEY missing (Process/User/Machine). Set it and rerun." }
if ($key -match "\s") { Die "GI_SUPABASE_SECRET_KEY contains spaces. Refusing." }
$internal = GetEnvAny "GI_PPI_WEBHOOK_INTERNAL_SECRET"
if ([string]::IsNullOrWhiteSpace($internal)) { Die "GI_PPI_WEBHOOK_INTERNAL_SECRET missing (Process/User/Machine). Set it and rerun." }
if ($internal -match "\s") { Die "GI_PPI_WEBHOOK_INTERNAL_SECRET contains spaces. Refusing." }

Push-Location $Root
try {
  Write-Host "== deploy functions ==" -ForegroundColor Cyan
  supabase functions deploy gi-receipt-get    | Out-Host
  supabase functions deploy gi-receipt-verify | Out-Host
  supabase functions deploy gi-receipt-mint   | Out-Host
  Write-Host "== set edge secrets ==" -ForegroundColor Cyan
  supabase secrets set ("GI_SUPABASE_URL=" + $url) | Out-Host
  supabase secrets set ("GI_SUPABASE_SECRET_KEY=" + $key) | Out-Host
  supabase secrets set ("GI_INTERNAL_SECRET=" + $internal) | Out-Host
  Write-Host "OK: deployed + secrets set" -ForegroundColor Green
} finally { Pop-Location }