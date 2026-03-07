// supabase/functions/gi-ppi-stripe-webhook/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import Stripe from "https://esm.sh/stripe@14.25.0?target=deno";

type SyncPayload = {
  event_id: string;
  event_type: string;
  org_id: string;
  plan_code: string;
  billing_period: "monthly" | "quarterly" | "annual";
  subscription_id: string;
  customer_id: string;
  status: string;
  current_period_start?: string;
  current_period_end: string;
  cancel_at_period_end: boolean;
};

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

  const stripeKey = mustGetEnv("GI_PPI_STRIPE_SECRET_KEY");
  const whsec = mustGetEnv("GI_PPI_STRIPE_WEBHOOK_SECRET");
  const operatorUserId = mustGetEnv("GI_PPI_SYSTEM_OPERATOR_USER_ID");

  // Optional extra guard (your choice)
  const internalSecret = Deno.env.get("GI_PPI_WEBHOOK_INTERNAL_SECRET");
  if (internalSecret) {
    const got = req.headers.get("x-gi-ppi-internal-secret");
    if (got !== internalSecret) return json({ ok: false, error: "UNAUTHORIZED" }, 401);
  }

  const stripe = new Stripe(stripeKey, { apiVersion: "2023-10-16" });

  const sig = req.headers.get("stripe-signature");
  if (!sig) return json({ ok: false, error: "MISSING_STRIPE_SIGNATURE" }, 400);

  const rawBody = await req.text();

  let event: Stripe.Event;
  try {
    event = stripe.webhooks.constructEvent(rawBody, sig, whsec);
  } catch (_e) {
    return json({ ok: false, error: "INVALID_STRIPE_SIGNATURE" }, 400);
  }

  // We sync off subscription events; you can add checkout.session.completed later if you want.
  const allowed = new Set([
    "customer.subscription.created",
    "customer.subscription.updated",
    "customer.subscription.deleted",
    "invoice.payment_failed", // optional
  ]);

  if (!allowed.has(event.type)) {
    return json({ ok: true, ignored: true, event_type: event.type });
  }

  // Extract subscription
  let sub: Stripe.Subscription | null = null;

  if (event.type.startsWith("customer.subscription.")) {
    sub = event.data.object as Stripe.Subscription;
  } else if (event.type === "invoice.payment_failed") {
    const inv = event.data.object as Stripe.Invoice;
    // invoice.subscription can be string or object
    const subId = typeof inv.subscription === "string" ? inv.subscription : inv.subscription?.id;
    if (!subId) return json({ ok: true, ignored: true, reason: "NO_SUBSCRIPTION_ON_INVOICE" });
    sub = await stripe.subscriptions.retrieve(subId);
  }

  if (!sub) return json({ ok: true, ignored: true, reason: "NO_SUB_OBJECT" });

  // Pull metadata you must attach when creating subscriptions.
  // If missing, we fail closed.
  const orgId = sub.metadata?.org_id;
  const planCode = sub.metadata?.plan_code;
  const billingPeriod = sub.metadata?.billing_period as SyncPayload["billing_period"];

  if (!orgId || !planCode || !billingPeriod) {
    return json({
      ok: false,
      error: "MISSING_REQUIRED_METADATA",
      required: ["metadata.org_id", "metadata.plan_code", "metadata.billing_period"],
      got: { org_id: orgId ?? null, plan_code: planCode ?? null, billing_period: billingPeriod ?? null },
    }, 400);
  }

  // Period boundaries
  const cps = sub.current_period_start ? new Date(sub.current_period_start * 1000).toISOString() : undefined;
  const cpe = sub.current_period_end ? new Date(sub.current_period_end * 1000).toISOString() : null;
  if (!cpe) return json({ ok: false, error: "MISSING_CURRENT_PERIOD_END" }, 400);

  const payload: SyncPayload = {
    event_id: event.id,
    event_type: event.type,
    org_id: orgId,
    plan_code: planCode,
    billing_period: billingPeriod,
    subscription_id: sub.id,
    customer_id: typeof sub.customer === "string" ? sub.customer : (sub.customer?.id ?? ""),
    status: sub.status,
    current_period_start: cps,
    current_period_end: cpe,
    cancel_at_period_end: !!sub.cancel_at_period_end,
  };

  if (!payload.customer_id) {
    return json({ ok: false, error: "MISSING_CUSTOMER_ID" }, 400);
  }

  // Call your RPC with claim context so existing admin checks pass
  // We emulate service_role + sub = operator user id
  const rows = await pgCall(
    `
    begin;
      select set_config('request.jwt.claim.role', 'service_role', true);
      select set_config('request.jwt.claim.sub', $1, true);

      select public.gi_ppi_stripe_sync_subscription($2::jsonb, $3::uuid) as result;

    commit;
    `,
    [operatorUserId, JSON.stringify(payload), operatorUserId],
  );

  return json({ ok: true, stripe_event: event.type, result: rows?.[0]?.result ?? null });
});
