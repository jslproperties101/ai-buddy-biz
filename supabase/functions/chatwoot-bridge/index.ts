// Ai buddy Biz — Chatwoot bridge (Supabase Edge Function, Deno). Phase 1 skeleton + Phase 2 draft mode.
//
// Chatwoot (self-hosted, see /chatwoot) posts webhooks here. This function checks the signature, ignores everything
// except new customer messages, and — only in test-reply mode — posts a fixed test reply so the whole loop can be
// proven before WhatsApp or Claude are involved.
//
// Function secrets (supabase secrets set …):
//   CHATWOOT_WEBHOOK_SECRET  the `secret` Chatwoot returns when the webhook is created (required)
//   CHATWOOT_BASE_URL        e.g. https://chat.example.com (required for test-reply mode)
//   CHATWOOT_API_TOKEN       access token of a Chatwoot agent/bot user (required for test-reply mode)
//   BRIDGE_MODE              "observe" (default, never replies), "test-reply" (Phase 1), or "draft" (Phase 2)
//   draft mode also needs:   CHATWOOT_API_TOKEN, CHATWOOT_BASE_URL, ANTHROPIC_API_KEY
//                            (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase itself)
//   CLAUDE_MODEL             optional, default claude-sonnet-5-5
//   BIZ_DB_SCHEMA            optional, default biz
//   BRIDGE_TEST_REPLY        text for test-reply mode
//
// Deploy WITHOUT Supabase JWT checking, because Chatwoot cannot send a Supabase JWT; the HMAC signature is the
// authentication and every request without a valid one is rejected with 401:
//   supabase functions deploy chatwoot-bridge --no-verify-jwt

import { handleWebhook, type BridgeMode } from "./handler.ts";
import { ChatwootClient } from "./chatwoot-client.ts";
import { RecentIds } from "./events.ts";
import { SupabaseStore } from "./store.ts";
import { ClaudeDrafter } from "./drafter.ts";

const recent = new RecentIds();

Deno.serve((req) => {
  const secret = Deno.env.get("CHATWOOT_WEBHOOK_SECRET");
  if (!secret) {
    console.error("CHATWOOT_WEBHOOK_SECRET is not set");
    return new Response(JSON.stringify({ error: "not_configured" }), { status: 503, headers: { "Content-Type": "application/json" } });
  }

  const m = Deno.env.get("BRIDGE_MODE");
  const mode: BridgeMode = m === "test-reply" ? "test-reply" : m === "draft" ? "draft" : "observe";
  const baseUrl = Deno.env.get("CHATWOOT_BASE_URL") ?? "";
  const token = Deno.env.get("CHATWOOT_API_TOKEN") ?? "";
  if (mode !== "observe" && (!baseUrl || !token)) {
    console.error(`${mode} mode needs CHATWOOT_BASE_URL and CHATWOOT_API_TOKEN`);
    return new Response(JSON.stringify({ error: "not_configured" }), { status: 503, headers: { "Content-Type": "application/json" } });
  }
  let store: SupabaseStore | undefined;
  let drafter: ClaudeDrafter | undefined;
  if (mode === "draft") {
    const url = Deno.env.get("SUPABASE_URL") ?? "";
    const key = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const claude = Deno.env.get("ANTHROPIC_API_KEY") ?? "";
    if (!url || !key || !claude) {
      console.error("draft mode needs SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY and ANTHROPIC_API_KEY");
      return new Response(JSON.stringify({ error: "not_configured" }), { status: 503, headers: { "Content-Type": "application/json" } });
    }
    store = new SupabaseStore(url, key, Deno.env.get("BIZ_DB_SCHEMA") ?? "biz");
    drafter = new ClaudeDrafter(claude, Deno.env.get("CLAUDE_MODEL") ?? "claude-sonnet-5-5", (a, q) => store!.findProducts(a, q));
  }

  return handleWebhook(req, {
    webhookSecret: secret,
    mode,
    testReply: Deno.env.get("BRIDGE_TEST_REPLY") ?? "Thanks for your message. This is an automatic test reply from Ai buddy Biz.",
    nowSeconds: () => Math.floor(Date.now() / 1000),
    recent,
    client: new ChatwootClient(baseUrl || "http://invalid.local", token),
    store,
    drafter,
    log: (line) => console.log(`[chatwoot-bridge] ${line}`),
  });
});
