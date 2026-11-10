// Talks to the Biz database (schema "biz" in EAB-QA-Test) with the service role, through the Data API.
// Only the four chatwoot_* functions from migration 0012 are ever called; they are locked to the service role.

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export type ClaimResult = "new" | "retry" | "duplicate";
export type LeadInput = { name: string; phone: string; email: string; message: string; interest: string };
export type LeadResult = { saved: boolean; reason?: string };
export type ProductRow = {
  name: string;
  description: string;
  currency: string | null;
  variants: { name: string | null; sku: string; price: number; in_stock: boolean }[];
};

export interface BridgeStore {
  claim(key: string): Promise<ClaimResult>;
  finish(key: string, ok: boolean): Promise<void>;
  saveLead(accountId: number, conversationId: number, lead: LeadInput): Promise<LeadResult>;
  findProducts(accountId: number, query: string): Promise<ProductRow[]>;
}

export class SupabaseStore implements BridgeStore {
  private base: string;
  private key: string;
  private schema: string;
  private fetchFn: FetchLike;
  constructor(supabaseUrl: string, serviceRoleKey: string, schema = "biz", fetchFn: FetchLike = (i, init) => fetch(i, init)) {
    this.base = supabaseUrl.replace(/\/+$/, "");
    this.key = serviceRoleKey;
    this.schema = schema;
    this.fetchFn = fetchFn;
  }

  private async rpc<T>(fn: string, args: Record<string, unknown>): Promise<T> {
    const res = await this.fetchFn(`${this.base}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: {
        apikey: this.key,
        Authorization: `Bearer ${this.key}`,
        "Content-Type": "application/json",
        "Content-Profile": this.schema,
      },
      body: JSON.stringify(args),
    });
    if (!res.ok) {
      const text = (await res.text().catch(() => "")).slice(0, 200); // never include the key
      throw new Error(`database ${fn} failed: HTTP ${res.status} ${text}`);
    }
    return (await res.json().catch(() => null)) as T;
  }

  async claim(key: string): Promise<ClaimResult> {
    const r = await this.rpc<string>("chatwoot_claim_event", { p_key: key });
    return r === "new" || r === "retry" ? r : "duplicate";
  }
  async finish(key: string, ok: boolean): Promise<void> {
    await this.rpc("chatwoot_finish_event", { p_key: key, p_ok: ok });
  }
  async saveLead(accountId: number, conversationId: number, lead: LeadInput): Promise<LeadResult> {
    const r = await this.rpc<{ saved?: boolean; reason?: string }>("chatwoot_save_lead", { p_account: accountId, p_conversation: conversationId, p: lead });
    return { saved: r?.saved === true, reason: r?.reason };
  }
  async findProducts(accountId: number, query: string): Promise<ProductRow[]> {
    const r = await this.rpc<ProductRow[]>("chatwoot_find_products", { p_account: accountId, p_query: query });
    return Array.isArray(r) ? r : [];
  }
}
