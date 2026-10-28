// Ai buddy Biz — outbound message sender (Supabase Edge Function, Deno)
//
// Sends queued rows from public.outbound_messages:
//   whatsapp → WhatsApp Cloud API (Meta). Template messages for campaigns / business-initiated chats,
//              plain text only works inside the customer's 24-hour reply window.
//   email    → Resend (https://resend.com)
//   sms      → Twilio
//
// Credentials are per business, stored in public.integration_secrets (never readable by app users):
//   whatsapp_cloud: {"phone_number_id":"…","token":"…","api_version":"v21.0"}
//   resend:         {"api_key":"re_…","from":"Shop <hello@yourdomain.com>"}
//   twilio:         {"account_sid":"AC…","auth_token":"…","from":"+60…"}
//
// Run it every minute with Supabase Cron (see README), or call it by hand:
//   curl -X POST https://<project>.supabase.co/functions/v1/send-messages -H "Authorization: Bearer <SERVICE_ROLE_KEY>"

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

type Msg = {
  id: string;
  tenant_id: string;
  campaign_id: string | null;
  channel: "whatsapp" | "email" | "sms";
  to_address: string;
  subject: string | null;
  body: string;
  wa_template: string | null;
  wa_language: string | null;
  wa_params: string[] | null;
  attempts: number;
};

type Result = { ok: true; providerId?: string } | { ok: false; error: string; retry: boolean };

const BATCH = 50;
const MAX_ATTEMPTS = 3;

Deno.serve(async (req) => {
  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const auth = req.headers.get("Authorization") ?? "";
  if (auth !== `Bearer ${serviceKey}`) return new Response("Unauthorized", { status: 401 });

  const db = createClient(url, serviceKey, { auth: { persistSession: false } });

  // Claim a batch so two overlapping runs don't send the same message twice
  const { data: queued, error } = await db
    .from("outbound_messages")
    .select("id")
    .eq("status", "queued")
    .lte("send_after", new Date().toISOString())
    .order("created_at")
    .limit(BATCH);
  if (error) return json({ error: error.message }, 500);
  const ids = ((queued ?? []) as { id: string }[]).map((r) => r.id);
  if (ids.length === 0) return json({ sent: 0, failed: 0 });

  const { data: claimed, error: claimErr } = await db
    .from("outbound_messages")
    .update({ status: "sending" })
    .in("id", ids)
    .eq("status", "queued")
    .select("*");
  if (claimErr) return json({ error: claimErr.message }, 500);

  const secrets = new Map<string, Record<string, string>>();
  const getSecret = async (tenant: string, provider: string) => {
    const key = `${tenant}:${provider}`;
    if (!secrets.has(key)) {
      const { data } = await db.from("integration_secrets").select("config").eq("tenant_id", tenant).eq("provider", provider).maybeSingle();
      secrets.set(key, (data?.config as Record<string, string>) ?? {});
    }
    return secrets.get(key)!;
  };

  let sent = 0, failed = 0;
  const campaigns = new Set<string>();

  for (const m of (claimed ?? []) as Msg[]) {
    let r: Result;
    try {
      r = await send(m, getSecret);
    } catch (e) {
      r = { ok: false, error: String(e), retry: true };
    }
    const attempts = m.attempts + 1;
    if (r.ok) {
      sent++;
      await db.from("outbound_messages").update({
        status: "sent", sent_at: new Date().toISOString(), provider_id: r.providerId ?? null, attempts, error: null,
      }).eq("id", m.id);
    } else if (r.retry && attempts < MAX_ATTEMPTS) {
      // back off 5, 25 minutes
      const wait = 5 * Math.pow(5, attempts - 1) * 60_000;
      await db.from("outbound_messages").update({
        status: "queued", attempts, error: r.error, send_after: new Date(Date.now() + wait).toISOString(),
      }).eq("id", m.id);
    } else {
      failed++;
      await db.from("outbound_messages").update({ status: "failed", attempts, error: r.error }).eq("id", m.id);
    }
    if (m.campaign_id) campaigns.add(m.campaign_id);
  }

  for (const c of campaigns) await db.rpc("campaign_refresh_counts", { p_campaign: c });
  return json({ claimed: claimed?.length ?? 0, sent, failed });
});

async function send(m: Msg, getSecret: (t: string, p: string) => Promise<Record<string, string>>): Promise<Result> {
  switch (m.channel) {
    case "whatsapp": return sendWhatsApp(m, await getSecret(m.tenant_id, "whatsapp_cloud"));
    case "email": return sendEmail(m, await getSecret(m.tenant_id, "resend"));
    case "sms": return sendSms(m, await getSecret(m.tenant_id, "twilio"));
  }
}

async function sendWhatsApp(m: Msg, cfg: Record<string, string>): Promise<Result> {
  if (!cfg.phone_number_id || !cfg.token) return { ok: false, error: "WhatsApp is not connected for this business", retry: false };
  const version = cfg.api_version || "v21.0";
  const to = m.to_address.replace(/\D/g, "");
  const payload = m.wa_template
    ? {
      messaging_product: "whatsapp",
      to,
      type: "template",
      template: {
        name: m.wa_template,
        language: { code: m.wa_language || "en" },
        ...(m.wa_params && m.wa_params.length
          ? { components: [{ type: "body", parameters: m.wa_params.map((t) => ({ type: "text", text: String(t) })) }] }
          : {}),
      },
    }
    : { messaging_product: "whatsapp", to, type: "text", text: { body: m.body, preview_url: true } };

  const res = await fetch(`https://graph.facebook.com/${version}/${cfg.phone_number_id}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${cfg.token}`, "Content-Type": "application/json" },
    body: JSON.stringify(payload),
  });
  const body = await res.json().catch(() => ({}));
  if (res.ok) return { ok: true, providerId: body?.messages?.[0]?.id };
  const err = body?.error?.message ?? `HTTP ${res.status}`;
  return { ok: false, error: err, retry: res.status === 429 || res.status >= 500 };
}

async function sendEmail(m: Msg, cfg: Record<string, string>): Promise<Result> {
  if (!cfg.api_key || !cfg.from) return { ok: false, error: "Email is not connected for this business", retry: false };
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${cfg.api_key}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: cfg.from,
      to: [m.to_address],
      subject: m.subject ?? "",
      text: m.body + "\n\nTo stop receiving these messages, reply STOP.",
    }),
  });
  const body = await res.json().catch(() => ({}));
  if (res.ok) return { ok: true, providerId: body?.id };
  return { ok: false, error: body?.message ?? `HTTP ${res.status}`, retry: res.status === 429 || res.status >= 500 };
}

async function sendSms(m: Msg, cfg: Record<string, string>): Promise<Result> {
  if (!cfg.account_sid || !cfg.auth_token || !cfg.from) return { ok: false, error: "SMS is not connected for this business", retry: false };
  const form = new URLSearchParams({ To: "+" + m.to_address.replace(/\D/g, ""), From: cfg.from, Body: m.body });
  const res = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${cfg.account_sid}/Messages.json`, {
    method: "POST",
    headers: {
      Authorization: "Basic " + btoa(`${cfg.account_sid}:${cfg.auth_token}`),
      "Content-Type": "application/x-www-form-urlencoded",
    },
    body: form,
  });
  const body = await res.json().catch(() => ({}));
  if (res.ok) return { ok: true, providerId: body?.sid };
  return { ok: false, error: body?.message ?? `HTTP ${res.status}`, retry: res.status === 429 || res.status >= 500 };
}

function json(v: unknown, status = 200) {
  return new Response(JSON.stringify(v), { status, headers: { "Content-Type": "application/json" } });
}

// Silence unused-type warning in editors without Deno types
export type { SupabaseClient };
