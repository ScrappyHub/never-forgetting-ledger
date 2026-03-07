param(
  [Parameter(Mandatory=$false)][string]$ProjectRef = "hmlihkcijjamxdurydbv"
)

$ErrorActionPreference="Stop"
Set-StrictMode -Version Latest

function Die([string]$m){ throw $m }
function Utf8NoBom(){ New-Object System.Text.UTF8Encoding($false) }
function J([object]$o){ return ($o | ConvertTo-Json -Depth 30) }

function LoadEnvFile([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return @{} }
  $map = @{}
  foreach ($ln in (Get-Content -LiteralPath $path)) {
    $s = $ln.Trim()
    if ($s.Length -eq 0) { continue }
    if ($s.StartsWith("#")) { continue }
    $idx = $s.IndexOf("=")
    if ($idx -lt 1) { continue }
    $k = $s.Substring(0,$idx).Trim()
    $v = $s.Substring($idx+1).Trim()
    if ($k.Length -eq 0) { continue }
    $map[$k] = $v
  }
  return $map
}

function Must([hashtable]$m,[string]$k){
  if (-not $m.ContainsKey($k) -or [string]::IsNullOrWhiteSpace([string]$m[$k])) {
    Die ("Missing required key in env file: " + $k)
  }
  return [string]$m[$k]
}

$Root = Split-Path -Parent $PSScriptRoot
$SecretsDir = Join-Path $Root ".secrets"
$EnvFile    = Join-Path $SecretsDir "gi-ppi.env"
$envMap     = LoadEnvFile $EnvFile

# Canonical naming you want:
#   SUPABASE_URL
#   SUPABASE_SECRET_KEY
#   SUPABASE_PUBLISHABLE_KEY (optional; not required for these two functions)
#   GI_PPI_WEBHOOK_INTERNAL_SECRET

# Compatibility mapping (your repo previously used SUPABASE_SERVICE_ROLE_KEY; if present, map it to SUPABASE_SECRET_KEY)
if (-not $envMap.ContainsKey("SUPABASE_SECRET_KEY") -and $envMap.ContainsKey("SUPABASE_SERVICE_ROLE_KEY")) {
  $envMap["SUPABASE_SECRET_KEY"] = $envMap["SUPABASE_SERVICE_ROLE_KEY"]
}

$SupabaseUrl = ("https://{0}.supabase.co" -f $ProjectRef)
if ($envMap.ContainsKey("SUPABASE_URL") -and -not [string]::IsNullOrWhiteSpace($envMap["SUPABASE_URL"])) {
  $SupabaseUrl = [string]$envMap["SUPABASE_URL"]
} else {
  $envMap["SUPABASE_URL"] = $SupabaseUrl
}

$InternalSecret = Must $envMap "GI_PPI_WEBHOOK_INTERNAL_SECRET"
$SupabaseSecret = Must $envMap "SUPABASE_SECRET_KEY"

Write-Host "== GI-PPI INSTALL: publisher-init + publisher-commit ==" -ForegroundColor Cyan
Write-Host ("Root: {0}" -f $Root) -ForegroundColor Cyan
Write-Host ("ProjectRef: {0}" -f $ProjectRef) -ForegroundColor Cyan
Write-Host ("EnvFile: {0}" -f $EnvFile) -ForegroundColor Cyan

# ------------------------------------------------------------
# 1) Write migration
# ------------------------------------------------------------
$MigrationsDir = Join-Path $Root "supabase\migrations"
if (-not (Test-Path -LiteralPath $MigrationsDir)) { Die ("Missing migrations dir: " + $MigrationsDir) }
$stamp14 = (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss")
$MigPath = Join-Path $MigrationsDir ("{0}_gi_ppi_publisher_sessions_v1.sql" -f $stamp14)

$SQL = @'
begin;

-- GI-PPI: Publisher sessions (server-side publish lock)
-- Purpose:
--   - Enable a 2-step publish workflow via Edge Functions:
--       (1) publisher-init   => creates publish session + returns signed upload URL
--       (2) publisher-commit => verifies object exists + activates artifact + returns signed download URL
--   - Keeps Supabase Secret Key ONLY in Edge Function secrets, never on client/workstation pipelines.

create table if not exists public.gi_ppi_publish_sessions (
  publish_session_id uuid primary key default gen_random_uuid(),
  artifact_key text not null,
  bucket_id text not null,
  object_path text not null,
  version text not null,
  platform text not null default 'windows',
  expected_sha256 text not null,
  expected_size_bytes bigint not null,
  status text not null,
  created_utc timestamptz not null default now(),
  committed_utc timestamptz null,
  actual_size_bytes bigint null,
  storage_etag text null,
  storage_updated_utc timestamptz null,
  notes jsonb not null default '{}'::jsonb
);

create index if not exists gi_ppi_publish_sessions_artifact_key_idx on public.gi_ppi_publish_sessions(artifact_key);
create index if not exists gi_ppi_publish_sessions_status_idx on public.gi_ppi_publish_sessions(status);

alter table public.gi_ppi_publish_sessions enable row level security;

-- Hard deny by default (no permissive policies).
-- Edge Functions use the Supabase Secret Key and are not restricted by RLS in practice.

-- Ensure artifacts table has a minimal "state" surface (safe no-op if columns already exist).
do $$ begin
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='gi_ppi_artifacts' and column_name='status') then
    alter table public.gi_ppi_artifacts add column status text not null default 'active';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='gi_ppi_artifacts' and column_name='published_utc') then
    alter table public.gi_ppi_artifacts add column published_utc timestamptz null;
  end if;
  if not exists (select 1 from information_schema.columns where table_schema='public' and table_name='gi_ppi_artifacts' and column_name='last_verified_utc') then
    alter table public.gi_ppi_artifacts add column last_verified_utc timestamptz null;
  end if;
end $$;

commit;
'@

[IO.File]::WriteAllText($MigPath, $SQL, (Utf8NoBom))
if (-not (Test-Path -LiteralPath $MigPath)) { Die ("WRITE_FAILED: " + $MigPath) }
Write-Host ("WROTE MIGRATION: {0}" -f $MigPath) -ForegroundColor Green

# ------------------------------------------------------------
# 2) Write Edge Functions
# ------------------------------------------------------------
$FnDir = Join-Path $Root "supabase\functions"
New-Item -ItemType Directory -Path $FnDir -Force | Out-Null

$FnInitDir   = Join-Path $FnDir "publisher-init"
$FnCommitDir = Join-Path $FnDir "publisher-commit"
New-Item -ItemType Directory -Path $FnInitDir -Force | Out-Null
New-Item -ItemType Directory -Path $FnCommitDir -Force | Out-Null

$InitTs = Join-Path $FnInitDir "index.ts"
$CommitTs = Join-Path $FnCommitDir "index.ts"

# publisher-init
$InitCode = @'
/// <reference lib="deno.ns" />
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function mustEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v || v.trim().length === 0) throw new Error(`MISSING_ENV:${name}`);
  return v;
}

function mustHeader(req: Request, name: string): string {
  const v = req.headers.get(name);
  if (!v || v.trim().length === 0) throw new Error(`MISSING_HEADER:${name}`);
  return v;
}

function eqConst(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return out === 0;
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") return json(405, { ok: false, error: "METHOD_NOT_ALLOWED" });

    const internalSecret = mustEnv("GI_PPI_WEBHOOK_INTERNAL_SECRET");
    const got = mustHeader(req, "x-gi-ppi-secret");
    if (!eqConst(got, internalSecret)) return json(401, { ok: false, error: "UNAUTHORIZED" });

    const supabaseUrl = mustEnv("SUPABASE_URL");
    // Canonical naming: SUPABASE_SECRET_KEY
    // Back-compat: allow SUPABASE_SERVICE_ROLE_KEY if someone still has that name in secrets
    const supabaseSecret = Deno.env.get("SUPABASE_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseSecret || supabaseSecret.trim().length === 0) throw new Error("MISSING_ENV:SUPABASE_SECRET_KEY");

    const sb = createClient(supabaseUrl, supabaseSecret, { auth: { persistSession: false } });
    const body = await req.json();

    const artifact_key = String(body.artifact_key ?? "");
    const bucket_id    = String(body.bucket_id ?? "work-engines");
    const object_path  = String(body.object_path ?? "");
    const version      = String(body.version ?? "");
    const platform     = String(body.platform ?? "windows");
    const expected_sha256 = String(body.expected_sha256 ?? "").toLowerCase();
    const expected_size_bytes = Number(body.expected_size_bytes ?? 0);

    if (!artifact_key) return json(400, { ok:false, error:"MISSING_artifact_key" });
    if (!object_path) return json(400, { ok:false, error:"MISSING_object_path" });
    if (!version) return json(400, { ok:false, error:"MISSING_version" });
    if (!expected_sha256 || expected_sha256.length < 32) return json(400, { ok:false, error:"MISSING_expected_sha256" });
    if (!Number.isFinite(expected_size_bytes) || expected_size_bytes <= 0) return json(400, { ok:false, error:"MISSING_expected_size_bytes" });

    // Ensure bucket exists (idempotent).
    // Use Storage REST to list/create because it is deterministic and does not rely on client-side heuristics.
    const headers = { Authorization: `Bearer ${supabaseSecret}`, apikey: supabaseSecret, "content-type":"application/json" };
    const listUrl = `${supabaseUrl}/storage/v1/bucket`;
    const listResp = await fetch(listUrl, { method:"GET", headers });
    if (!listResp.ok) {
      const t = await listResp.text();
      return json(502, { ok:false, error:"BUCKET_LIST_FAILED", detail:t.slice(0,500) });
    }
    const buckets = await listResp.json();
    const exists = Array.isArray(buckets) && buckets.some((b: any) => b?.id === bucket_id);
    if (!exists) {
      const createResp = await fetch(`${supabaseUrl}/storage/v1/bucket`, {
        method:"POST", headers, body: JSON.stringify({ id: bucket_id, name: bucket_id, public: false }),
      });
      if (!createResp.ok) {
        const t = await createResp.text();
        return json(502, { ok:false, error:"BUCKET_CREATE_FAILED", detail:t.slice(0,500) });
      }
    }

    // Create publish session (STAGED)
    const ins = await sb.from("gi_ppi_publish_sessions").insert({
      artifact_key, bucket_id, object_path, version, platform,
      expected_sha256, expected_size_bytes, status: "STAGED",
    }).select("publish_session_id, created_utc").single();

    if (ins.error) return json(502, { ok:false, error:"SESSION_INSERT_FAILED", detail: ins.error.message });

    // Upsert artifact row into STAGED state (does NOT mark active yet)
    const art = await sb.from("gi_ppi_artifacts").upsert({
      artifact_key, bucket_id, object_path, sha256: expected_sha256, size_bytes: expected_size_bytes,
      version, platform, status: "staged", published_utc: null, last_verified_utc: null,
    }, { onConflict: "artifact_key" }).select("artifact_key").single();

    if (art.error) return json(502, { ok:false, error:"ARTIFACT_UPSERT_FAILED", detail: art.error.message });

    // Create signed upload URL (direct-to-storage, no keys on client)
    // NOTE: Signed upload URL in supabase-js v2 uses token + signedUrl; clients upload via uploadToSignedUrl
    const up = await sb.storage.from(bucket_id).createSignedUploadUrl(object_path);
    if (up.error) return json(502, { ok:false, error:"SIGNED_UPLOAD_FAILED", detail: up.error.message });

    return json(200, {
      ok: true,
      publish_session_id: ins.data.publish_session_id,
      upload: {
        bucket_id, object_path,
        signed_url: up.data?.signedUrl ?? null,
        token: up.data?.token ?? null,
      },
    });
  } catch (e) {
    return json(500, { ok:false, error:"EXCEPTION", detail: String(e?.message ?? e) });
  }
});
'@

[IO.File]::WriteAllText($InitTs, $InitCode, (Utf8NoBom))
if (-not (Test-Path -LiteralPath $InitTs)) { Die ("WRITE_FAILED: " + $InitTs) }
Write-Host ("WROTE: {0}" -f $InitTs) -ForegroundColor Green

# publisher-commit
$CommitCode = @'
/// <reference lib="deno.ns" />
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function mustEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v || v.trim().length === 0) throw new Error(`MISSING_ENV:${name}`);
  return v;
}

function mustHeader(req: Request, name: string): string {
  const v = req.headers.get(name);
  if (!v || v.trim().length === 0) throw new Error(`MISSING_HEADER:${name}`);
  return v;
}

function eqConst(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return out === 0;
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") return json(405, { ok:false, error:"METHOD_NOT_ALLOWED" });

    const internalSecret = mustEnv("GI_PPI_WEBHOOK_INTERNAL_SECRET");
    const got = mustHeader(req, "x-gi-ppi-secret");
    if (!eqConst(got, internalSecret)) return json(401, { ok:false, error:"UNAUTHORIZED" });

    const supabaseUrl = mustEnv("SUPABASE_URL");
    const supabaseSecret = Deno.env.get("SUPABASE_SECRET_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseSecret || supabaseSecret.trim().length === 0) throw new Error("MISSING_ENV:SUPABASE_SECRET_KEY");

    const sb = createClient(supabaseUrl, supabaseSecret, { auth: { persistSession: false } });
    const body = await req.json();

    const publish_session_id = String(body.publish_session_id ?? "");
    const expires_in_seconds = Number(body.expires_in_seconds ?? 300);
    if (!publish_session_id) return json(400, { ok:false, error:"MISSING_publish_session_id" });
    if (!Number.isFinite(expires_in_seconds) || expires_in_seconds < 60 || expires_in_seconds > 3600) {
      return json(400, { ok:false, error:"BAD_expires_in_seconds" });
    }

    // Load session
    const ses = await sb.from("gi_ppi_publish_sessions")
      .select("*")
      .eq("publish_session_id", publish_session_id)
      .single();
    if (ses.error) return json(404, { ok:false, error:"SESSION_NOT_FOUND", detail: ses.error.message });

    const s = ses.data as any;
    if (String(s.status) !== "STAGED") {
      return json(409, { ok:false, error:"BAD_STATUS", status: s.status });
    }

    const bucket_id = String(s.bucket_id);
    const object_path = String(s.object_path);
    const artifact_key = String(s.artifact_key);
    const expected_sha256 = String(s.expected_sha256);
    const expected_size_bytes = Number(s.expected_size_bytes);

    // Verify object exists and get metadata via Storage REST info endpoint
    const headers = { Authorization: `Bearer ${supabaseSecret}`, apikey: supabaseSecret };
    const infoUrl = `${supabaseUrl}/storage/v1/object/info/${bucket_id}/${object_path}`;
    const infoResp = await fetch(infoUrl, { method:"GET", headers });
    if (!infoResp.ok) {
      const t = await infoResp.text();
      return json(409, { ok:false, error:"OBJECT_NOT_FOUND_OR_INFO_FAILED", detail:t.slice(0,500) });
    }
    const info = await infoResp.json();
    const actualSize = Number(info?.size ?? 0);
    const etag = String(info?.etag ?? "");
    const updatedAt = info?.updated_at ? String(info.updated_at) : null;

    if (!Number.isFinite(actualSize) || actualSize <= 0) {
      return json(409, { ok:false, error:"OBJECT_INFO_MISSING_SIZE" });
    }

    if (actualSize !== expected_size_bytes) {
      return json(409, {
        ok:false, error:"SIZE_MISMATCH",
        expected_size_bytes, actual_size_bytes: actualSize,
      });
    }

    // Activate artifact
    const upArt = await sb.from("gi_ppi_artifacts").upsert({
      artifact_key, bucket_id, object_path,
      sha256: expected_sha256, size_bytes: expected_size_bytes,
      version: String(s.version), platform: String(s.platform),
      status: "active",
      published_utc: new Date().toISOString(),
      last_verified_utc: new Date().toISOString(),
    }, { onConflict: "artifact_key" }).select("artifact_key").single();

    if (upArt.error) return json(502, { ok:false, error:"ARTIFACT_ACTIVATE_FAILED", detail: upArt.error.message });

    // Commit session
    const upSes = await sb.from("gi_ppi_publish_sessions").update({
      status: "PUBLISHED",
      committed_utc: new Date().toISOString(),
      actual_size_bytes: actualSize,
      storage_etag: etag || null,
      storage_updated_utc: updatedAt || null,
    }).eq("publish_session_id", publish_session_id).select("publish_session_id,status").single();

    if (upSes.error) return json(502, { ok:false, error:"SESSION_COMMIT_FAILED", detail: upSes.error.message });

    // Mint signed download URL
    const dl = await sb.storage.from(bucket_id).createSignedUrl(object_path, expires_in_seconds);
    if (dl.error) return json(502, { ok:false, error:"SIGNED_DOWNLOAD_FAILED", detail: dl.error.message });

    return json(200, {
      ok:true,
      publish_session_id,
      artifact_key,
      bucket_id, object_path,
      signed_url: dl.data?.signedUrl ?? null,
      expires_in_seconds,
    });
  } catch (e) {
    return json(500, { ok:false, error:"EXCEPTION", detail: String(e?.message ?? e) });
  }
});
'@

[IO.File]::WriteAllText($CommitTs, $CommitCode, (Utf8NoBom))
if (-not (Test-Path -LiteralPath $CommitTs)) { Die ("WRITE_FAILED: " + $CommitTs) }
Write-Host ("WROTE: {0}" -f $CommitTs) -ForegroundColor Green

# ------------------------------------------------------------
# 3) Apply migration + deploy functions + set secrets
# ------------------------------------------------------------
Push-Location $Root
try {
  Write-Host "Running: supabase link" -ForegroundColor Cyan
  supabase link --project-ref $ProjectRef | Out-Host

  Write-Host "Running: supabase db push" -ForegroundColor Cyan
  cmd.exe /c "echo y| supabase db push" | Out-Host

  Write-Host "Deploying: publisher-init" -ForegroundColor Cyan
  supabase functions deploy publisher-init --no-verify-jwt | Out-Host

  Write-Host "Deploying: publisher-commit" -ForegroundColor Cyan
  supabase functions deploy publisher-commit --no-verify-jwt | Out-Host

  Write-Host "Setting function secrets (server-side only)..." -ForegroundColor Cyan
  # These secrets are ONLY stored in Supabase Edge Function environment; not on client download/publish flows.
  supabase secrets set "SUPABASE_URL=$SupabaseUrl" "SUPABASE_SECRET_KEY=$SupabaseSecret" "GI_PPI_WEBHOOK_INTERNAL_SECRET=$InternalSecret" | Out-Host

  Write-Host "INSTALL COMPLETE" -ForegroundColor Green
} finally { Pop-Location }