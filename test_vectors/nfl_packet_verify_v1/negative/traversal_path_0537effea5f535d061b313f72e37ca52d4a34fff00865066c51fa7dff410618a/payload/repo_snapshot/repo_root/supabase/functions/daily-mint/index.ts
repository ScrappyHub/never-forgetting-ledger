import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SECRET_KEY = Deno.env.get("SUPABASE_SECRET_KEY")!;
const INTERNAL_SECRET = Deno.env.get("GI_PPI_WEBHOOK_INTERNAL_SECRET")!;

if (!SUPABASE_URL || !SUPABASE_SECRET_KEY || !INTERNAL_SECRET) {
  throw new Error("MISSING_REQUIRED_ENV");
}

const supabaseAdmin = createClient(SUPABASE_URL, SUPABASE_SECRET_KEY, { auth: { persistSession: false } });

function monthStartUtc(d: Date): string {
  const y = d.getUTCFullYear();
  const m = d.getUTCMonth();
  return new Date(Date.UTC(y, m, 1)).toISOString().slice(0, 10); // YYYY-MM-DD
}

Deno.serve(async (req) => {
  try {
    // Optional hardening so random callers can't mint
    const got = req.headers.get("x-gi-ppi-webhook-secret") || "";
    if (got !== INTERNAL_SECRET) return new Response("FORBIDDEN", { status: 403 });

    const today = new Date();
    const mintMonth = monthStartUtc(today);

    const { data: due, error: dueErr } = await supabaseAdmin.rpc("gi_ppi_list_orgs_due_for_monthly_mint", {
      p_month: mintMonth,
    });

    if (dueErr) throw new Error(`DUE_LIST_FAILED: ${dueErr.message}`);

    const rows = Array.isArray(due) ? due : [];
    let minted = 0;

    for (const r of rows) {
      const orgId = r.org_id as string;
      const { error: mintErr } = await supabaseAdmin.rpc("gi_ppi_admin_mint_monthly_credits", {
        p_org_id: orgId,
        p_month: mintMonth,
      });
      if (mintErr) throw new Error(`MINT_FAILED org=${orgId}: ${mintErr.message}`);
      minted++;
    }

    return new Response(JSON.stringify({ ok: true, mint_month: mintMonth, due: rows.length, minted }), {
      headers: { "content-type": "application/json" },
    });
  } catch (e) {
    return new Response(`ERROR: ${(e as Error).message}`, { status: 500 });
  }
});
