// Real BridgeStore: calls the chat_* functions from supabase/migrations/0012_chat.sql with the service role.
// Deno only (imports from esm.sh), so it is not loaded by the Node unit tests; the functions it calls are tested
// against a real Postgres (see the Phase 2 report).

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
import type { BridgeStore, BusinessContext, ClaimResult, LeadInput, Listing, ViewingResult } from "./store.ts";

export class SupabaseStore implements BridgeStore {
  private db: SupabaseClient;

  // Ai buddy Biz tables live in schema "biz" of the EAB-QA-Test project; BIZ_DB_SCHEMA=public for a stand-alone project.
  constructor(url: string, serviceKey: string, schema: string) {
    this.db = createClient(url, serviceKey, { db: { schema }, auth: { persistSession: false } });
  }

  private async rpc(fn: string, args: Record<string, unknown>) {
    const { data, error } = await this.db.rpc(fn, args);
    if (error) throw new Error(`${fn}: ${error.message}`);
    return data;
  }

  async claimEvent(accountId: number, key: string): Promise<ClaimResult> {
    const d = await this.rpc("chat_claim_event", { p_account: accountId, p_key: key });
    if (!d?.ok) return { ok: false, reason: String(d?.reason ?? "unknown") };
    return { ok: true, tenantId: d.tenant_id, botEnabled: d.bot_enabled === true, maxBotReplies: Number(d.max_bot_replies ?? 6) };
  }

  async releaseEvent(key: string): Promise<void> {
    await this.rpc("chat_release_event", { p_key: key });
  }

  async getContext(tenantId: string): Promise<BusinessContext> {
    const d = await this.rpc("chat_context", { p_tenant: tenantId });
    return { business: d?.business ?? "our business", country: d?.country ?? "MY", currency: d?.currency ?? "MYR", plan: d?.plan ?? "free", used: Number(d?.used ?? 0), limit: Number(d?.limit ?? 0) };
  }

  async getConversation(accountId: number, conversationId: number) {
    const d = await this.rpc("chat_get_conversation", { p_account: accountId, p_conversation: conversationId });
    if (!d || d.chatwoot_conversation_id === undefined) return null;
    return { botReplies: Number(d.bot_replies ?? 0), handedOver: d.handed_over === true };
  }

  async upsertLead(tenantId: string, accountId: number, conversationId: number, lead: LeadInput) {
    const d = await this.rpc("chat_upsert_lead", {
      p_tenant: tenantId, p_account: accountId, p_conversation: conversationId,
      p: { name: lead.name, phone: lead.phone, email: lead.email, interest: lead.interest, summary: lead.summary, language: lead.language, source: lead.source, values: lead.values },
    });
    return { contactId: d.contact_id as string, dealId: d.deal_id as string, created: d.created === true };
  }

  async searchListings(tenantId: string, query: string, limit: number): Promise<Listing[]> {
    const d = await this.rpc("chat_search_listings", { p_tenant: tenantId, p_query: query, p_limit: limit });
    return Array.isArray(d) ? (d as Listing[]) : [];
  }

  async requestViewing(tenantId: string, accountId: number, conversationId: number, req: { ref: string; startLocal: string; notes: string }): Promise<ViewingResult> {
    const d = await this.rpc("chat_request_viewing", {
      p_tenant: tenantId, p_account: accountId, p_conversation: conversationId,
      p: { ref: req.ref, start_local: req.startLocal, notes: req.notes },
    });
    if (!d?.ok) return { ok: false, reason: String(d?.reason ?? "unknown") };
    return { ok: true, duplicate: d.duplicate === true, bookingId: String(d.booking_id), startLocal: String(d.start_local) };
  }

  async recordTurn(a: Parameters<BridgeStore["recordTurn"]>[0]): Promise<void> {
    await this.rpc("chat_record_turn", {
      p_tenant: a.tenantId, p_account: a.accountId, p_conversation: a.conversationId, p_replied: a.replied, p_handover: a.handover,
      p_reason: a.reason, p_model: a.model, p_in: a.inputTokens, p_out: a.outputTokens, p_cost: a.costUsd,
    });
  }
}
