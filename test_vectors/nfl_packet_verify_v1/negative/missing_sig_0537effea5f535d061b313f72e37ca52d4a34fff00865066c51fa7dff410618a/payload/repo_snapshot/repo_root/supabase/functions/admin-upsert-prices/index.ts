// supabase/functions/admin-upsert-prices/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

type Row = {
  plan_code: string;
  provider: string; // 'stripe'
  billing_period: "monthly" | "quarterly" | "annual";
  external_price_id: string;
  currency: string; // 'usd'
  active: boolean;
};

function json(status: number, obj: unknown) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

async function dbQuery(sql: string, params: unknown[] = []) {
  const url = Deno.env.get("GI_PPI_DB_URL");
  if (!url) throw new Error("GI_PPI_DB_URL_MISSING");
  const { Client } = await import("npm:pg@8.11.3");
  const client = new Client({ connectionString: url });
  await client.connect();
  try {
    return await client.query(sql, params);
  } finally {
    await client.end();
  }
}

serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "METHOD_NOT_ALLOWED" });

  // Protect this endpoint with internal secret
  const internal = Deno.env.get("GI_PPI_WEBHOOK_INTERNAL_SECRET");
  if (!internal) return json(500, { error: "INTERNAL_SECRET_MISSING" });

  const got = req.headers.get("x-gi-ppi-secret");
  if (got !== internal) return json(401, { error: "UNAUTHORIZED" });

  let rows: Row[];
  try {
    const body = await req.json();
    rows = body?.rows;
  } catch {
    return json(400, { error: "INVALID_JSON" });
  }

  if (!Array.isArray(rows) || rows.length === 0) {
    return json(400, { error: "ROWS_REQUIRED" });
  }

  let upserted = 0;
  for (const r of rows) {
    await dbQuery(
      `
      select *
      from public.gi_ppi_admin_upsert_plan_price(
        $1::text, $2::text, $3::text, $4::text, $5::text, $6::boolean
      );
      `,
      [r.plan_code, r.provider, r.billing_period, r.external_price_id, r.currency, r.active]
    );
    upserted++;
  }

  return json(200, { ok: true, upserted });
});
