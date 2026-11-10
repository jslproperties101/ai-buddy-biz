// Live mode: what happens to one new customer message. Order matters:
//   claim the event (de-dupe) → check switches and limits → ask Claude → save the lead → send the reply → record the turn.
// Anything that must never be lost (the customer's lead) is saved before the reply goes out, and a failed save does
// not stop the reply. A failed reply releases the claim so Chatwoot's retry can run again.

import type { IncomingMessage } from "./events.ts";
import type { BridgeStore, ClaimResult, LeadInput } from "./store.ts";
import { buildMessages, buildSystemPrompt, costUsd, decide, HOLDING_REPLY, type ChatTurn, type Decision, type FetchLike, type ToolRunner } from "./ai.ts";

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
  listingTools?: boolean; // Phase 3: let Claude search listings and request viewings. Default on; false = Phase 2 behaviour.
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

const VIEWING_HINTS: Record<string, string> = {
  bad_time: "Ask the customer for a specific date and time.",
  too_soon: "The time must be at least 2 hours from now. Ask for a later time.",
  too_far: "The time must be within the next 90 days. Ask for an earlier date.",
  too_many_requests: "Enough viewing requests were already made in this chat. Tell the customer a team member will arrange it, and hand over.",
};
const clampInt = (v: unknown, lo: number, hi: number, dflt: number) => (typeof v === "number" && Number.isInteger(v) ? Math.min(hi, Math.max(lo, v)) : dflt);
const text = (v: unknown, max: number) => (typeof v === "string" ? v.trim().slice(0, max) : "");

/** The two tools Claude may use in live mode. They only read approved listings and create a PENDING viewing request. */
export function makeToolRunner(m: IncomingMessage, tenantId: string, deps: LiveDeps): ToolRunner {
  return {
    async run(name, input) {
      if (name === "search_listings") {
        const listings = await deps.store.searchListings(tenantId, text(input.query, 100), clampInt(input.limit, 1, 8, 5));
        return { result: listings.length > 0 ? { listings } : { listings: [], note: "No matching listings. Do not invent any; offer to have a team member help." } };
      }

      if (name === "request_viewing") {
        const start = text(input.start_local, 20);
        if (!/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$/.test(start)) return { result: { ok: false, reason: "bad_time", hint: VIEWING_HINTS.bad_time } };

        // The request needs a contact on file: save one from what we know before asking for the viewing.
        try {
          await deps.store.upsertLead(tenantId, m.accountId, m.conversationId, {
            name: text(input.name, 120) || m.contactName || "", phone: m.contactPhone ?? "", email: "", interest: "", summary: "",
            language: "", source: m.channel?.includes("Whatsapp") ? "whatsapp" : "chat", values: {},
          });
        } catch (e) {
          deps.log(`viewing: contact save failed: ${(e as Error).message}`);
          return { result: { ok: false, reason: "could_not_save", hint: "Tell the customer a team member will arrange the viewing, and hand over." } };
        }

        const r = await deps.store.requestViewing(tenantId, m.accountId, m.conversationId, {
          ref: text(input.property_ref, 60), startLocal: start, notes: text(input.notes, 300),
        });
        if (!r.ok) {
          return { result: { ok: false, reason: r.reason, hint: VIEWING_HINTS[r.reason] ?? "Tell the customer a team member will arrange the viewing, and hand over." } };
        }
        return {
          result: { ok: true, status: "pending: the team must confirm", start_local: r.startLocal, hint: "Tell the customer the team will confirm. Do not say it is booked or confirmed. Set handover to true." },
          viewingBooked: true,
        };
      }
      return { result: { error: "unknown tool" } };
    },
  };
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
    d = await decide({
      fetchFn: deps.fetchFn, apiKey: deps.anthropicKey, model: deps.model, system: buildSystemPrompt(ctx), messages: buildMessages(history, m.content),
      tools: deps.listingTools === false ? undefined : makeToolRunner(m, tenantId, deps),
    });
  } catch (e) {
    log(`AI call failed: ${(e as Error).message}`);
    try { await client.sendMessage(m.accountId, m.conversationId, HOLDING_REPLY); } catch { /* the private note below still alerts the team */ }
    await handOver(deps, m, "Bot stopped: the AI service failed. Please reply to the customer.");
    await turn(false, true, "AI service failed");
    return ok({ handled: true, action: "handed_over", reason: "ai_error" });
  }

  // A viewing request always needs a person, whatever Claude decided.
  if (d.viewingRequested && !d.handover) {
    d.handover = true;
    d.handoverReason = "Viewing requested: please confirm with the customer";
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
  return ok({ handled: true, action: d.handover ? "replied_and_handed_over" : "replied", ...(d.toolsUsed.length > 0 ? { tools: d.toolsUsed } : {}) });
}
