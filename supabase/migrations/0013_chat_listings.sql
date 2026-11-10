-- Ai buddy Biz — Chatwoot customer inbox bridge, Phase 3: listings and viewing requests
-- Lets the chat assistant (a) look up listings from the product catalogue and (b) ask for a property viewing.
-- Depends on 0001–0012. Functions are for the service role (the bridge) only.
-- NOT applied anywhere yet. On the EAB-QA-Test project use the generated incremental file in supabase/eab-qa-test/.
--
-- Safety design:
--   * Opt-in. A product is visible to the chat assistant only when products.chat_visible = true (default false).
--   * The assistant only ever sees name, the lowest active variant price, the SKU as a reference, and products.chat_info —
--     text the owner wrote for exactly this purpose. Costs, stock levels, suppliers and custom fields are never exposed.
--   * A viewing request creates a PENDING booking plus a task for staff. Nothing is confirmed to the customer.

alter table public.products
  add column chat_visible boolean not null default false,   -- may the chat assistant mention this product?
  add column chat_info text;                                -- what it may say: location, size, features… (owner-written)

-- ===== Viewing requests made from chat =====
create table public.chat_viewing_requests (
  booking_id uuid primary key references public.bookings(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  chatwoot_account_id int not null,
  chatwoot_conversation_id int not null,
  product_id uuid references public.products(id) on delete set null,
  created_at timestamptz not null default now(),
  foreign key (chatwoot_account_id, chatwoot_conversation_id)
    references public.chat_conversations(chatwoot_account_id, chatwoot_conversation_id) on delete cascade
);
create index on public.chat_viewing_requests (chatwoot_account_id, chatwoot_conversation_id);
alter table public.chat_viewing_requests enable row level security;
create policy chat_viewing_requests_read on public.chat_viewing_requests for select
  using (has_perm(tenant_id, 'book.view') or has_perm(tenant_id, 'book.manage'));

-- ===== Listing search (service role only) =====
-- Every word of the query (max 5, 2+ letters) must appear in the product name or its chat_info.
-- An empty query returns the newest opted-in listings.
create or replace function public.chat_search_listings(p_tenant uuid, p_query text default '', p_limit int default 5)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  words text[];
  lim int := least(greatest(coalesce(p_limit, 5), 1), 8);
  cur char(3);
begin
  select base_currency into cur from tenants where id = p_tenant;
  select coalesce(array_agg(s.word), '{}') into words from (
    select lower(t) as word from unnest(regexp_split_to_array(trim(coalesce(p_query, '')), '\s+')) t where length(t) >= 2 limit 5
  ) s;
  return coalesce((
    select jsonb_agg(q.item) from (
      select jsonb_build_object('ref', v.sku, 'name', p.name, 'price_from', v.price, 'currency', cur,
                                'info', left(coalesce(p.chat_info, ''), 600)) as item
      from products p
      join lateral (select pv.sku, pv.price from product_variants pv where pv.product_id = p.id and pv.active order by pv.price, pv.sku limit 1) v on true
      where p.tenant_id = p_tenant and p.active and p.chat_visible
        and not exists (select 1 from unnest(words) w where position(w in lower(p.name || ' ' || coalesce(p.chat_info, ''))) = 0)
      order by p.created_at desc
      limit lim
    ) q), '[]'::jsonb);
end $$;

-- ===== Viewing request (service role only) =====
-- p: {"ref": SKU of the listing (optional), "start_local": "YYYY-MM-DD HH24:MI" in the business's time zone, "notes": text}
-- Returns {"ok": true, ...} or {"ok": false, "reason": ...}. Expected problems are reasons, not errors.
create or replace function public.chat_request_viewing(p_tenant uuid, p_account int, p_conversation int, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  conv chat_conversations; ct contacts; prod products;
  tz text := tenant_tz(p_tenant);
  v_local timestamp; v_start timestamptz; v_end timestamptz;
  v_ref text := left(trim(coalesce(p->>'ref', '')), 60);
  v_notes text := left(trim(coalesce(p->>'notes', '')), 300);
  svc uuid; outl uuid; bid uuid; existing uuid; n int; label text; shown text;
begin
  select * into conv from chat_conversations
   where chatwoot_account_id = p_account and chatwoot_conversation_id = p_conversation and tenant_id = p_tenant for update;
  if not found or conv.contact_id is null then return jsonb_build_object('ok', false, 'reason', 'no_contact'); end if;
  select * into ct from contacts where id = conv.contact_id;

  if coalesce(p->>'start_local', '') !~ '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$' then
    return jsonb_build_object('ok', false, 'reason', 'bad_time');
  end if;
  begin
    v_local := (p->>'start_local')::timestamp;
  exception when others then
    return jsonb_build_object('ok', false, 'reason', 'bad_time');
  end;
  v_start := v_local at time zone tz;
  v_end := v_start + interval '60 minutes';
  shown := to_char(v_local, 'YYYY-MM-DD HH24:MI');
  if v_start < now() + interval '2 hours' then return jsonb_build_object('ok', false, 'reason', 'too_soon'); end if;
  if v_start > now() + interval '90 days' then return jsonb_build_object('ok', false, 'reason', 'too_far'); end if;

  -- same request again (customer repeats, or the webhook is retried): return the existing one
  select b.id into existing from bookings b join chat_viewing_requests r on r.booking_id = b.id
   where r.chatwoot_account_id = p_account and r.chatwoot_conversation_id = p_conversation
     and b.start_at = v_start and b.status in ('pending', 'confirmed');
  if existing is not null then
    return jsonb_build_object('ok', true, 'duplicate', true, 'booking_id', existing, 'start_local', shown);
  end if;

  select count(*) into n from chat_viewing_requests r join bookings b on b.id = r.booking_id
   where r.chatwoot_account_id = p_account and r.chatwoot_conversation_id = p_conversation and b.status in ('pending', 'confirmed');
  if n >= 3 then return jsonb_build_object('ok', false, 'reason', 'too_many_requests'); end if;

  select id into outl from outlets where tenant_id = p_tenant order by created_at limit 1;
  if outl is null then return jsonb_build_object('ok', false, 'reason', 'no_outlet'); end if;

  insert into booking_services (tenant_id, name, description, duration_minutes, price, online)
  values (p_tenant, 'Property viewing', 'Viewing requested through chat', 60, 0, false) on conflict (tenant_id, name) do nothing;
  select id into svc from booking_services where tenant_id = p_tenant and name = 'Property viewing';

  if v_ref <> '' then
    select p2.* into prod from products p2 join product_variants pv on pv.product_id = p2.id
     where p2.tenant_id = p_tenant and pv.sku = v_ref and p2.active and p2.chat_visible limit 1;
  end if;
  label := coalesce(prod.name, nullif(v_ref, ''), 'a property');

  insert into bookings (tenant_id, outlet_id, kind, service_id, contact_id, name, phone, email, party_size, start_at, end_at, status, source, notes)
  values (p_tenant, outl, 'service', svc, ct.id, ct.name, ct.phone, ct.email, 1, v_start, v_end, 'pending', 'web',
          left('Viewing request from chat, NOT confirmed. Property: ' || label || '.' || case when v_notes <> '' then ' Customer note: ' || v_notes else '' end, 1000))
  returning id into bid;

  insert into chat_viewing_requests (booking_id, tenant_id, chatwoot_account_id, chatwoot_conversation_id, product_id)
  values (bid, p_tenant, p_account, p_conversation, prod.id);

  insert into activities (tenant_id, contact_id, deal_id, kind, body, due_at, owner_id, created_by)
  values (p_tenant, ct.id, conv.deal_id, 'task', 'Confirm viewing requested via chat: ' || label || ' on ' || shown || ' (' || tz || '). Booking is pending.',
          now() + interval '1 hour', null, null);

  return jsonb_build_object('ok', true, 'duplicate', false, 'booking_id', bid, 'start_local', shown);
end $$;

-- Service role only
do $$ declare f text; begin
  foreach f in array array['chat_search_listings(uuid, text, int)', 'chat_request_viewing(uuid, int, int, jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
