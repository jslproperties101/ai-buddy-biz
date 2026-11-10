// Run from the repo root (Node 22+):
//   node --test --experimental-strip-types supabase/functions/chatwoot-bridge/tests/bridge.test.ts
// These tests use no network and no Chatwoot server.

import { test } from "node:test";
import assert from "node:assert/strict";
import { hmacSha256Hex, verifyChatwootSignature, parseTimestampSeconds, timingSafeEqual } from "../signature.ts";
import { classifyEvent, RecentIds } from "../events.ts";
import { ChatwootClient } from "../chatwoot-client.ts";
import { handleWebhook, type BridgeDeps } from "../handler.ts";

const SECRET = "test-secret";
const NOW = 1_800_000_000;

async function sign(body: string, ts = String(NOW), secret = SECRET) {
  return { "X-Chatwoot-Timestamp": ts, "X-Chatwoot-Signature": `sha256=${await hmacSha256Hex(secret, `${ts}.${body}`)}` };
}

function incoming(overrides: Record<string, unknown> = {}) {
  return {
    event: "message_created",
    id: 101,
    content: "Hi, is the Mont Kiara condo still available?",
    message_type: "incoming",
    private: false,
    account: { id: 1 },
    conversation: { id: 55, status: "pending", channel: "Channel::Whatsapp" },
    sender: { id: 9, name: "Aisha", phone_number: "+60123456789" },
    ...overrides,
  };
}

function makeDeps(over: Partial<BridgeDeps> = {}) {
  const sent: unknown[][] = [];
  const logs: string[] = [];
  const deps: BridgeDeps = {
    webhookSecret: SECRET,
    mode: "observe",
    testReply: "test reply",
    nowSeconds: () => NOW,
    recent: new RecentIds(),
    client: { sendMessage: async (...a) => { sent.push(a); return {}; } },
    log: (l) => logs.push(l),
    ...over,
  };
  return { deps, sent, logs };
}

async function post(body: unknown, deps: BridgeDeps, headers?: Record<string, string>) {
  const raw = typeof body === "string" ? body : JSON.stringify(body);
  const h = headers ?? (await sign(raw));
  return handleWebhook(new Request("https://x.test/chatwoot-bridge", { method: "POST", body: raw, headers: h }), deps);
}

// ---------- signature ----------

test("signature: known HMAC vector (RFC 4231 test case 2)", async () => {
  assert.equal(
    await hmacSha256Hex("Jefe", "what do ya want for nothing?"),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843",
  );
});

test("signature: valid signature passes", async () => {
  const body = '{"a":1}';
  const h = await sign(body);
  const r = await verifyChatwootSignature({ secret: SECRET, timestampHeader: h["X-Chatwoot-Timestamp"], signatureHeader: h["X-Chatwoot-Signature"], rawBody: body, nowSeconds: NOW });
  assert.deepEqual(r, { ok: true });
});

test("signature: tampered body fails", async () => {
  const h = await sign('{"a":1}');
  const r = await verifyChatwootSignature({ secret: SECRET, timestampHeader: h["X-Chatwoot-Timestamp"], signatureHeader: h["X-Chatwoot-Signature"], rawBody: '{"a":2}', nowSeconds: NOW });
  assert.deepEqual(r, { ok: false, reason: "mismatch" });
});

test("signature: wrong secret fails", async () => {
  const h = await sign("{}", String(NOW), "other-secret");
  const r = await verifyChatwootSignature({ secret: SECRET, timestampHeader: h["X-Chatwoot-Timestamp"], signatureHeader: h["X-Chatwoot-Signature"], rawBody: "{}", nowSeconds: NOW });
  assert.deepEqual(r, { ok: false, reason: "mismatch" });
});

test("signature: missing headers, bad timestamp, stale timestamp, bad format", async () => {
  const base = { secret: SECRET, rawBody: "{}", nowSeconds: NOW };
  assert.deepEqual(await verifyChatwootSignature({ ...base, timestampHeader: null, signatureHeader: null }), { ok: false, reason: "missing_headers" });
  assert.deepEqual(await verifyChatwootSignature({ ...base, timestampHeader: "abc", signatureHeader: "sha256=" + "a".repeat(64) }), { ok: false, reason: "bad_timestamp" });
  const old = await sign("{}", String(NOW - 301));
  assert.deepEqual(await verifyChatwootSignature({ ...base, timestampHeader: old["X-Chatwoot-Timestamp"], signatureHeader: old["X-Chatwoot-Signature"] }), { ok: false, reason: "stale_timestamp" });
  assert.deepEqual(await verifyChatwootSignature({ ...base, timestampHeader: String(NOW), signatureHeader: "md5=abc" }), { ok: false, reason: "bad_signature_format" });
});

test("signature: millisecond timestamps are accepted", async () => {
  const ms = String(NOW * 1000);
  const h = await sign("{}", ms);
  const r = await verifyChatwootSignature({ secret: SECRET, timestampHeader: ms, signatureHeader: h["X-Chatwoot-Signature"], rawBody: "{}", nowSeconds: NOW });
  assert.deepEqual(r, { ok: true });
  assert.equal(parseTimestampSeconds(ms), NOW);
  assert.equal(parseTimestampSeconds("12"), null);
});

test("timingSafeEqual", () => {
  assert.equal(timingSafeEqual("abc", "abc"), true);
  assert.equal(timingSafeEqual("abc", "abd"), false);
  assert.equal(timingSafeEqual("abc", "abcd"), false);
});

// ---------- classification ----------

test("classify: incoming text message is accepted with fields mapped", () => {
  const c = classifyEvent(incoming());
  assert.equal(c.kind, "incoming_message");
  if (c.kind === "incoming_message") {
    assert.deepEqual(c.message, {
      accountId: 1, conversationId: 55, messageId: 101,
      content: "Hi, is the Mont Kiara condo still available?",
      channel: "Channel::Whatsapp", contactId: 9, contactName: "Aisha", contactPhone: "+60123456789", conversationStatus: "pending",
    });
  }
});

test("classify: ignores outgoing, private notes, other events, empty text, missing ids, junk", () => {
  assert.deepEqual(classifyEvent(incoming({ message_type: "outgoing" })), { kind: "ignored", reason: "message_type_outgoing" });
  assert.deepEqual(classifyEvent(incoming({ private: true })), { kind: "ignored", reason: "private_note" });
  assert.deepEqual(classifyEvent(incoming({ event: "conversation_updated" })), { kind: "ignored", reason: "event_conversation_updated" });
  assert.deepEqual(classifyEvent(incoming({ content: "   " })), { kind: "ignored", reason: "no_text" });
  assert.deepEqual(classifyEvent(incoming({ content: null })), { kind: "ignored", reason: "no_text" });
  assert.deepEqual(classifyEvent(incoming({ conversation: {} })), { kind: "ignored", reason: "missing_ids" });
  assert.deepEqual(classifyEvent(null), { kind: "ignored", reason: "payload_not_object" });
  assert.deepEqual(classifyEvent("x"), { kind: "ignored", reason: "payload_not_object" });
});

test("RecentIds: detects duplicates and evicts the oldest past its limit", () => {
  const r = new RecentIds(2);
  assert.equal(r.checkAndAdd("a"), false);
  assert.equal(r.checkAndAdd("a"), true);
  r.checkAndAdd("b");
  r.checkAndAdd("c"); // evicts "a"
  assert.equal(r.checkAndAdd("a"), false);
});

// ---------- client ----------

test("client: sends the documented request and never leaks the token in errors", async () => {
  const calls: { url: string; init: RequestInit }[] = [];
  const ok = new ChatwootClient("https://chat.test/", "tok123", async (url, init) => { calls.push({ url, init: init! }); return new Response("{}", { status: 200 }); });
  await ok.sendMessage(1, 55, "hello");
  assert.equal(calls[0].url, "https://chat.test/api/v1/accounts/1/conversations/55/messages");
  assert.equal(calls[0].init.method, "POST");
  assert.equal((calls[0].init.headers as Record<string, string>).api_access_token, "tok123");
  assert.deepEqual(JSON.parse(calls[0].init.body as string), { content: "hello", message_type: "outgoing", private: false });

  const bad = new ChatwootClient("https://chat.test", "tok123", async () => new Response("nope", { status: 401 }));
  await assert.rejects(() => bad.sendMessage(1, 55, "x"), (e: Error) => /HTTP 401/.test(e.message) && !e.message.includes("tok123"));
});

// ---------- handler ----------

test("handler: rejects non-POST", async () => {
  const { deps } = makeDeps();
  const res = await handleWebhook(new Request("https://x.test/", { method: "GET" }), deps);
  assert.equal(res.status, 405);
});

test("handler: rejects missing/invalid signature with 401 and does nothing", async () => {
  const { deps, sent } = makeDeps({ mode: "test-reply" });
  const body = JSON.stringify(incoming());
  assert.equal((await post(body, deps, {})).status, 401);
  assert.equal((await post(body, deps, { "X-Chatwoot-Timestamp": String(NOW), "X-Chatwoot-Signature": "sha256=" + "0".repeat(64) })).status, 401);
  assert.equal(sent.length, 0);
});

test("handler: valid signature but invalid JSON gives 400", async () => {
  const { deps } = makeDeps();
  assert.equal((await post("not json", deps)).status, 400);
});

test("handler: observe mode acknowledges and never replies", async () => {
  const { deps, sent } = makeDeps({ mode: "observe" });
  const res = await post(incoming(), deps);
  assert.equal(res.status, 200);
  assert.deepEqual(await res.json(), { handled: true, action: "observed" });
  assert.equal(sent.length, 0);
});

test("handler: test-reply mode replies once to the right conversation", async () => {
  const { deps, sent } = makeDeps({ mode: "test-reply" });
  const res = await post(incoming(), deps);
  assert.deepEqual(await res.json(), { handled: true, action: "test_reply_sent" });
  assert.deepEqual(sent, [[1, 55, "test reply"]]);
});

test("handler: duplicate delivery is skipped (by delivery header, and by message id)", async () => {
  const { deps, sent } = makeDeps({ mode: "test-reply" });
  const raw = JSON.stringify(incoming());
  const h = { ...(await sign(raw)), "X-Chatwoot-Delivery": "d-1" };
  assert.equal((await (await post(raw, deps, h)).json()).handled, true);
  assert.deepEqual(await (await post(raw, deps, h)).json(), { handled: false, reason: "duplicate" });
  assert.equal(sent.length, 1);

  const { deps: d2, sent: s2 } = makeDeps({ mode: "test-reply" });
  await post(incoming(), d2);
  assert.deepEqual(await (await post(incoming(), d2)).json(), { handled: false, reason: "duplicate" });
  assert.equal(s2.length, 1);
});

test("handler: our own outgoing reply coming back does not trigger another reply (no loop)", async () => {
  const { deps, sent } = makeDeps({ mode: "test-reply" });
  const res = await post(incoming({ message_type: "outgoing" }), deps);
  assert.deepEqual(await res.json(), { handled: false, reason: "message_type_outgoing" });
  assert.equal(sent.length, 0);
});

test("handler: Chatwoot API failure returns 502 and does not throw", async () => {
  const { deps, logs } = makeDeps({ mode: "test-reply", client: { sendMessage: async () => { throw new Error("boom"); } } });
  const res = await post(incoming(), deps);
  assert.equal(res.status, 502);
  assert.ok(logs.some((l) => l.includes("test reply failed")));
});
