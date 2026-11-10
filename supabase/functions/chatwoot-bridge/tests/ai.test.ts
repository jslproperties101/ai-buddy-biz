// node --test --experimental-strip-types supabase/functions/chatwoot-bridge/tests/ai.test.ts
import { test } from "node:test";
import assert from "node:assert/strict";
import { buildMessages, buildSystemPrompt, costUsd, decide, HOLDING_REPLY, MAX_REPLY_CHARS, parseDecision, replyIsSafe, TOOL } from "../ai.ts";

const toolBody = (input: unknown, usage = { input_tokens: 120, output_tokens: 30 }) => ({ content: [{ type: "tool_use", name: "respond", input }], usage });

// ---------- buildMessages ----------

test("buildMessages: current message goes last; history already containing it is not duplicated", () => {
  const out = buildMessages([{ role: "user", content: "hi" }, { role: "assistant", content: "Hello!" }, { role: "user", content: "condo in KL?" }], "condo in KL?");
  assert.deepEqual(out, [{ role: "user", content: "hi" }, { role: "assistant", content: "Hello!" }, { role: "user", content: "condo in KL?" }]);
});

test("buildMessages: no history gives just the current message", () => {
  assert.deepEqual(buildMessages([], "hello"), [{ role: "user", content: "hello" }]);
});

test("buildMessages: leading assistant turns are dropped and same-role neighbours merged so roles alternate", () => {
  const out = buildMessages([
    { role: "assistant", content: "Welcome!" },
    { role: "user", content: "a" }, { role: "user", content: "b" },
    { role: "assistant", content: "x" }, { role: "assistant", content: "y" },
  ], "c");
  assert.deepEqual(out, [{ role: "user", content: "a\nb" }, { role: "assistant", content: "x\ny" }, { role: "user", content: "c" }]);
});

test("buildMessages: keeps only the most recent turns and truncates very long messages", () => {
  const history = Array.from({ length: 30 }, (_, i) => ({ role: (i % 2 === 0 ? "user" : "assistant") as "user" | "assistant", content: `m${i}` }));
  const out = buildMessages(history, "now", 4);
  assert.ok(out.length <= 5);
  assert.equal(out[out.length - 1].content, "now");
  assert.equal(buildMessages([], "x".repeat(5000))[0].content.length, 2000);
});

test("buildMessages: blank history entries are ignored", () => {
  assert.deepEqual(buildMessages([{ role: "user", content: "  " }], "hi"), [{ role: "user", content: "hi" }]);
});

// ---------- replyIsSafe ----------

test("replyIsSafe blocks links and bare domains, allows normal text", () => {
  for (const bad of ["see https://evil.test/pay", "go to www.evil.test", "visit evil.com/login", "pay at bank-me.my/x"]) assert.equal(replyIsSafe(bad), false, bad);
  for (const good of ["Hi! Are you looking to buy or rent?", "Budget around RM1.2m in Mont Kiara?", "Selamat datang! Anda mahu beli atau sewa?", "你好，请问想买还是租？"]) assert.equal(replyIsSafe(good), true, good);
});

// ---------- parseDecision ----------

test("parseDecision: normal answer with lead details", () => {
  const d = parseDecision(toolBody({
    reply: "Hi Aisha! Which area are you looking at?", language: "en", handover: false,
    lead: { name: "Aisha", interest: "3-bed condo", summary: "Wants a 3-bed", budget: "RM1.2m", mm2h_interest: true, property_type: "condo" },
  }));
  assert.equal(d.reply, "Hi Aisha! Which area are you looking at?");
  assert.equal(d.handover, false);
  assert.equal(d.handoverReason, null);
  assert.equal(d.language, "en");
  assert.equal(d.lead.name, "Aisha");
  assert.equal(d.lead.budget, "RM1.2m");
  assert.equal(d.lead.mm2hInterest, true);
});

test("parseDecision: handover without a reason gets a default reason", () => {
  const d = parseDecision(toolBody({ reply: "A colleague will help.", handover: true }));
  assert.equal(d.handover, true);
  assert.equal(d.handoverReason, "AI asked for a person");
});

test("parseDecision: no tool call or unreadable answer falls back to a holding reply and handover", () => {
  for (const body of [{ content: [{ type: "text", text: "hello" }] }, {}, null, { content: [{ type: "tool_use", name: "other", input: {} }] }]) {
    const d = parseDecision(body);
    assert.equal(d.reply, HOLDING_REPLY);
    assert.equal(d.handover, true);
    assert.equal(d.handoverReason, "AI answer could not be read");
  }
});

test("parseDecision: empty reply is replaced and forces handover", () => {
  const d = parseDecision(toolBody({ reply: "   ", handover: false }));
  assert.equal(d.reply, HOLDING_REPLY);
  assert.equal(d.handover, true);
});

test("parseDecision: a reply with a link is blocked, replaced and handed over", () => {
  const d = parseDecision(toolBody({ reply: "Pay here https://evil.test/x", handover: false }));
  assert.equal(d.reply, HOLDING_REPLY);
  assert.equal(d.handover, true);
  assert.match(d.handoverReason ?? "", /link/);
});

test("parseDecision: long replies are capped, bad types and unknown language are neutralised", () => {
  const d = parseDecision(toolBody({ reply: "a".repeat(5000), language: "klingon", handover: "yes", lead: { name: 42, budget: { x: 1 }, mm2h_interest: "true" } }));
  assert.equal(d.reply.length, MAX_REPLY_CHARS);
  assert.equal(d.language, null);
  assert.equal(d.handover, false); // only a real boolean true counts
  assert.equal(d.lead.name, "");
  assert.equal(d.lead.budget, "");
  assert.equal(d.lead.mm2hInterest, null);
});

// ---------- decide ----------

function fakeFetch(responses: { status: number; body: unknown }[]) {
  const calls: { url: string; init: RequestInit }[] = [];
  const f = async (url: string, init?: RequestInit) => {
    calls.push({ url, init: init! });
    const r = responses[Math.min(calls.length - 1, responses.length - 1)];
    return new Response(JSON.stringify(r.body), { status: r.status });
  };
  return { f, calls };
}

test("decide: sends a forced-tool request with the key in the header and returns usage", async () => {
  const { f, calls } = fakeFetch([{ status: 200, body: toolBody({ reply: "Hi!", handover: false }) }]);
  const d = await decide({ fetchFn: f, apiKey: "sk-test", model: "claude-sonnet-5-5", system: "SYS", messages: [{ role: "user", content: "hello" }] });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://api.anthropic.com/v1/messages");
  assert.equal((calls[0].init.headers as Record<string, string>)["x-api-key"], "sk-test");
  const sent = JSON.parse(calls[0].init.body as string);
  assert.equal(sent.model, "claude-sonnet-5-5");
  assert.equal(sent.system, "SYS");
  assert.deepEqual(sent.tool_choice, { type: "tool", name: "respond" });
  assert.deepEqual(sent.tools, [JSON.parse(JSON.stringify(TOOL))]);
  assert.deepEqual(sent.messages, [{ role: "user", content: "hello" }]);
  assert.deepEqual(d.usage, { input: 120, output: 30 });
  assert.equal(d.model, "claude-sonnet-5-5");
  assert.equal(d.reply, "Hi!");
});

test("decide: retries on 429 then succeeds", async () => {
  const waits: number[] = [];
  const { f, calls } = fakeFetch([{ status: 429, body: {} }, { status: 200, body: toolBody({ reply: "ok", handover: false }) }]);
  const d = await decide({ fetchFn: f, apiKey: "k", model: "m", system: "s", messages: [{ role: "user", content: "x" }], sleep: async (ms) => { waits.push(ms); } });
  assert.equal(calls.length, 2);
  assert.equal(waits.length, 1);
  assert.equal(d.reply, "ok");
});

test("decide: gives up after repeated 429/529", async () => {
  const { f, calls } = fakeFetch([{ status: 529, body: {} }]);
  await assert.rejects(() => decide({ fetchFn: f, apiKey: "k", model: "m", system: "s", messages: [], sleep: async () => {} }), /busy/);
  assert.equal(calls.length, 3);
});

test("decide: other errors throw with the service message and never include the key", async () => {
  const { f } = fakeFetch([{ status: 400, body: { error: { message: "bad request" } } }]);
  await assert.rejects(() => decide({ fetchFn: f, apiKey: "sk-secret", model: "m", system: "s", messages: [] }), (e: Error) => e.message === "bad request" && !e.message.includes("sk-secret"));
});

// ---------- misc ----------

test("costUsd uses the model price table; unknown models cost 0", () => {
  assert.equal(costUsd("claude-sonnet-5-5", { input: 1_000_000, output: 1_000_000 }), 12);
  assert.equal(costUsd("claude-haiku-5-5", { input: 1_000_000, output: 0 }), 0.1);
  assert.equal(costUsd("something-else", { input: 5, output: 5 }), 0);
});

test("system prompt names the business and carries the key safety rules", () => {
  const p = buildSystemPrompt({ business: "Test Realty", country: "MY", currency: "MYR" });
  assert.match(p, /Test Realty/);
  assert.match(p, /MYR/);
  assert.match(p, /untrusted/i);
  assert.match(p, /NO listing, price or availability data/);
  assert.match(p, /passport|IC/);
});
