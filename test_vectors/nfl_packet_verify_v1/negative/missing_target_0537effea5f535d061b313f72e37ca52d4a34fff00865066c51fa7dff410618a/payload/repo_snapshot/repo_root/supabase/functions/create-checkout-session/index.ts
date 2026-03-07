// supabase/functions/create-checkout-session/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.25.0?target=deno";

type Body = {
  org_id: string;
  plan_code: string;
  billing_period: "monthly" | "quarterly" | "annual";
  success_url: string;
  cancel_url: string;
};

function json(status: number, obj: unknown) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { "content-type": "application/json" },
  });
}

// Minimal DB query helper (no Supabase service key; direct DB role)
async function dbQuery(sql: string, params: unknown[] = []) {
  const url = Deno.env.get("GI_PPI_DB_URL");
  if (!url) throw new Error("GI_PPI_DB_URL_MISSING");

  // deno-postgres via npm (works in Supabase Edge)
  const { Client } = await import("npm:pg@8.11.3");
  const client = new Client({ connectionString: url });
  await client.connect();
  try {
    const res = await client.query(sql, params);
    return res;
  } finally {
    await client.end();
  }
}

serve(async (req) => {
  if (req.method !== "POST") return json(405, { error: "METHOD_NOT_ALLOWED" });

  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
  if (!stripeKey) return json(500, { error: "STRIPE_SECRET_KEY_MISSING" });

  const stripe = new Stripe(stripeKey, { apiVersion: "2023-10-16" });

  let body: Body;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "INVALID_JSON" });
  }

  const { org_id, plan_code, billing_period, success_url, cancel_url } = body ?? ({} as Body);
  if (!org_id) return json(400, { error: "ORG_ID_REQUIRED" });
  if (!plan_code) return json(400, { error: "PLAN_CODE_REQUIRED" });
  if (!billing_period) return json(400, { error: "BILLING_PERIOD_REQUIRED" });
  if (!success_url) return json(400, { error: "SUCCESS_URL_REQUIRED" });
  if (!cancel_url) return json(400, { error: "CANCEL_URL_REQUIRED" });

  // Look up Stripe price id from your canonical table (already populated)
  const q = await dbQuery(
    `
    select external_price_id, currency
    from public.gi_ppi_plan_prices
    where provider='stripe'
      and plan_code=$1
      and billing_period=$2
      and active=true
    limit 1
    `,
    [plan_code, billing_period]
  );

  const row = q.rows?.[0];
  if (!row) return json(400, { error: "PRICE_NOT_FOUND_FOR_PLAN_PERIOD" });

  const priceId = row.external_price_id as string;

  // Create Checkout Session
  const session = await stripe.checkout.sessions.create({
    mode: "subscription",
    line_items: [{ price: priceId, quantity: 1 }],
    success_url,
    cancel_url,

    // IMPORTANT: put metadata on session AND subscription
    metadata: {
      org_id,
      plan_code,
      billing_period,
    },
    subscription_data: {
      metadata: {
        org_id,
        plan_code,
        billing_period,
      },
    },
  });

  return json(200, { ok: true, checkout_url: session.url });
});

