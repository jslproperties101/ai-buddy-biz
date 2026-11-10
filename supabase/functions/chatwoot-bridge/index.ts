// Ai buddy Biz — Chatwoot bridge (Supabase Edge Function, Deno). Phase 1 skeleton.
//
// Chatwoot (self-hosted, see /chatwoot) posts webhooks here. This function checks the signature, ignores everything
// except new customer messages, and — only in test-reply mode — posts a fixed test reply so the whole loop can be
// proven before WhatsApp or Claude are involved.
//
// Function secrets (supabase secrets set …):
//   CHATWOOT_WEBHOOK_SECRET  the `secret` Chatwoot returns when the webhook is created (required)
//   CHATWOOT_BASE_URL        e.g. https://chat.example.com (required for test-reply mode)
//   CHATWOOT_API_TOKEN       access token of a Chatwoot agent/bot user (required for test-reply mode)
//   BRIDGE_MODE              "observe" (default, never replies) or "test-reply"
//   BRIDGE_TEST_REPLY        text for test-reply mode
//
// Deploy WITHOUT Supabase JWT checking, because Chatwoot cannot send a Supabase JWT; the HMAC signature is the
// authentication and every request without a valid one is rejected with 401:
//   supabase functions deploy chatwoot-bridge --no-verify-jwt

import { handleWebhook, type BridgeMode } from "./handler.ts";
import { ChatwootClient } from "./chatwoot-client.ts";
import { RecentIds } from "./events.ts";

const recent = new RecentIds();

Deno.serve((req) => {
  const secret = Deno.env.get("CHATWOOT_WEBHOOK_SECRET");
  if (!secret) {
    console.error("CHATWOOT_WEBHOOK_SECRET is not set");
    return new Response(JSON.stringify({ error: "not_configured" }), { status: 503, headers: { "Content-Type": "application/json" } });
  }

  const mode: BridgeMode = Deno.env.get("BRIDGE_MODE") === "test-reply" ? "test-reply" : "observe";
  const baseUrl = Deno.env.get("CHATWOOT_BASE_URL") ?? "";
  const token = Deno.env.get("CHATWOOT_API_TOKEN") ?? "";
  if (mode === "test-reply" && (!baseUrl || !token)) {
    console.error("test-reply mode needs CHATWOOT_BASE_URL and CHATWOOT_API_TOKEN");
    return new Response(JSON.stringify({ error: "not_configured" }), { status: 503, headers: { "Content-Type": "application/json" } });
  }

  return handleWebhook(req, {
    webhookSecret: secret,
    mode,
    testReply: Deno.env.get("BRIDGE_TEST_REPLY") ?? "Thanks for your message. This is an automatic test reply from Ai buddy Biz.",
    nowSeconds: () => Math.floor(Date.now() / 1000),
    recent,
    client: new ChatwootClient(baseUrl || "http://invalid.local", token),
    log: (line) => console.log(`[chatwoot-bridge] ${line}`),
  });
});
