param([string]$ProjectRef = "hmlihkcijjamxdurydbv")
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
  foreach ($scope in @("Process","User","Machine")) {
    $v = [Environment]::GetEnvironmentVariable($name, $scope)
    if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
  }
  return $null
}

$Root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path -LiteralPath $Root)) { Die ("Repo root not found: " + $Root) }
Write-Host "== GI RECEIPT FUNCTIONS INSTALL (V4) ==" -ForegroundColor Cyan
Write-Host ("Root: {0}" -f $Root) -ForegroundColor Cyan

# A) Create Edge Function entrypoints
$FnRoot = Join-Path $Root "supabase\functions"
$FnGet  = Join-Path $FnRoot "gi-receipt-get\index.ts"
$FnVer  = Join-Path $FnRoot "gi-receipt-verify\index.ts"

# TS is embedded as a single-quoted here-string so PowerShell never expands anything
$codeGet = @'
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

export default async (req: Request) => {
  try {
    if (req.method !== "POST") return j(405, { ok: false, reason: "METHOD_NOT_ALLOWED" });

    const SUPABASE_URL = mustEnv("GI_SUPABASE_URL");
    const SECRET_KEY   = mustEnv("GI_SUPABASE_SECRET_KEY");

    const supabase = createClient(SUPABASE_URL, SECRET_KEY, {
      auth: { persistSession: false },
    });

    const b = await req.json().catch(() => null);
    const receipt_id = (b?.receipt_id ?? "").toString().trim();
    if (!receipt_id) return j(400, { ok: false, reason: "MISSING_RECEIPT_ID" });

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
'@

$codeVer = @'
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

export default async (req: Request) => {
  try {
    if (req.method !== "POST") return j(405, { ok: false, reason: "METHOD_NOT_ALLOWED" });

    const SUPABASE_URL = mustEnv("GI_SUPABASE_URL");
    const SECRET_KEY   = mustEnv("GI_SUPABASE_SECRET_KEY");

    const supabase = createClient(SUPABASE_URL, SECRET_KEY, {
      auth: { persistSession: false },
    });

    const b = await req.json().catch(() => null);
    const receipt_id = (b?.receipt_id ?? "").toString().trim();
    const proposal   = b?.proposal ?? null;

    if (!receipt_id) return j(400, { ok: false, reason: "MISSING_RECEIPT_ID" });
    if (proposal === null || typeof proposal !== "object") {
      return j(400, { ok: false, reason: "MISSING_OR_INVALID_PROPOSAL" });
    }

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
'@

WriteFile $FnGet $codeGet
WriteFile $FnVer $codeVer
Write-Host ("WROTE: {0}" -f $FnGet) -ForegroundColor Green
Write-Host ("WROTE: {0}" -f $FnVer) -ForegroundColor Green

# B) Deploy + set secrets
$url = GetEnvAny "GI_SUPABASE_URL"
if ([string]::IsNullOrWhiteSpace($url)) { $url = ("https://{0}.supabase.co" -f $ProjectRef) }
$key = GetEnvAny "GI_SUPABASE_SECRET_KEY"
if ([string]::IsNullOrWhiteSpace($key)) { Die "GI_SUPABASE_SECRET_KEY missing in Process/User/Machine." }
if ($key -match "\s") { Die "GI_SUPABASE_SECRET_KEY contains spaces (looks like a sentence). Set the real key." }

Push-Location $Root
try {
  Write-Host "== supabase functions deploy ==" -ForegroundColor Cyan
  supabase functions deploy gi-receipt-get    | Out-Host
  supabase functions deploy gi-receipt-verify | Out-Host
  Write-Host "== supabase secrets set (GI_* only) ==" -ForegroundColor Cyan
  supabase secrets set ("GI_SUPABASE_URL=" + $url) | Out-Host
  supabase secrets set ("GI_SUPABASE_SECRET_KEY=" + $key) | Out-Host
  Write-Host "OK: GI RECEIPT FUNCTIONS READY" -ForegroundColor Green
} finally {
  Pop-Location
}
