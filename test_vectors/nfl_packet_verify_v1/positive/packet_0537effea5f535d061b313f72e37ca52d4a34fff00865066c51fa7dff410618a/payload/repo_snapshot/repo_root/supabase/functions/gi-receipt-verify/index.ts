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