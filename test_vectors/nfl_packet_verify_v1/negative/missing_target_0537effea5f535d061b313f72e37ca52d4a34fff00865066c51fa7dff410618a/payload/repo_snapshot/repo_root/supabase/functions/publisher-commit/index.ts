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