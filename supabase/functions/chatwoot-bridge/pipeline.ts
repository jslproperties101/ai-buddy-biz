// Live mode: what happens to one new customer message. Order matters:
//   claim the event (de-dupe) → check switches and limits → ask Claude → save the lead → send the reply → record the turn.
// Anything that must never be lost (the customer's lead) is saved before the reply goes out, and a failed save does
// not stop the reply. A failed reply releases the claim so Chatwoot's retry can run again.

import type { IncomingMessage } from "./events.ts";
import type { BridgeStore, ClaimResult, LeadInput } from "./store.ts";
import { buildMessages, buildSystemPrompt, costUsd, decide, HOLDING_REPLY, type ChatTurn, type Decision, type FetchLike } from "./ai.ts";

export type PipelineClient = {
  sendMessage: (accountId: number, conversationId: number, content: string, opts?: { private?: boolean }) => Promise<unknown>;
  getRecentTurns: (accountId: number, conversationId: number, limit?: number) => Promise<ChatTurn[]>;
  setStatus: (accountId: number, conversationId: number, status: "open" | "pending" | "resolved") => Promise<unknown>;
};

export type LiveDeps = {
  store: BridgeStore;
  client: PipelineClient;
  fetchFn: FetchLike;
  anthropicKey: string;
  model: string;
  log: (line: string) => void;
};

export type PipelineResult = { status: number; body: Record<string, unknown> };

const ok = (body: Record<string, unknown>): PipelineResult => ({ status: 200, body });

export function leadInputFrom(d: Decision, m: IncomingMessage): LeadInput | null {
  const l = d.lead;
  const values: Record<string, string | boolean> = {};
  if (l.propertyType) values.property_type = l.propertyType;
  if (l.budget) values.budget = l.budget;
  if (l.area) values.area = l.area;
  if (l.timeline) values.timeline = l.timeline;
  if (l.mm2hInterest === true) values.mm2h_interest = true;

  const lead: LeadInput = {
    // The WhatsApp/Chatwoot profile is more reliable than anything the model heard; the model fills the gaps.
    name: l.name || m.contactName || "",
    phone: m.contactPhone || l.phone,
    email: l.email,
    interest: l.interest,
    summary: l.summary,
    language: d.language ?? "",
    source: m.channel?.includes("Whatsapp") ? "whatsapp" : "chat",
    values,
  };
  const hasSignal = lead.interest || lead.summary || Object.keys(values).length > 0 || lead.email || l.name || l.phone;
  return hasSignal ? lead : null;
}

async function bestEffort(deps: LiveDeps, what: string, fn: () => Promise<unknown>) {
  try { await fn(); } catch (e) { deps.log(`${what} failed: ${(e as Error).message}`); }
}

async function handOver(deps: LiveDeps, m: IncomingMessage, note: string) {
  await bestEffort(deps, "handover note", () => deps.client.sendMessage(m.accountId, m.conversationId, note, { private: true }));
  await bestEffort(deps, "handover status", () => deps.client.setStatus(m.accountId, m.conversationId, "open"));
}

export async function processIncoming(m: IncomingMessage, dedupeKey: string, deps: LiveDeps): Promise<PipelineResult> {
  const claim = await deps.store.claimEvent(m.accountId, dedupeKey);
  if (!claim.ok) {
    if (claim.reason !== "duplicate") deps.log(`not handled: ${claim.reason} (chatwoot account ${m.accountId})`);
    return ok({ handled: false, reason: claim.reason });
  }
  try {
    return await processClaimed(m, dedupeKey, deps, claim);
  } catch (e) {
    // Something unexpected (for example the database) failed before we answered: free the claim so Chatwoot's retry
    // is not mistaken for a duplicate and the customer's message is not lost.
    await deps.store.releaseEvent(dedupeKey).catch(() => {});
    throw e;
  }
}

async function processClaimed(m: IncomingMessage, dedupeKey: string, deps: LiveDeps, claim: Extract<ClaimResult, { ok: true }>): Promise<PipelineResult> {
  const { store, client, log } = deps;
  const { tenantId } = claim;
  if (!claim.botEnabled) return ok({ handled: false, reason: "bot_disabled" });
  if (m.hasAssignee) return ok({ handled: false, reason: "human_assigned" });

  const conv = await store.getConversation(m.accountId, m.conversationId);
  if (conv?.handedOver) return ok({ handled: false, reason: "handed_over" });

  const turn = (replied: boolean, handover: boolean, reason: string | null, d?: Decision) =>
    bestEffort(deps, "record turn", () => store.recordTurn({
      tenantId, accountId: m.accountId, conversationId: m.conversationId, replied, handover, reason,
      model: d?.model ?? deps.model, inputTokens: d?.usage.input ?? 0, outputTokens: d?.usage.output ?? 0, costUsd: d ? costUsd(d.model, d.usage) : 0,
    }));

  // Cheap limits first: never spend AI money once the plan or the per-conversation cap is used up.
  const ctx = await store.getContext(tenantId);
  const limitReason = ctx.used >= ctx.limit ? "AI plan limit reached this month" : (conv?.botReplies ?? 0) >= claim.maxBotReplies ? "Bot reply limit for this conversation reached" : null;
  if (limitReason) {
    try { await client.sendMessage(m.accountId, m.conversationId, HOLDING_REPLY); }
    catch (e) { await store.releaseEvent(dedupeKey).catch(() => {}); log(`holding reply failed: ${(e as Error).message}`); return { status: 502, body: { handled: false, error: "reply_failed" } }; }
    await handOver(deps, m, `Bot stopped: ${limitReason}. Please reply to the customer.`);
    await turn(true, true, limitReason);
    return ok({ handled: true, action: "handed_over", reason: limitReason });
  }

  // History is a nice-to-have: without it Claude still sees the current message.
  let history: ChatTurn[] = [];
  try { history = await client.getRecentTurns(m.accountId, m.conversationId, 12); }
  catch (e) { log(`history unavailable: ${(e as Error).message}`); }

  let d: Decision;
  try {
    d = await decide({ fetchFn: deps.fetchFn, apiKey: deps.anthropicKey, model: deps.model, system: buildSystemPrompt(ctx), messages: buildMessages(history, m.content) });
  } catch (e) {
    log(`AI call failed: ${(e as Error).message}`);
    try { await client.sendMessage(m.accountId, m.conversationId, HOLDING_REPLY); } catch { /* the private note below still alerts the team */ }
    await handOver(deps, m, "Bot stopped: the AI service failed. Please reply to the customer.");
    await turn(false, true, "AI service failed");
    return ok({ handled: true, action: "handed_over", reason: "ai_error" });
  }

  // Save the lead before replying so a failed reply never loses what the customer told us.
  const lead = leadInputFrom(d, m);
  if (lead) await bestEffort(deps, "lead save", () => store.upsertLead(tenantId, m.accountId, m.conversationId, lead));

  try {
    await client.sendMessage(m.accountId, m.conversationId, d.reply);
  } catch (e) {
    log(`reply failed: ${(e as Error).message}`);
    await store.releaseEvent(dedupeKey).catch(() => {});
    await bestEffort(deps, "record usage", () => store.recordTurn({
      tenantId, accountId: m.accountId, conversationId: m.conversationId, replied: false, handover: false, reason: null,
      model: d.model, inputTokens: d.usage.input, outputTokens: d.usage.output, costUsd: costUsd(d.model, d.usage),
    }));
    return { status: 502, body: { handled: false, error: "reply_failed" } };
  }

  if (d.handover) await handOver(deps, m, `Bot handed over: ${d.handoverReason ?? "needs a person"}.${d.lead.summary ? ` Summary: ${d.lead.summary}` : ""}`);
  await turn(true, d.handover, d.handoverReason, d);
  return ok({ handled: true, action: d.handover ? "replied_and_handed_over" : "replied" });
}
