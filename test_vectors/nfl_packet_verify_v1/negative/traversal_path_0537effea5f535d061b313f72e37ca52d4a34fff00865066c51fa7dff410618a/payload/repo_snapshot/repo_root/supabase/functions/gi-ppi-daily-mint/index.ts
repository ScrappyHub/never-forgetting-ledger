// supabase/functions/gi-ppi-daily-mint/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";

function mustGetEnv(name: string): string {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`Missing env: ${name}`);
  return v;
}

async function pgCall(sql: string, params: unknown[] = []) {
  const url = mustGetEnv("GI_PPI_DB_URL");
  const { Client } = await import("https://deno.land/x/postgres@v0.19.3/mod.ts");
  const client = new Client(url);
  await client.connect();
  try {
    const res = await client.queryObject({ text: sql, args: params });
    return res.rows;
  } finally {
    await client.end();
  }
}

function json(res: unknown, status = 200) {
  return new Response(JSON.stringify(res), {
    status,
    headers: { "content-type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method !== "POST") return json({ ok: false, error: "METHOD_NOT_ALLOWED" }, 405);

  const operatorUserId = mustGetEnv("GI_PPI_SYSTEM_OPERATOR_USER_ID");

  // Optional internal secret
  const internalSecret = Deno.env.get("GI_PPI_WEBHOOK_INTERNAL_SECRET");
  if (internalSecret) {
    const got = req.headers.get("x-gi-ppi-internal-secret");
    if (got !== internalSecret) return json({ ok: false, error: "UNAUTHORIZED" }, 401);
  }

  const now = new Date();
  const month = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), 1)).toISOString().slice(0, 10);

  const rows = await pgCall(
    `
    begin;
      select set_config('request.jwt.claim.role', 'service_role', true);
      select set_config('request.jwt.claim.sub', $1, true);

      with due as (
        select * from public.gi_ppi_list_orgs_due_for_monthly_mint($2::date)
      ),
      minted as (
        select
          d.org_id,
          (public.gi_ppi_admin_mint_monthly_credits(d.org_id, d.mint_month)).*
        from due d
      )
      select jsonb_build_object(
        'month', $2::date,
        'minted_count', (select count(*) from minted),
        'minted', coalesce(jsonb_agg(to_jsonb(minted)), '[]'::jsonb)
      ) as result;

    commit;
    `,
    [operatorUserId, month],
  );

  return json({ ok: true, result: rows?.[0]?.result ?? null });
});
