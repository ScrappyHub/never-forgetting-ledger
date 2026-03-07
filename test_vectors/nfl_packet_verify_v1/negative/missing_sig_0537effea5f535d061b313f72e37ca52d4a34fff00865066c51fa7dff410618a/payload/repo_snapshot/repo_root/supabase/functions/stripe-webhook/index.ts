// supabase/functions/stripe-webhook/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.25.0?target=deno";

function text(status: number, t: string) {
  return new Response(t, { status });
}

async function dbExec(sql: string, params: unknown[] = []) {
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
  if (req.method !== "POST") return text(405, "METHOD_NOT_ALLOWED");

  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY");
  const whsec = Deno.env.get("STRIPE_WEBHOOK_SECRET");
  if (!stripeKey) return text(500, "STRIPE_SECRET_KEY_MISSING");
  if (!whsec) return text(500, "STRIPE_WEBHOOK_SECRET_MISSING");

  const stripe = new Stripe(stripeKey, { apiVersion: "2023-10-16" });

  const sig = req.headers.get("stripe-signature");
  if (!sig) return text(400, "MISSING_STRIPE_SIGNATURE");

  const rawBody = await req.text();

  let event: Stripe.Event;
  try {
    event = stripe.webhooks.constructEvent(rawBody, sig, whsec);
  } catch (_e) {
    return text(400, "WEBHOOK_SIGNATURE_INVALID");
  }

  // We care about subscription lifecycle + invoice failures
  const handled = new Set([
    "checkout.session.completed",
    "customer.subscription.created",
    "customer.subscription.updated",
    "customer.subscription.deleted",
    "invoice.payment_failed",
    "invoice.payment_succeeded",
  ]);

  if (!handled.has(event.type)) {
    return text(200, "IGNORED");
  }

  // Extract subscription object
  let sub: Stripe.Subscription | null = null;

  if (event.type.startsWith("customer.subscription.")) {
    sub = event.data.object as Stripe.Subscription;
  } else if (event.type === "checkout.session.completed") {
    const sess = event.data.object as Stripe.Checkout.Session;
    if (sess.subscription) {
      sub = await stripe.subscriptions.retrieve(String(sess.subscription));
    }
  } else if (event.type.startsWith("invoice.")) {
    const inv = event.data.object as Stripe.Invoice;
    if (inv.subscription) {
      sub = await stripe.subscriptions.retrieve(String(inv.subscription));
    }
  }

  if (!sub) return text(200, "NO_SUBSCRIPTION");

  const md = (sub.metadata ?? {}) as Record<string, string>;

  const org_id = md.org_id;
  const plan_code = md.plan_code;
  const billing_period = md.billing_period;

  if (!org_id || !plan_code || !billing_period) {
    // hard fail closed for provisioning
    return text(400, "MISSING_REQUIRED_METADATA");
  }

  const payload = {
    event_id: event.id,
    event_type: event.type,
    org_id,
    plan_code,
    billing_period,
    subscription_id: sub.id,
    customer_id: String(sub.customer),

    status: sub.status,
    current_period_start: new Date(sub.current_period_start * 1000).toISOString(),
    current_period_end: new Date(sub.current_period_end * 1000).toISOString(),
    cancel_at_period_end: Boolean(sub.cancel_at_period_end),
  };

  // Call DB RPC (as gi_ppi_edge). Operator id is null because this is system-to-system.
  await dbExec(
    `select public.gi_ppi_stripe_sync_subscription($1::jsonb, $2::uuid);`,
    [JSON.stringify(payload), null]
  );

  return text(200, "OK");
});
