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

  /** Send a reply to the customer (private=false) or an internal note for agents only (private=true). */
  sendMessage(accountId: number, conversationId: number, content: string, opts: { private?: boolean } = {}): Promise<unknown> {
    return this.call("POST", `/api/v1/accounts/${accountId}/conversations/${conversationId}/messages`, {
      content,
      message_type: "outgoing",
      private: opts.private === true,
    });
  }
}
