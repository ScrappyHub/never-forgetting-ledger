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