// supabase/functions/gi-ppi-chat-evaluate/index.ts
import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import postgres from "https://deno.land/x/postgresjs@v3.4.5/mod.js";

function json(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

// Minimal JWT payload decode (no verification here; Supabase verifies before your code runs)
// We only need sub (user id).
function getJwtSub(authHeader: string | null): string | null {
  if (!authHeader) return null;
  const m = authHeader.match(/^Bearer\s+(.+)$/i);
  if (!m) return null;
  const token = m[1];
  const parts = token.split(".");
  if (parts.length < 2) return null;
  try {
    const payload = JSON.parse(atob(parts[1].replace(/-/g, "+").replace(/_/g, "/")));
    return typeof payload.sub === "string" ? payload.sub : null;
  } catch (_) {
    return null;
  }
}

serve(async (req) => {
  const startedAt = Date.now();
  let sql: any = null;

  // for logging
  let org_id: string | null = null;
  let user_id: string | null = null;

  try {
    if (req.method !== "POST") return json(405, { ok: false, error: "METHOD_NOT_ALLOWED" });

    const dbUrl = Deno.env.get("GI_PPI_DB_URL");
    if (!dbUrl) return json(500, { ok: false, error: "GI_PPI_DB_URL_NOT_SET" });

    const auth = req.headers.get("authorization");
    user_id = getJwtSub(auth);
    if (!user_id) return json(401, { ok: false, error: "AUTH_REQUIRED" });

    const body = await req.json().catch(() => null);
    if (!body || typeof body !== "object") return json(400, { ok: false, error: "BODY_REQUIRED" });

    org_id = typeof (body as any).org_id === "string" ? (body as any).org_id : null;
    const prompt = typeof (body as any).prompt === "string" ? (body as any).prompt : null;

    if (!org_id) return json(400, { ok: false, error: "ORG_ID_REQUIRED" });
    if (!prompt || !prompt.trim()) return json(400, { ok: false, error: "PROMPT_REQUIRED" });

    sql = postgres(dbUrl, { max: 1, idle_timeout: 5 });

    // HARD gate: pilot/admin-only + plan flag + consent + entitlement
    const gateRows = await sql`
      select public.gi_ppi_edge_can_use_conversation(
        ${org_id}::uuid,
        ${user_id}::uuid
      ) as allowed
    `;
    const allowed = !!gateRows?.[0]?.allowed;

    if (!allowed) {
      // Log deny
      await sql`
        select public.gi_ppi_edge_log_event(
          ${JSON.stringify({
            event_type: "conversation_attempt",
            org_id,
            user_id,
            ok: false,
            reason: "CONVERSATION_NOT_ALLOWED",
            metadata: { ms: Date.now() - startedAt },
          })}::jsonb
        )
      `;
      return json(403, { ok: false, error: "CONVERSATION_NOT_ALLOWED" });
    }

    // If allowed, log allow
    await sql`
      select public.gi_ppi_edge_log_event(
        ${JSON.stringify({
          event_type: "conversation_attempt",
          org_id,
          user_id,
          ok: true,
          reason: "CONVERSATION_ALLOWED",
          metadata: { ms: Date.now() - startedAt },
        })}::jsonb
      )
    `;

    // At this point you can:
    // - call your deterministic evaluator RPCs
    // - optionally call an AI model
    // For now we return a stub so you can prove gating is perfect.

    return json(200, {
      ok: true,
      mode: "pilot",
      note: "Conversation gate passed. Wire evaluator/AI next.",
    });
  } catch (e) {
    try {
      if (sql) {
        await sql`
          select public.gi_ppi_edge_log_event(
            ${JSON.stringify({
              event_type: "conversation_attempt",
              org_id,
              user_id,
              ok: false,
              reason: String((e as any)?.message ?? "INTERNAL"),
              metadata: { ms: Date.now() - startedAt },
            })}::jsonb
          )
        `;
      }
    } catch (_) {}

    return json(500, { ok: false, error: "INTERNAL", message: String((e as any)?.message ?? e) });
  } finally {
    try { if (sql) await sql.end(); } catch (_) {}
  }
});
