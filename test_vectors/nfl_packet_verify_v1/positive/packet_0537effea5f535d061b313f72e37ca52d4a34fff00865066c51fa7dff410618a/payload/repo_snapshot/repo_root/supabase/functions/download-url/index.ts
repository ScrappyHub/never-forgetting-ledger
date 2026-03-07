/**
 * GI-PPI download-url (canonical)
 * - Auth wall: x-gi-ppi-secret must match GI_PPI_WEBHOOK_INTERNAL_SECRET
 * - Looks up artifact location from public.gi_ppi_artifacts (bucket_id + object_path)
 * - Uses Storage signed URL via service role (no SQL on storage internals)
 * - Writes issuance ledger row (ok/deny/error)
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

type Json = Record<string, unknown>;

function json(status: number, obj: Json) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function mustEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`Missing env: ${name}`);
  return v;
}

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") return json(405, { ok: false, error: "METHOD_NOT_ALLOWED" });

    const expected = Deno.env.get("GI_PPI_WEBHOOK_INTERNAL_SECRET") ?? "";
    const got = req.headers.get("x-gi-ppi-secret") ?? "";
    if (!expected || !got || got !== expected) {
      return json(401, { ok: false, error: "UNAUTHORIZED" });
    }

    const body = await req.json().catch(() => null) as any;
    const org_id = body?.org_id as string | undefined;
    const user_id = body?.user_id as string | undefined;
    const artifact_key = body?.artifact_key as string | undefined;
    const expires_in_seconds = Number(body?.expires_in_seconds ?? 300);

    if (!org_id || !user_id || !artifact_key) {
      return json(400, { ok: false, error: "BAD_REQUEST", message: "org_id, user_id, artifact_key required" });
    }
    if (!Number.isFinite(expires_in_seconds) || expires_in_seconds < 60 || expires_in_seconds > 3600) {
      return json(400, { ok: false, error: "BAD_REQUEST", message: "expires_in_seconds must be 60..3600" });
    }

    const supabaseUrl = mustEnv("SUPABASE_URL");
    const serviceKey = mustEnv("SUPABASE_SERVICE_ROLE_KEY");
    const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false } });

    // 1) Lookup artifact location (canonical truth)
    const { data: a, error: aerr } = await admin
      .from("gi_ppi_artifacts")
      .select("artifact_key,bucket_id,object_path,sha256,size_bytes,version,platform,created_utc")
      .eq("artifact_key", artifact_key)
      .maybeSingle();

    if (aerr) {
      // ledger
      await admin.from("gi_ppi_download_issuance").insert([{
        org_id, user_id, artifact_key,
        expires_at: new Date(Date.now() + expires_in_seconds * 1000).toISOString(),
        policy_snapshot: { reason: "artifact_lookup_error" },
        request_ip: req.headers.get("x-forwarded-for") ?? null,
        user_agent: req.headers.get("user-agent") ?? null,
        result: "error",
        error: String(aerr.message ?? aerr),
      }]);
      return json(500, { ok: false, error: "INTERNAL", message: "artifact lookup failed" });
    }

    if (!a) {
      await admin.from("gi_ppi_download_issuance").insert([{
        org_id, user_id, artifact_key,
        expires_at: new Date(Date.now() + expires_in_seconds * 1000).toISOString(),
        policy_snapshot: { reason: "artifact_not_found" },
        request_ip: req.headers.get("x-forwarded-for") ?? null,
        user_agent: req.headers.get("user-agent") ?? null,
        result: "deny",
        error: "artifact not registered",
      }]);
      return json(404, { ok: false, error: "NOT_FOUND", message: "artifact_key not registered" });
    }

    // 2) Mint signed URL
    const { data: s, error: serr } = await admin.storage
      .from(a.bucket_id)
      .createSignedUrl(a.object_path, expires_in_seconds);

    if (serr || !s?.signedUrl) {
      await admin.from("gi_ppi_download_issuance").insert([{
        org_id, user_id, artifact_key,
        expires_at: new Date(Date.now() + expires_in_seconds * 1000).toISOString(),
        policy_snapshot: { reason: "signed_url_error", bucket_id: a.bucket_id, object_path: a.object_path },
        request_ip: req.headers.get("x-forwarded-for") ?? null,
        user_agent: req.headers.get("user-agent") ?? null,
        result: "error",
        error: String(serr?.message ?? "no signedUrl"),
      }]);
      return json(500, { ok: false, error: "INTERNAL", message: "signed url failed" });
    }

    // 3) Ledger ok + return integrity metadata so client can verify download
    await admin.from("gi_ppi_download_issuance").insert([{
      org_id, user_id, artifact_key,
      expires_at: new Date(Date.now() + expires_in_seconds * 1000).toISOString(),
      policy_snapshot: {
        version: a.version,
        platform: a.platform,
        sha256: a.sha256,
        size_bytes: a.size_bytes,
        bucket_id: a.bucket_id,
        object_path: a.object_path,
      },
      request_ip: req.headers.get("x-forwarded-for") ?? null,
      user_agent: req.headers.get("user-agent") ?? null,
      result: "ok",
      error: null,
    }]);

    return json(200, {
      ok: true,
      artifact: {
        artifact_key: a.artifact_key,
        version: a.version,
        platform: a.platform,
        sha256: a.sha256,
        size_bytes: a.size_bytes,
        created_utc: a.created_utc,
      },
      signed_url: s.signedUrl,
      expires_in_seconds,
    });
  } catch (e) {
    return json(500, { ok: false, error: "INTERNAL", message: String(e?.message ?? e) });
  }
});