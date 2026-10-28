// Ai buddy Biz — send-messages
// Sends a queued campaign in batches over WhatsApp Cloud API or email (Resend).
//
// Call from the app:  supabase.functions.invoke('send-messages', { body: { campaign_id } })
// The caller must be allowed to manage campaigns (checked with their own login).
// Call repeatedly until { remaining: 0 }.
//
// Secrets (supabase secrets set …):
//   WHATSAPP_TOKEN, WHATSAPP_PHONE_NUMBER_ID, GRAPH_API_VERSION (default v22.0)
//   RESEND_API_KEY, EMAIL_FROM (e.g. "Kedai Joe <hello@yourdomain.com>")
// SUPABASE_URL, SUPABASE_ANON_KEY and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.

import { createClient } from "npm:@supabase/supabase-js@2";

const BATCH = 40;
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

type Recipient = {
  id: number;
  to_address: string;
  contacts: { name: string; email: string | null } | null;
  contact_id: string;
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
}

function fill(text: string, vars: Record<string, string>) {
  return text.replace(/\{\{\s*(\w+)\s*\}\}/g, (_, k) => vars[k] ?? "");
}

function escapeHtml(s: string) {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
}

async function sendWhatsApp(to: string, campaign: any, vars: Record<string, string>) {
  const token = Deno.env.get("WHATSAPP_TOKEN");
  const phoneId = Deno.env.get("WHATSAPP_PHONE_NUMBER_ID");
  const ver = Deno.env.get("GRAPH_API_VERSION") ?? "v22.0";
  if (!token || !phoneId) throw new Error("WhatsApp is not set up (WHATSAPP_TOKEN / WHATSAPP_PHONE_NUMBER_ID)");

  // Outside the 24-hour customer service window only approved templates are delivered.
  const body = campaign.wa_template_name
    ? {
        messaging_product: "whatsapp",
        to,
        type: "template",
        template: {
          name: campaign.wa_template_name,
          language: { code: campaign.wa_template_lang || "en" },
          components: (campaign.wa_template_params ?? []).length
            ? [{
                type: "body",
                parameters: (campaign.wa_template_params as string[]).map((p) => ({ type: "text", text: vars[p] || "-" })),
              }]
            : [],
        },
      }
    : { messaging_product: "whatsapp", to, type: "text", text: { body: fill(campaign.message, vars) } };

  const res = await fetch(`https://graph.facebook.com/${ver}/${phoneId}/messages`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out?.error?.message ?? `WhatsApp error ${res.status}`);
  return out?.messages?.[0]?.id as string | undefined;
}

async function sendEmail(to: string, campaign: any, vars: Record<string, string>) {
  const key = Deno.env.get("RESEND_API_KEY");
  const from = Deno.env.get("EMAIL_FROM");
  if (!key || !from) throw new Error("Email is not set up (RESEND_API_KEY / EMAIL_FROM)");
  const text = fill(campaign.message, vars);
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from,
      to: [to],
      subject: fill(campaign.subject || campaign.name, vars),
      text,
      html: `<div style="font-family:sans-serif;line-height:1.5">${escapeHtml(text).replace(/\n/g, "<br>")}</div>`,
    }),
  });
  const out = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(out?.message ?? `Email error ${res.status}`);
  return out?.id as string | undefined;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const url = Deno.env.get("SUPABASE_URL")!;
  const auth = req.headers.get("Authorization") ?? "";
  const { campaign_id } = await req.json().catch(() => ({}));
  if (!campaign_id) return json({ error: "campaign_id is required" }, 400);

  // 1. Permission check with the caller's own login (RLS: crm.campaign.manage)
  const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } } });
  const { data: mine } = await asUser.from("campaigns").select("id").eq("id", campaign_id).maybeSingle();
  if (!mine) return json({ error: "Campaign not found or not allowed" }, 403);

  // 2. Do the work with the service role
  const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const { data: campaign } = await admin.from("campaigns").select("*, tenants(name)").eq("id", campaign_id).single();
  if (!campaign || !["queued", "sending"].includes(campaign.status)) {
    return json({ error: `Campaign is ${campaign?.status ?? "missing"}` }, 400);
  }
  await admin.from("campaigns").update({ status: "sending" }).eq("id", campaign_id).eq("status", "queued");

  const { data: batch } = await admin
    .from("campaign_recipients")
    .select("id, to_address, contact_id, contacts(name, email)")
    .eq("campaign_id", campaign_id)
    .eq("status", "queued")
    .order("id")
    .limit(BATCH);

  let sent = 0, failed = 0;
  const errors: string[] = [];
  for (const r of (batch ?? []) as unknown as Recipient[]) {
    const name = r.contacts?.name ?? "";
    const { data: pts } = await admin.rpc("points_balance", { p_contact: r.contact_id });
    const vars = {
      name,
      first_name: name.split(/\s+/)[0] ?? name,
      points: String(pts ?? 0),
      business: campaign.tenants?.name ?? "",
    };
    try {
      const id = campaign.channel === "whatsapp"
        ? await sendWhatsApp(r.to_address, campaign, vars)
        : await sendEmail(r.to_address, campaign, vars);
      await admin.rpc("campaign_mark", { p_recipient: r.id, p_ok: true, p_provider_id: id ?? null, p_error: null });
      sent++;
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      // A setup problem stops the run instead of failing every recipient
      if (msg.includes("is not set up")) return json({ error: msg, sent, failed }, 400);
      await admin.rpc("campaign_mark", { p_recipient: r.id, p_ok: false, p_provider_id: null, p_error: msg.slice(0, 500) });
      failed++;
      if (errors.length < 3) errors.push(msg);
    }
  }

  const { count } = await admin
    .from("campaign_recipients")
    .select("id", { count: "exact", head: true })
    .eq("campaign_id", campaign_id)
    .eq("status", "queued");

  return json({ sent, failed, remaining: count ?? 0, errors });
});
