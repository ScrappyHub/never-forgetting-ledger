// supabase/functions/mint-daily/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";
function json(status, body) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8"
    }
  });
}
serve(async (req)=>{
  try {
    if (req.method !== "POST") return json(405, {
      ok: false,
      error: "METHOD_NOT_ALLOWED"
    });
    const expected = Deno.env.get("GI_PPI_WEBHOOK_INTERNAL_SECRET");
    if (!expected) return json(500, {
      ok: false,
      error: "MISSING_SECRET_SERVER_CONFIG"
    });
    const got = req.headers.get("x-gi-ppi-secret");
    if (!got || got !== expected) return json(401, {
      ok: false,
      error: "UNAUTHORIZED"
    });
    const dbUrl = Deno.env.get("GI_PPI_DB_URL");
    if (!dbUrl) return json(500, {
      ok: false,
      error: "GI_PPI_DB_URL_NOT_SET"
    });
    const sql = postgres(dbUrl, {
      max: 1,
      idle_timeout: 5
    });
    // Optional body: { "month": "YYYY-MM-01" } or omit to use current month
    let month = null;
    try {
      const body = await req.json().catch(()=>null);
      if (body && typeof body.month === "string") month = body.month;
    } catch (_) {}
    const rows = await sql`
      select public.gi_ppi_edge_mint_monthly_credits(${month}::date) as result
    `;
    await sql.end();
    return json(200, rows?.[0]?.result ?? {
      ok: true,
      note: "NO_RESULT"
    });
  } catch (e) {
    // Return real error message so you’re not blind again
    return json(500, {
      ok: false,
      error: "INTERNAL",
      message: String(e?.message ?? e),
      // stack is helpful while you’re locking; remove later if you want
      stack: String(e?.stack ?? "")
    });
  }
});
