// GI_RECEIPT_GET_LOCK_V5
// deno-lint-ignore-file no-explicit-any
export const config = { verify_jwt: false };

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
  const key = mustEnv("GI_SUPABASE_SECRET_KEY"); // service role / secret key
  return createClient(url, key, { auth: { persistSession: false } });
}

export default async (req: Request) => {
  try {
    if (req.method !== "POST") return j(405, { ok: false, reason: "METHOD_NOT_ALLOWED" });

    const gate = requireInternal(req);
    if (!gate.ok) return gate.resp;

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