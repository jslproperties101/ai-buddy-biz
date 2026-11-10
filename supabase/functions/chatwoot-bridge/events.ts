// Decide what the bridge should do with a Chatwoot webhook payload.
// Pure functions only — no network, no clock — so they are easy to test.

export type IncomingMessage = {
  accountId: number;
  conversationId: number;
  messageId: number;
  content: string;
  channel: string | null; // e.g. "Channel::Whatsapp", "Channel::WebWidget"
  contactId: number | null;
  contactName: string | null;
  contactPhone: string | null;
  conversationStatus: string | null;
  hasAssignee: boolean; // a human agent already owns the conversation
};

export type Classification =
  | { kind: "incoming_message"; message: IncomingMessage }
  | { kind: "ignored"; reason: string };

// deno-lint-ignore no-explicit-any
type Json = any;

function asInt(v: unknown): number | null {
  return typeof v === "number" && Number.isInteger(v) ? v : null;
}

export function classifyEvent(payload: Json): Classification {
  if (!payload || typeof payload !== "object") return { kind: "ignored", reason: "payload_not_object" };

  if (payload.event !== "message_created") return { kind: "ignored", reason: `event_${String(payload.event ?? "unknown")}` };

  // Only customer messages. Our own replies, agent replies and bot replies come back as "outgoing"/"template"
  // and must never trigger another reply (that would loop).
  if (payload.message_type !== "incoming") return { kind: "ignored", reason: `message_type_${String(payload.message_type ?? "unknown")}` };

  if (payload.private === true) return { kind: "ignored", reason: "private_note" };

  const messageId = asInt(payload.id);
  const accountId = asInt(payload.account?.id);
  const conversationId = asInt(payload.conversation?.id);
  if (messageId === null || accountId === null || conversationId === null) return { kind: "ignored", reason: "missing_ids" };

  const content = typeof payload.content === "string" ? payload.content.trim() : "";
  if (content === "") return { kind: "ignored", reason: "no_text" }; // attachments only, for now

  const sender = payload.sender && typeof payload.sender === "object" ? payload.sender : {};
  return {
    kind: "incoming_message",
    message: {
      accountId,
      conversationId,
      messageId,
      content,
      channel: typeof payload.conversation?.channel === "string" ? payload.conversation.channel : null,
      contactId: asInt(sender.id),
      contactName: typeof sender.name === "string" ? sender.name : null,
      contactPhone: typeof sender.phone_number === "string" ? sender.phone_number : null,
      conversationStatus: typeof payload.conversation?.status === "string" ? payload.conversation.status : null,
      hasAssignee: payload.conversation?.meta?.assignee != null,
    },
  };
}

// Chatwoot can deliver the same webhook more than once. This is a best-effort, in-memory guard for one running
// instance only; Phase 2 replaces it with a database table so it also survives restarts and multiple instances.
export class RecentIds {
  private seen = new Map<string, number>();
  private max: number;
  constructor(max = 500) {
    this.max = max;
  }

  /** Returns true if the id was already seen (a duplicate); records it otherwise. */
  checkAndAdd(id: string): boolean {
    if (this.seen.has(id)) return true;
    this.seen.set(id, Date.now());
    if (this.seen.size > this.max) {
      const oldest = this.seen.keys().next().value;
      if (oldest !== undefined) this.seen.delete(oldest);
    }
    return false;
  }
}
