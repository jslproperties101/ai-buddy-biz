// Request handler for the Chatwoot → Ai buddy Biz bridge. Dependencies are injected so it can be tested without
// a server. Modes:
//   observe     verify, classify, de-duplicate, log. Never posts anything.
//   test-reply  (Phase 1) post one fixed public test reply.
//   draft       (Phase 2) save the customer as a lead (once per conversation), ask Claude for a suggested reply using the
//               business's products and prices, and post it as a PRIVATE NOTE only. Nothing is ever sent to the customer.

import { verifyChatwootSignature } from "./signature.ts";
import { classifyEvent, type IncomingMessage, type RecentIds } from "./events.ts";
import type { BridgeStore } from "./store.ts";
import type { Drafter, HistoryLine } from "./drafter.ts";

export type BridgeMode = "observe" | "test-reply" | "draft";

export const DRAFT_PREFIX = "Suggested reply (draft, NOT sent to the customer):\n\n";

export type BridgeDeps = {
  webhookSecret: string;
  mode: BridgeMode;
  testReply: string;
  nowSeconds: () => number;
  recent: RecentIds;
  client: {
    sendMessage: (accountId: number, conversationId: number, content: string, opts?: { private?: boolean }) => Promise<unknown>;
    listMessages?: (accountId: number, conversationId: number) => Promise<HistoryLine[]>;
  };
  store?: BridgeStore;   // draft mode only
  drafter?: Drafter;     // draft mode only
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
  if (deps.mode === "draft") return await handleDraft(m, dedupeKey, deps);
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

async function handleDraft(m: IncomingMessage, key: string, deps: BridgeDeps): Promise<Response> {
  const { store, drafter } = deps;
  if (!store || !drafter) return json({ error: "not_configured" }, 503);

  // The database decides whether this delivery is new, a retry of one that failed, or a duplicate.
  let claim;
  try {
    claim = await store.claim(key);
  } catch (e) {
    deps.log(`claim failed: ${(e as Error).message}`);
    return json({ handled: false, error: "store_unavailable" }, 502);
  }
  if (claim === "duplicate") return json({ handled: false, reason: "duplicate" });

  try {
    // 1. Lead. Never blocks the draft: if it fails it is simply tried again on the customer's next message.
    try {
      const lead = await store.saveLead(m.accountId, m.conversationId, {
        name: m.contactName ?? "", phone: m.contactPhone ?? "", email: m.contactEmail ?? "", message: m.content.slice(0, 2000), interest: m.content.slice(0, 160),
      });
      if (lead.saved) deps.log(`lead saved for conversation ${m.conversationId}`);
    } catch (e) {
      deps.log(`lead save failed: ${(e as Error).message}`);
    }

    // 2. Context. If the history cannot be read, the draft is written from the latest message alone.
    let history: HistoryLine[] = [];
    try {
      history = (await deps.client.listMessages?.(m.accountId, m.conversationId)) ?? [];
      // the newest customer line is the message itself; do not repeat it
      if (history.length && history[history.length - 1].from === "customer" && history[history.length - 1].text === m.content.slice(0, 500)) history = history.slice(0, -1);
    } catch (e) {
      deps.log(`history unavailable: ${(e as Error).message}`);
    }

    // 3. Draft, as a private note.
    const text = await drafter.draft({ accountId: m.accountId, customerName: m.contactName, message: m.content, history });
    if (text === "") {
      await store.finish(key, true);
      return json({ handled: true, action: "no_draft" });
    }
    await deps.client.sendMessage(m.accountId, m.conversationId, DRAFT_PREFIX + text, { private: true });
    await store.finish(key, true);
    deps.log(`draft posted as private note in conversation ${m.conversationId}`);
    return json({ handled: true, action: "draft_posted" });
  } catch (e) {
    deps.log(`draft failed: ${(e as Error).message}`);
    try { await store.finish(key, false); } catch { /* the 2-minute takeover rule covers this */ }
    return json({ handled: false, error: "draft_failed" }, 502);
  }
}
