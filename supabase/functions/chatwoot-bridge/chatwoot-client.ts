// Minimal Chatwoot REST client (Application API). Only what the bridge needs.
// Auth header and endpoint per Chatwoot's API docs: `api_access_token` header,
//   POST /api/v1/accounts/{account_id}/conversations/{conversation_id}/messages

export type FetchLike = (input: string, init?: RequestInit) => Promise<Response>;

export class ChatwootClient {
  private base: string;
  private apiToken: string;
  private fetchFn: FetchLike;
  constructor(baseUrl: string, apiToken: string, fetchFn: FetchLike = (i, init) => fetch(i, init)) {
    this.base = baseUrl.replace(/\/+$/, "");
    this.apiToken = apiToken;
    this.fetchFn = fetchFn;
  }

  private async call(method: string, path: string, body?: unknown): Promise<unknown> {
    const res = await this.fetchFn(`${this.base}${path}`, {
      method,
      headers: { "Content-Type": "application/json", api_access_token: this.apiToken },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (!res.ok) {
      // Never include the token in errors; include status and a short slice of the response to help debugging.
      const text = (await res.text().catch(() => "")).slice(0, 200);
      throw new Error(`Chatwoot ${method} ${path} failed: HTTP ${res.status} ${text}`);
    }
    return await res.json().catch(() => ({}));
  }

  /**
   * Recent customer/agent messages of a conversation, oldest first. In Chatwoot's REST API message_type 0 is incoming
   * (customer) and 1 is outgoing (agent or bot); activity lines, templates and private notes are left out.
   */
  async getRecentTurns(accountId: number, conversationId: number, limit = 12): Promise<{ role: "user" | "assistant"; content: string }[]> {
    const d = (await this.call("GET", `/api/v1/accounts/${accountId}/conversations/${conversationId}/messages`)) as {
      payload?: { content?: unknown; message_type?: unknown; private?: unknown; created_at?: unknown }[];
    };
    const rows = Array.isArray(d?.payload) ? d.payload : [];
    return rows
      .filter((m) => m && m.private !== true && (m.message_type === 0 || m.message_type === 1) && typeof m.content === "string" && m.content.trim() !== "")
      .sort((a, b) => Number(a.created_at ?? 0) - Number(b.created_at ?? 0))
      .slice(-limit)
      .map((m) => ({ role: m.message_type === 0 ? "user" as const : "assistant" as const, content: m.content as string }));
  }

  /** Move a conversation to "open" so it shows up in the human agents' queue (bot-handled ones sit in "pending"). */
  setStatus(accountId: number, conversationId: number, status: "open" | "pending" | "resolved"): Promise<unknown> {
    return this.call("POST", `/api/v1/accounts/${accountId}/conversations/${conversationId}/toggle_status`, { status });
  }

  /** Send a reply to the customer (private=false) or an internal note for agents only (private=true). */
  sendMessage(accountId: number, conversationId: number, content: string, opts: { private?: boolean } = {}): Promise<unknown> {
    return this.call("POST", `/api/v1/accounts/${accountId}/conversations/${conversationId}/messages`, {
      content,
      message_type: "outgoing",
      private: opts.private === true,
    });
  }
}
