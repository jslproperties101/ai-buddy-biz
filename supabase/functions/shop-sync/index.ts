// Ai buddy Biz — online shop sync (Supabase Edge Function, Deno)
//
// For each business that connected Shopify or WooCommerce (More → Orders settings → Online shop):
//   1. links shop products to your products by SKU (every 6 hours, or when asked),
//   2. imports new shop orders into Orders (status "pending", marked prepaid when paid online),
//   3. publishes available stock (on hand at the chosen outlet minus what open orders already promise).
//
// Run every 5 minutes with Supabase Cron using the service key (see README), or from the app ("Sync now"),
// which calls it with the signed-in user's token and a tenant_id; the user needs the ord.settings permission.
//
// Credentials live in public.integration_secrets (never readable by app users):
//   shopify:     {"shop_domain":"your-shop.myshopify.com","access_token":"shpat_…","api_version":"2026-07","location_id":"gid://shopify/Location/…"}
//   woocommerce: {"base_url":"https://shop.example.com","consumer_key":"ck_…","consumer_secret":"cs_…"}

import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

type Channel = { tenant_id: string; provider: "shopify" | "woocommerce"; outlet_id: string; enabled: boolean; import_orders: boolean;
  push_stock: boolean; last_order_at: string | null; last_map_at: string | null };
type ExtVariant = { sku: string; external_id: string; external_parent_id?: string | null; inventory_item_id?: string | null };
type ShopOrder = { external_ref: string; number: string; created_at: string; paid: boolean; total: number; currency?: string; shipping: number;
  customer: { name?: string | null; email?: string | null; phone?: string | null }; address: string | null; postcode: string | null;
  note: string | null; items: { sku: string | null; name: string; qty: number; price: number }[] };
type StockRow = { variant_id: string; sku: string; external_id: string; external_parent_id: string | null; inventory_item_id: string | null;
  available: number; last_pushed_qty: number | null };

interface ShopApi {
  listVariants(): Promise<ExtVariant[]>;
  ordersSince(since: string): Promise<ShopOrder[]>;
  setStock(rows: StockRow[]): Promise<{ ok: StockRow[]; failed: { row: StockRow; error: string }[] }>;
}

const MAP_EVERY_MS = 6 * 3600_000;
const MAX_PUSH = 200;

Deno.serve(async (req) => {
  const url = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const auth = req.headers.get("Authorization") ?? "";
  const db = createClient(url, serviceKey, { auth: { persistSession: false } });
  let body: { tenant_id?: string; remap?: boolean } = {};
  try { body = await req.json(); } catch { /* cron calls without a body */ }

  // Who may run it: the cron (service key) for everyone, or a signed-in manager for their own business
  let onlyTenant: string | null = null;
  if (auth !== `Bearer ${serviceKey}`) {
    if (!auth.startsWith("Bearer ") || !body.tenant_id) return json({ error: "Unauthorized" }, 401);
    const asUser = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, { global: { headers: { Authorization: auth } }, auth: { persistSession: false } });
    const { data: allowed } = await asUser.rpc("has_perm", { t: body.tenant_id, perm: "ord.settings" });
    if (allowed !== true) return json({ error: "Not allowed" }, 403);
    onlyTenant = body.tenant_id;
  }

  let q = db.from("shop_channels").select("*").eq("enabled", true);
  if (onlyTenant) q = q.eq("tenant_id", onlyTenant);
  const { data: channels, error } = await q;
  if (error) return json({ error: error.message }, 500);

  const results: Record<string, unknown>[] = [];
  for (const ch of (channels ?? []) as Channel[]) {
    const stats = { linked: 0, imported: 0, pushed: 0, push_failed: 0 };
    let lastError: string | null = null;
    try {
      const { data: sec } = await db.from("integration_secrets").select("config").eq("tenant_id", ch.tenant_id).eq("provider", ch.provider).maybeSingle();
      const cfg = (sec?.config ?? {}) as Record<string, string>;
      const api = ch.provider === "shopify" ? shopify(cfg) : woo(cfg);

      // 1. Link by SKU
      if (body.remap || !ch.last_map_at || Date.now() - Date.parse(ch.last_map_at) > MAP_EVERY_MS) {
        stats.linked = await linkBySku(db, ch, await api.listVariants());
        await db.from("shop_channels").update({ last_map_at: new Date().toISOString() }).eq("tenant_id", ch.tenant_id).eq("provider", ch.provider);
      }
      // 2. Orders
      if (ch.import_orders) {
        const since = ch.last_order_at ?? new Date(Date.now() - 3 * 86400_000).toISOString();
        let newest = ch.last_order_at;
        for (const o of await api.ordersSince(since)) {
          const { error: e } = await db.rpc("shop_import_order", { p_tenant: ch.tenant_id, p_provider: ch.provider, p: o });
          if (e) throw new Error(`Order ${o.number}: ${e.message}`);
          stats.imported++;
          if (!newest || o.created_at > newest) newest = o.created_at;
        }
        if (newest !== ch.last_order_at) {
          await db.from("shop_channels").update({ last_order_at: newest }).eq("tenant_id", ch.tenant_id).eq("provider", ch.provider);
        }
      }
      // 3. Stock
      if (ch.push_stock) {
        const { data: snap, error: se } = await db.rpc("shop_stock_snapshot", { p_tenant: ch.tenant_id, p_provider: ch.provider });
        if (se) throw new Error(se.message);
        const changed = ((snap ?? []) as StockRow[]).filter((r) => r.last_pushed_qty === null || Number(r.last_pushed_qty) !== Number(r.available))
          .slice(0, MAX_PUSH);
        if (changed.length) {
          const res = await api.setStock(changed);
          const now = new Date().toISOString();
          for (const r of res.ok) {
            await db.from("shop_links").update({ last_pushed_qty: r.available, last_pushed_at: now })
              .eq("tenant_id", ch.tenant_id).eq("provider", ch.provider).eq("variant_id", r.variant_id);
          }
          stats.pushed = res.ok.length;
          stats.push_failed = res.failed.length;
          if (res.failed.length) lastError = `Stock for ${res.failed[0].row.sku}: ${res.failed[0].error}`;
        }
      }
    } catch (e) {
      lastError = e instanceof Error ? e.message : String(e);
    }
    await db.from("shop_channels").update({ last_sync_at: new Date().toISOString(), last_error: lastError, stats })
      .eq("tenant_id", ch.tenant_id).eq("provider", ch.provider);
    results.push({ tenant: ch.tenant_id, provider: ch.provider, ...stats, error: lastError });
  }
  return json({ channels: results.length, results });
});

async function linkBySku(db: SupabaseClient, ch: Channel, ext: ExtVariant[]): Promise<number> {
  const bySku = new Map<string, ExtVariant>();
  for (const v of ext) if (v.sku?.trim()) bySku.set(v.sku.trim(), v);
  const skus = [...bySku.keys()];
  let linked = 0;
  for (let i = 0; i < skus.length; i += 200) {
    const { data } = await db.from("product_variants").select("id, sku").eq("tenant_id", ch.tenant_id).in("sku", skus.slice(i, i + 200));
    const rows = ((data ?? []) as { id: string; sku: string }[]).map((v) => {
      const e = bySku.get(v.sku)!;
      return { tenant_id: ch.tenant_id, provider: ch.provider, variant_id: v.id, external_id: e.external_id,
               external_parent_id: e.external_parent_id ?? null, inventory_item_id: e.inventory_item_id ?? null };
    });
    if (rows.length) {
      const { error } = await db.from("shop_links").upsert(rows, { onConflict: "tenant_id,provider,variant_id" });
      if (error) throw new Error(error.message);
      linked += rows.length;
    }
  }
  return linked;
}

// ───────────── Shopify (GraphQL Admin API) ─────────────
function shopify(cfg: Record<string, string>): ShopApi {
  if (!cfg.shop_domain || !cfg.access_token) throw new Error("Shopify is not connected");
  const endpoint = `https://${cfg.shop_domain}/admin/api/${cfg.api_version || "2026-07"}/graphql.json`;
  const gql = async (query: string, variables: Record<string, unknown> = {}): Promise<any> => {
    for (let attempt = 0; attempt < 3; attempt++) {
      const r = await fetch(endpoint, {
        method: "POST",
        headers: { "Content-Type": "application/json", "X-Shopify-Access-Token": cfg.access_token },
        body: JSON.stringify({ query, variables }),
      });
      if (r.status === 429) { await sleep(2000 * (attempt + 1)); continue; }
      const body = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(`Shopify ${r.status}: ${body?.errors ? JSON.stringify(body.errors).slice(0, 200) : "request failed"}`);
      const throttled = (body.errors ?? []).some((e: any) => e?.extensions?.code === "THROTTLED");
      if (throttled) { await sleep(2000 * (attempt + 1)); continue; }
      if (body.errors?.length) throw new Error(`Shopify: ${body.errors[0].message}`);
      return body.data;
    }
    throw new Error("Shopify is busy (rate limited) — will retry next run");
  };
  let locationId: string | null = cfg.location_id || null;

  return {
    async listVariants() {
      const out: ExtVariant[] = [];
      let after: string | null = null;
      for (let page = 0; page < 40; page++) {
        const d = await gql(`query($after: String) { productVariants(first: 250, after: $after) {
            pageInfo { hasNextPage endCursor } nodes { id sku inventoryItem { id } } } }`, { after });
        for (const n of d.productVariants.nodes) out.push({ sku: n.sku ?? "", external_id: n.id, inventory_item_id: n.inventoryItem?.id ?? null });
        if (!d.productVariants.pageInfo.hasNextPage) break;
        after = d.productVariants.pageInfo.endCursor;
      }
      return out;
    },
    async ordersSince(since) {
      const out: ShopOrder[] = [];
      let after: string | null = null;
      for (let page = 0; page < 10; page++) {
        const d = await gql(`query($q: String!, $after: String) { orders(first: 50, after: $after, sortKey: CREATED_AT, query: $q) {
            pageInfo { hasNextPage endCursor }
            nodes { id name createdAt cancelledAt displayFinancialStatus note email phone
              customer { displayName }
              shippingAddress { name address1 address2 city province zip country phone }
              totalPriceSet { shopMoney { amount currencyCode } }
              totalShippingPriceSet { shopMoney { amount } }
              lineItems(first: 100) { nodes { sku name quantity originalUnitPriceSet { shopMoney { amount } } } } } } }`,
          { q: `created_at:>'${since}'`, after });
        for (const o of d.orders.nodes) {
          if (o.cancelledAt) continue;
          const a = o.shippingAddress;
          out.push({
            external_ref: o.id, number: o.name, created_at: o.createdAt,
            paid: ["PAID", "PARTIALLY_REFUNDED"].includes(o.displayFinancialStatus),
            total: Number(o.totalPriceSet?.shopMoney?.amount ?? 0), currency: o.totalPriceSet?.shopMoney?.currencyCode,
            shipping: Number(o.totalShippingPriceSet?.shopMoney?.amount ?? 0),
            customer: { name: o.customer?.displayName ?? a?.name ?? null, email: o.email ?? null, phone: o.phone ?? a?.phone ?? null },
            address: a ? [a.address1, a.address2, a.city, a.province, a.country].filter(Boolean).join(", ") : null,
            postcode: a?.zip ?? null, note: o.note ?? null,
            items: o.lineItems.nodes.map((l: any) => ({ sku: l.sku || null, name: l.name, qty: l.quantity,
              price: Number(l.originalUnitPriceSet?.shopMoney?.amount ?? 0) })),
          });
        }
        if (!d.orders.pageInfo.hasNextPage) break;
        after = d.orders.pageInfo.endCursor;
      }
      return out;
    },
    async setStock(rows) {
      if (!locationId) {
        const d = await gql(`{ locations(first: 1) { nodes { id } } }`);
        locationId = d.locations.nodes[0]?.id ?? null;
        if (!locationId) throw new Error("No Shopify location found — add location_id");
      }
      const ok: StockRow[] = [], failed: { row: StockRow; error: string }[] = [];
      const usable = rows.filter((r) => r.inventory_item_id);
      for (const r of rows) if (!r.inventory_item_id) failed.push({ row: r, error: "no inventory item (is inventory tracked in Shopify?)" });
      for (let i = 0; i < usable.length; i += 100) {
        const chunk = usable.slice(i, i + 100);
        // changeFromQuantity: null = set without compare-and-swap (required field since API 2026-04); @idempotent required too
        const d = await gql(`mutation($input: InventorySetQuantitiesInput!, $key: String!) {
            inventorySetQuantities(input: $input) @idempotent(key: $key) { userErrors { field message } } }`, {
          key: crypto.randomUUID(),
          input: { name: "available", reason: "correction", referenceDocumentUri: "aibuddybiz://stock-sync",
            quantities: chunk.map((r) => ({ inventoryItemId: r.inventory_item_id, locationId, quantity: Math.max(0, Math.floor(Number(r.available))), changeFromQuantity: null })) },
        });
        const errs = d.inventorySetQuantities.userErrors ?? [];
        if (errs.length) chunk.forEach((r) => failed.push({ row: r, error: errs[0].message }));
        else ok.push(...chunk);
      }
      return { ok, failed };
    },
  };
}

// ───────────── WooCommerce (REST API v3) ─────────────
function woo(cfg: Record<string, string>): ShopApi {
  if (!cfg.base_url?.startsWith("https://") || !cfg.consumer_key || !cfg.consumer_secret) throw new Error("WooCommerce is not connected");
  const base = cfg.base_url.replace(/\/+$/, "") + "/wp-json/wc/v3";
  const headers = { Authorization: "Basic " + btoa(`${cfg.consumer_key}:${cfg.consumer_secret}`), "Content-Type": "application/json" };
  const call = async (path: string, init: RequestInit = {}): Promise<any> => {
    const r = await fetch(base + path, { ...init, headers });
    const body = await r.json().catch(() => null);
    if (!r.ok) throw new Error(`WooCommerce ${r.status}: ${body?.message ?? "request failed"}`);
    return body;
  };
  return {
    async listVariants() {
      const out: ExtVariant[] = [];
      for (let page = 1; page <= 50; page++) {
        const products = await call(`/products?per_page=100&page=${page}&status=publish`);
        for (const p of products) {
          if (p.type === "variable") {
            for (let vp = 1; vp <= 10; vp++) {
              const vars = await call(`/products/${p.id}/variations?per_page=100&page=${vp}`);
              for (const v of vars) if (v.sku) out.push({ sku: v.sku, external_id: String(v.id), external_parent_id: String(p.id) });
              if (vars.length < 100) break;
            }
          } else if (p.sku) {
            out.push({ sku: p.sku, external_id: String(p.id) });
          }
        }
        if (products.length < 100) break;
      }
      return out;
    },
    async ordersSince(since) {
      const out: ShopOrder[] = [];
      for (let page = 1; page <= 10; page++) {
        const orders = await call(`/orders?after=${encodeURIComponent(since)}&per_page=100&page=${page}&orderby=date&order=asc`);
        for (const o of orders) {
          if (!["processing", "on-hold", "completed"].includes(o.status)) continue;   // skip unpaid/failed/cancelled
          const s = o.shipping ?? {}, b = o.billing ?? {};
          const addr = [s.address_1, s.address_2, s.city, s.state, s.country].filter(Boolean).join(", ");
          out.push({
            external_ref: String(o.id), number: `#${o.number}`, created_at: (o.date_created_gmt ?? o.date_created) + "Z",
            paid: !!o.date_paid, total: Number(o.total), currency: o.currency, shipping: Number(o.shipping_total ?? 0),
            customer: { name: [b.first_name, b.last_name].filter(Boolean).join(" ") || null, email: b.email || null, phone: b.phone || s.phone || null },
            address: addr || null, postcode: s.postcode || null, note: o.customer_note || null,
            items: (o.line_items ?? []).map((l: any) => ({ sku: l.sku || null, name: l.name, qty: l.quantity, price: Number(l.price) })),
          });
        }
        if (orders.length < 100) break;
      }
      return out;
    },
    async setStock(rows) {
      const ok: StockRow[] = [], failed: { row: StockRow; error: string }[] = [];
      for (const r of rows) {
        const path = r.external_parent_id ? `/products/${r.external_parent_id}/variations/${r.external_id}` : `/products/${r.external_id}`;
        try {
          await call(path, { method: "PUT", body: JSON.stringify({ manage_stock: true, stock_quantity: Math.max(0, Math.floor(Number(r.available))) }) });
          ok.push(r);
        } catch (e) {
          failed.push({ row: r, error: e instanceof Error ? e.message : String(e) });
        }
      }
      return { ok, failed };
    },
  };
}

function sleep(ms: number) { return new Promise((r) => setTimeout(r, ms)); }
function json(v: unknown, status = 200) {
  return new Response(JSON.stringify(v), { status, headers: { "Content-Type": "application/json" } });
}
