// Request handler for the Chatwoot → Ai buddy Biz bridge. Dependencies are injected so it can be tested without
// a server. Phase 1 scope: verify, classify, de-duplicate, and (in test-reply mode only) post a fixed test reply.
// Claude replies and lead capture arrive in Phase 2.

import { verifyChatwootSignature } from "./signature.ts";
import { classifyEvent, type RecentIds } from "./events.ts";

export type BridgeMode = "observe" | "test-reply";

export type BridgeDeps = {
  webhookSecret: string;
  mode: BridgeMode;
  testReply: string;
  nowSeconds: () => number;
  recent: RecentIds;
  client: { sendMessage: (accountId: number, conversationId: number, content: string, opts?: { private?: boolean }) => Promise<unknown> };
  log: (line: string) => void;
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

export async function handleWebhook(req: Request, deps: BridgeDeps): Promise<Response> {
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  // Read the body once, as text: the signature is computed over the exact raw bytes Chatwoot sent.
  const rawBody = await req.text();

  const sig = await verifyChatwootSignature({
    secret: deps.webhookSecret,
    timestampHeader: req.headers.get("X-Chatwoot-Timestamp"),
    signatureHeader: req.headers.get("X-Chatwoot-Signature"),
    rawBody,
    nowSeconds: deps.nowSeconds(),
  });
  if (!sig.ok) {
    deps.log(`rejected webhook: ${sig.reason}`);
    return json({ error: "unauthorized", reason: sig.reason }, 401);
  }

  let payload: unknown;
  try {
    payload = JSON.parse(rawBody);
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const c = classifyEvent(payload);
  if (c.kind === "ignored") return json({ handled: false, reason: c.reason });

  // Duplicate delivery guard. Prefer Chatwoot's delivery id; fall back to account+message id.
  const m = c.message;
  const dedupeKey = req.headers.get("X-Chatwoot-Delivery") ?? `${m.accountId}:${m.messageId}`;
  if (deps.recent.checkAndAdd(dedupeKey)) return json({ handled: false, reason: "duplicate" });

  if (deps.mode === "observe") {
    deps.log(`observed incoming message ${m.messageId} in conversation ${m.conversationId}`);
    return json({ handled: true, action: "observed" });
  }

  try {
    await deps.client.sendMessage(m.accountId, m.conversationId, deps.testReply);
    deps.log(`test reply sent to conversation ${m.conversationId}`);
    return json({ handled: true, action: "test_reply_sent" });
  } catch (e) {
    deps.log(`test reply failed: ${(e as Error).message}`);
    // 502 so Chatwoot's retry/alerting can see it; the dedupe key is already recorded, so a retry will be skipped
    // in this instance. Phase 2 makes this properly retryable via the database queue.
    return json({ handled: false, error: "reply_failed" }, 502);
  }
}
