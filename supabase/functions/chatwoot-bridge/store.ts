// What the live pipeline needs from the database. An interface so the pipeline can be tested with a fake;
// the real implementation (supabase-store.ts) calls the chat_* functions from migration 0012.

export type LeadInput = {
  name: string;
  phone: string;
  email: string;
  interest: string;
  summary: string;
  language: string;
  source: string;
  values: Record<string, string | boolean>;
};

export type ClaimResult =
  | { ok: true; tenantId: string; botEnabled: boolean; maxBotReplies: number }
  | { ok: false; reason: string };

export type BusinessContext = { business: string; country: string; currency: string; plan: string; used: number; limit: number };

export type Listing = { ref: string; name: string; price_from: number; currency: string; info: string };

export type ViewingResult =
  | { ok: true; duplicate: boolean; bookingId: string; startLocal: string }
  | { ok: false; reason: string };

export interface BridgeStore {
  claimEvent(accountId: number, key: string): Promise<ClaimResult>;
  releaseEvent(key: string): Promise<void>;
  getContext(tenantId: string): Promise<BusinessContext>;
  getConversation(accountId: number, conversationId: number): Promise<{ botReplies: number; handedOver: boolean } | null>;
  upsertLead(tenantId: string, accountId: number, conversationId: number, lead: LeadInput): Promise<{ contactId: string; dealId: string; created: boolean }>;
  searchListings(tenantId: string, query: string, limit: number): Promise<Listing[]>;
  requestViewing(tenantId: string, accountId: number, conversationId: number, req: { ref: string; startLocal: string; notes: string }): Promise<ViewingResult>;
  recordTurn(args: {
    tenantId: string; accountId: number; conversationId: number; replied: boolean; handover: boolean; reason: string | null;
    model: string; inputTokens: number; outputTokens: number; costUsd: number;
  }): Promise<void>;
}
