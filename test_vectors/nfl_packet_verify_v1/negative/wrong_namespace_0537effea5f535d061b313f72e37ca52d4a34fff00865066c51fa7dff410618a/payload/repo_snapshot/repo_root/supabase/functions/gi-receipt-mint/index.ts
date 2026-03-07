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
    const proposal = b?.proposal ?? { hello: "world" };
    if (proposal === null || typeof proposal !== "object") return j(400, { ok: false, reason: "INVALID_PROPOSAL" });

    const supabase = sb();
    let { data: pv } = await supabase.from("gi_policy_versions")
      .select("policy_version_id,policy_sha256")
      .order("created_at",{ascending:true})
      .limit(1).maybeSingle();
    if (!pv) {
      const p = { canonical: "policy_v1", allow: true };
      const sha = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(JSON.stringify(p)));
      const hex = Array.from(new Uint8Array(sha)).map(b => b.toString(16).padStart(2,"0")).join("");
      const ins = await supabase.from("gi_policy_versions").insert({ policy_sha256: hex, policy_json: p, frozen: true })
        .select("policy_version_id,policy_sha256").single();
      if (ins.error) return j(500, { ok:false, reason:"POLICY_INSERT_FAIL", detail: ins.error.message });
      pv = ins.data;
    }
    const evaluation_id = crypto.randomUUID();
    const rpc = await supabase.rpc("gi_write_receipt", {
      p_evaluation_id: evaluation_id,
      p_policy_version_id: pv.policy_version_id,
      p_overlay_version_id: null, p_overlay_sha256: null,
      p_schema_overlay_version_id: null, p_schema_overlay_sha256: null,
      p_proposal: proposal,
      p_decision: "ALLOW",
      p_reason_codes: ["MINT_TEST"],
      p_results: { minted: true },
      p_caller_org_id: null, p_caller_user_id: null,
    });
    if (rpc.error) return j(500, { ok:false, reason:"RECEIPT_WRITE_FAIL", detail: rpc.error.message });
    return j(200, { ok:true, receipt_id: rpc.data, evaluation_id });
  } catch (e: any) {
    return j(500, { ok: false, reason: "SERVER_ERROR", detail: String(e?.message ?? e) });
  }
};