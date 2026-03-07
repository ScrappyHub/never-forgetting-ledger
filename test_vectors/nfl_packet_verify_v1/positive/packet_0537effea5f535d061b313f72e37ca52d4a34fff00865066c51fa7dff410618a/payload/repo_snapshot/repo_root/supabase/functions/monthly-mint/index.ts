import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

Deno.serve(async (_req) => {
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false },
  });

  const today = new Date();
  const month = new Date(Date.UTC(today.getUTCFullYear(), today.getUTCMonth(), 1))
    .toISOString()
    .slice(0, 10); // YYYY-MM-DD

  const { data, error } = await supabase.rpc("gi_ppi_service_run_monthly_mint", {
    p_month: month,
    p_limit: 500,
  });

  if (error) return new Response(`Mint RPC error: ${error.message}`, { status: 500 });
  return new Response(JSON.stringify({ ok: true, result: data }), {
    headers: { "content-type": "application/json" },
  });
});
