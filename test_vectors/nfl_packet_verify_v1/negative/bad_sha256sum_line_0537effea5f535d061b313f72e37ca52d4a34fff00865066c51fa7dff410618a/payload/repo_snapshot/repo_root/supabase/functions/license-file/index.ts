// supabase/functions/license-file/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";

function json(status: number, body: unknown, headers: Record<string, string> = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });
}

function b64ToBytes(b64: string): Uint8Array {
  const bin = atob(b64);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

function bytesToB64(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s);
}

// Deterministic JSON stringify (canonical): sorts keys recursively.
// (This is what makes hashing/signing deterministic.)
function stableStringify(value: any): string {
  if (value === null || value === undefined) return "null";
  const t = typeof value;
  if (t === "number" || t === "boolean") return JSON.stringify(value);
  if (t === "string") return JSON.stringify(value);
  if (Array.isArray(value)) return "[" + value.map(stableStringify).join(",") + "]";
  if (t === "object") {
    const keys = Object.keys(value).sort();
    return "{" + keys.map((k) => JSON.stringify(k) + ":" + stableStringify(value[k])).join(",") + "}";
  }
  // fallback
  return JSON.stringify(String(value));
}

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", bytes));
  return Array.from(digest).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function reasonFromError(e: unknown): string {
  const msg = String((e as any)?.message ?? e ?? "");
  // Keep short + deterministic for analytics
  if (!msg) return "INTERNAL";
  return msg.length <= 80 ? msg : msg.slice(0, 80);
}

serve(async (req) => {
  const startedAt = Date.now();

  let org_id: string | null = null;
  let user_id: string | null = null;
  let artifact_key: string | null = null;

  let sql: any = null;

  const logEvent = async (ok: boolean, reason: string, extra: any = {}) => {
    try {
      if (!sql) return;
      await sql`
        select public.gi_ppi_edge_log_event(
          ${JSON.stringify({
            event_type: "license_file",
            ok,
            reason,
            org_id,
            user_id,
            artifact_key,
            metadata: { ms: Date.now() - startedAt, ...extra },
          })}::jsonb
        )
      `;
    } catch (_) {
      // never block main flow on logging
    }
  };

  try {
    if (req.method !== "POST") {
      return json(405, { ok: false, error: "METHOD_NOT_ALLOWED" });
    }

    const expectedInternal = Deno.env.get("GI_PPI_WEBHOOK_INTERNAL_SECRET");
    if (!expectedInternal) {
      return json(500, { ok: false, error: "MISSING_SECRET_SERVER_CONFIG" });
    }

    const got = req.headers.get("x-gi-ppi-secret");
    if (!got || got !== expectedInternal) {
      return json(401, { ok: false, error: "UNAUTHORIZED" });
    }

    const dbUrl = Deno.env.get("GI_PPI_DB_URL");
    if (!dbUrl) {
      return json(500, { ok: false, error: "GI_PPI_DB_URL_NOT_SET" });
    }

    const privB64 = Deno.env.get("GI_PPI_LICENSE_SIGNING_PRIVATE_KEY_B64");
    if (!privB64) {
      return json(500, { ok: false, error: "LICENSE_SIGNING_PRIVATE_KEY_NOT_SET" });
    }

    const body = await req.json().catch(() => null);
    if (!body || typeof body !== "object") {
      return json(400, { ok: false, error: "BODY_REQUIRED" });
    }

    org_id = typeof (body as any).org_id === "string" ? (body as any).org_id : null;
    user_id = typeof (body as any).user_id === "string" ? (body as any).user_id : null;
    artifact_key = typeof (body as any).artifact_key === "string" ? (body as any).artifact_key : null;

    if (!org_id) return json(400, { ok: false, error: "ORG_ID_REQUIRED" });
    if (!user_id) return json(400, { ok: false, error: "USER_ID_REQUIRED" });
    if (!artifact_key) return json(400, { ok: false, error: "ARTIFACT_KEY_REQUIRED" });

    sql = postgres(dbUrl, { max: 1, idle_timeout: 5 });

    // Call the canonical SECURITY DEFINER RPC (Edge role only needs EXECUTE on it)
    const rows = await sql`
      select public.gi_ppi_edge_issue_license_file(
        ${org_id}::uuid,
        ${artifact_key}::text,
        ${user_id}::uuid
      ) as result
    `;
    const result = rows?.[0]?.result ?? null;

    if (!result || result.ok !== true) {
      await logEvent(false, "ISSUE_FAILED", { db_result: result ?? null });
      return json(500, { ok: false, error: "ISSUE_FAILED" });
    }

    // Build license payload (deterministic)
    const issued_at = new Date().toISOString();
    const license_id = crypto.randomUUID();

    // What DB returned should include:
    // org_id, artifact_key, plan_code, entitlement_expires_at, flags{...}
    const licensePayload: any = {
      license_version: "v1",
      license_id,
      issued_at,
      org_id: result.org_id,
      artifact_key: result.artifact_key,
      plan_code: result.plan_code,
      entitlement_expires_at: result.entitlement_expires_at,
      flags: result.flags ?? {},
      // you can add anything else you want the Work Engine to enforce offline here,
      // as long as it stays deterministic and signed
    };

    // Hash + sign (signature covers everything except signature itself)
    const canonical = stableStringify(licensePayload);
    const canonicalBytes = new TextEncoder().encode(canonical);
    const payload_hash = await sha256Hex(canonicalBytes);

    const privKeyBytes = b64ToBytes(privB64);
    const cryptoKey = await crypto.subtle.importKey(
      "pkcs8",
      privKeyBytes.buffer,
      { name: "Ed25519" },
      false,
      ["sign"],
    );

    const sig = new Uint8Array(await crypto.subtle.sign({ name: "Ed25519" }, cryptoKey, canonicalBytes));
    const signature_b64 = bytesToB64(sig);

    const fullLicense = {
      ...licensePayload,
      payload_hash,
      signature: signature_b64,
      signature_alg: "Ed25519",
      signature_payload: "stable_json_v1",
    };

    await logEvent(true, "LICENSE_ISSUED", {
      plan_code: result.plan_code,
      entitlement_expires_at: result.entitlement_expires_at,
    });

    const filename = `${artifact_key}.license.json`;
    const fileBytes = new TextEncoder().encode(JSON.stringify(fullLicense, null, 2));

    return new Response(fileBytes, {
      status: 200,
      headers: {
        "content-type": "application/json; charset=utf-8",
        "content-disposition": `attachment; filename="${filename}"`,
        "cache-control": "no-store",
      },
    });
  } catch (e) {
    const reason = reasonFromError(e);
    try {
      await (async () => {
        if (!sql) return;
        await logEvent(false, reason);
      })();
    } catch (_) {}

    return json(500, {
      ok: false,
      error: "INTERNAL",
      message: String((e as any)?.message ?? e),
    });
  } finally {
    try {
      if (sql) await sql.end();
    } catch (_) {}
  }
});
