// Ai buddy Biz — Chatwoot bridge (Supabase Edge Function, Deno).
//
// Chatwoot (self-hosted, see /chatwoot) posts webhooks here. This function checks the signature, ignores everything
// except new customer messages, and then, depending on BRIDGE_MODE:
//   observe     (default) acknowledge only; never replies
//   test-reply  post one fixed test reply (Phase 1 loop test)
//   live        Claude answers the customer, saves the lead into Ai buddy Biz, and hands over to a person when needed (Phase 2)
//
// Function secrets (supabase secrets set …):
//   CHATWOOT_WEBHOOK_SECRET  the `secret` Chatwoot returns when the webhook is created (required)
//   CHATWOOT_BASE_URL        e.g. https://chat.example.com (test-reply and live)
//   CHATWOOT_API_TOKEN       access token of a Chatwoot agent/bot user (test-reply and live)
//   BRIDGE_MODE              observe | test-reply | live
//   BRIDGE_TEST_REPLY        text for test-reply mode
//   ANTHROPIC_API_KEY        live mode only
//   AI_MODEL                 live mode, optional (default claude-sonnet-5-5)
//   BIZ_DB_SCHEMA            live mode, default "biz" (EAB-QA-Test); "public" for a stand-alone Biz project
//   SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY   provided by Supabase automatically
//
// Deploy WITHOUT Supabase JWT checking, because Chatwoot cannot send a Supabase JWT; the HMAC signature is the
// authentication and every request without a valid one is rejected with 401:
//   supabase functions deploy chatwoot-bridge --no-verify-jwt

import { handleWebhook, type BridgeMode } from "./handler.ts";
import { ChatwootClient } from "./chatwoot-client.ts";
import { RecentIds } from "./events.ts";
import { SupabaseStore } from "./supabase-store.ts";

const recent = new RecentIds();
const notConfigured = () => new Response(JSON.stringify({ error: "not_configured" }), { status: 503, headers: { "Content-Type": "application/json" } });

Deno.serve((req) => {
  const secret = Deno.env.get("CHATWOOT_WEBHOOK_SECRET");
  if (!secret) {
    console.error("CHATWOOT_WEBHOOK_SECRET is not set");
    return notConfigured();
  }

  const raw = Deno.env.get("BRIDGE_MODE");
  const mode: BridgeMode = raw === "live" ? "live" : raw === "test-reply" ? "test-reply" : "observe";
  const baseUrl = Deno.env.get("CHATWOOT_BASE_URL") ?? "";
  const token = Deno.env.get("CHATWOOT_API_TOKEN") ?? "";
  if (mode !== "observe" && (!baseUrl || !token)) {
    console.error(`${mode} mode needs CHATWOOT_BASE_URL and CHATWOOT_API_TOKEN`);
    return notConfigured();
  }

  const client = new ChatwootClient(baseUrl || "http://invalid.local", token);
  const log = (line: string) => console.log(`[chatwoot-bridge] ${line}`);

  let live;
  if (mode === "live") {
    const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
    const url = Deno.env.get("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!anthropicKey || !url || !serviceKey) {
      console.error("live mode needs ANTHROPIC_API_KEY, SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY");
      return notConfigured();
    }
    live = {
      store: new SupabaseStore(url, serviceKey, Deno.env.get("BIZ_DB_SCHEMA") ?? "biz"),
      client,
      fetchFn: (i: string, init?: RequestInit) => fetch(i, init),
      anthropicKey,
      model: Deno.env.get("AI_MODEL") ?? "claude-sonnet-5-5",
      log,
    };
  }

  return handleWebhook(req, {
    webhookSecret: secret,
    mode,
    testReply: Deno.env.get("BRIDGE_TEST_REPLY") ?? "Thanks for your message. This is an automatic test reply from Ai buddy Biz.",
    nowSeconds: () => Math.floor(Date.now() / 1000),
    recent,
    client,
    log,
    live,
  });
});
