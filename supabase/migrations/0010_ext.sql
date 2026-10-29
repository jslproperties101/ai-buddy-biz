-- Ai buddy Biz — Batch I: Restaurant, online orders, bookings, delivery, shop sync (module EXT)
-- Tables & floor, kitchen stations & display, modifiers, orders for every channel (dine-in, takeaway,
-- delivery, QR at table, online, marketplace, Shopify/WooCommerce), checkout through the POS sale engine,
-- public menu / ordering / tracking / booking RPCs for the customer web app, appointment & table bookings,
-- delivery zones and riders, and stock sync bookkeeping for online shops.
-- Depends on 0001–0009.

do $$ begin
  if exists (select 1 from pg_namespace where nspname = 'extensions') then
    create extension if not exists btree_gist with schema extensions;
  else
    create extension if not exists btree_gist;
  end if;
end $$;

-- ===== Permissions & roles =====
insert into public.permissions (code, module, description) values
  ('ord.view','EXT','See tables, orders and the kitchen display'),
  ('ord.take','EXT','Take orders and send them to the kitchen'),
  ('ord.kitchen','EXT','Update item status on the kitchen display'),
  ('ord.void','EXT','Void sent items and cancel orders'),
  ('ord.deliver','EXT','Deliver orders assigned to me'),
  ('ord.settings','EXT','Tables, stations, modifiers, online ordering, delivery zones, shop sync'),
  ('book.view','EXT','See bookings'),
  ('book.manage','EXT','Create and change bookings');

insert into public.roles (tenant_id, name, is_builtin) values (null, 'Kitchen', true) on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r join public.permissions p on p.module = 'EXT'
where r.tenant_id is null and r.name in ('Owner','Admin','Manager') on conflict do nothing;
insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r, unnest(array['ord.view','ord.take','ord.kitchen','book.view','book.manage']) c
where r.tenant_id is null and r.name = 'Cashier' on conflict do nothing;
insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r, unnest(array['ord.view','ord.kitchen']) c
where r.tenant_id is null and r.name = 'Kitchen' on conflict do nothing;
insert into public.role_permissions (role_id, permission_code)
select r.id, 'ord.deliver' from public.roles r where r.tenant_id is null and r.name = 'Driver' on conflict do nothing;
insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r, unnest(array['book.view']) c
where r.tenant_id is null and r.name in ('Viewer','Sales') on conflict do nothing;

-- ===== Settings =====
create table public.ext_settings (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  web_base_url text,                         -- where web/menu.html, order.html, book.html are hosted
  online_key text not null default encode(sha256(convert_to(gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')), 'hex'),
  qr_ordering boolean not null default true,
  qr_auto_send boolean not null default false,   -- QR orders go straight to the kitchen (else staff accept first)
  online_ordering boolean not null default false,
  pickup_enabled boolean not null default true,
  delivery_enabled boolean not null default false,
  prep_minutes int not null default 20,
  service_charge_pct numeric(5,2) not null default 0 check (service_charge_pct between 0 and 20),
  service_charge_dine_in_only boolean not null default true,
  booking_enabled boolean not null default false,
  booking_slot_minutes int not null default 15 check (booking_slot_minutes between 5 and 120),
  table_booking_minutes int not null default 90,
  booking_max_party int not null default 12,
  booking_min_notice_minutes int not null default 60,
  booking_days_ahead int not null default 60,
  service_variant_id uuid references public.product_variants(id),
  delivery_variant_id uuid references public.product_variants(id),
  updated_at timestamptz not null default now(),
  unique (online_key)
);

create table public.business_hours (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  weekday int not null check (weekday between 1 and 7),     -- ISO: 1 = Monday
  opens time not null,
  closes time not null,
  check (closes > opens)
);

-- ===== Floor, stations, menu options =====
create table public.dining_areas (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  name text not null,
  sort_order int not null default 0
);

create table public.dining_tables (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  area_id uuid references public.dining_areas(id) on delete set null,
  name text not null,
  seats int not null default 4 check (seats between 1 and 50),
  qr_token text not null default encode(sha256(convert_to(gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')), 'hex'),
  bookable boolean not null default true,
  active boolean not null default true,
  sort_order int not null default 0,
  unique (outlet_id, name),
  unique (qr_token)
);

create table public.kitchen_stations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  unique (tenant_id, name)
);

alter table public.products
  add column if not exists station_id uuid references public.kitchen_stations(id) on delete set null,
  add column if not exists on_menu boolean not null default true,        -- shown on QR / online menu
  add column if not exists sold_out boolean not null default false,      -- "86"
  add column if not exists menu_sort int not null default 0;

create table public.modifier_groups (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,                      -- e.g. "Spice level", "Add-ons"
  min_select int not null default 0 check (min_select >= 0),
  max_select int not null default 1 check (max_select >= 1),
  check (max_select >= min_select),
  unique (tenant_id, name)
);

create table public.modifiers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  group_id uuid not null references public.modifier_groups(id) on delete cascade,
  name text not null,
  price_delta numeric(12,2) not null default 0 check (price_delta >= 0),
  active boolean not null default true,
  sort_order int not null default 0
);

create table public.product_modifier_groups (
  product_id uuid not null references public.products(id) on delete cascade,
  group_id uuid not null references public.modifier_groups(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  sort_order int not null default 0,
  primary key (product_id, group_id)
);

create table public.delivery_zones (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  name text not null,
  postcodes text[] not null default '{}',   -- empty = any postcode
  fee numeric(10,2) not null default 0 check (fee >= 0),
  min_order numeric(10,2) not null default 0,
  active boolean not null default true
);

-- ===== Orders =====
create table public.order_counters (
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  day date not null,
  next_no int not null default 1,
  primary key (outlet_id, day)
);

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id),
  order_no text not null,
  channel text not null check (channel in ('dine_in','takeaway','delivery','online','marketplace')),
  source text not null default 'staff' check (source in ('staff','qr','web','shopify','woocommerce')),
  table_id uuid references public.dining_tables(id) on delete set null,
  status text not null default 'open' check (status in ('pending','open','ready','out_for_delivery','delivered','completed','cancelled')),
  guests int,
  contact_id uuid references public.contacts(id) on delete set null,
  customer_name text,
  customer_phone text,
  customer_email text,
  notes text,
  fulfilment text not null default 'here' check (fulfilment in ('here','pickup','delivery','shipping')),
  scheduled_for timestamptz,
  delivery_address text,
  delivery_postcode text,
  delivery_zone_id uuid references public.delivery_zones(id) on delete set null,
  delivery_fee numeric(10,2) not null default 0,
  service_charge_pct numeric(5,2) not null default 0,
  rider_id uuid,
  external_provider text check (external_provider in ('shopify','woocommerce','grabfood','foodpanda','shopeefood','lalamove','other')),
  external_ref text,
  prepaid boolean not null default false,
  prepaid_amount numeric(14,2),
  items_total numeric(14,2) not null default 0,      -- before tax, service charge and delivery
  sale_id uuid references public.sales(id),
  track_token text not null default encode(sha256(convert_to(gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')), 'hex'),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  ready_at timestamptz,
  dispatched_at timestamptz,
  delivered_at timestamptz,
  completed_at timestamptz,
  cancelled_at timestamptz,
  cancel_reason text,
  unique (track_token),
  unique (tenant_id, external_provider, external_ref)
);
create index on public.orders (tenant_id, status, created_at desc);
create unique index one_open_order_per_table on public.orders (table_id) where table_id is not null and status in ('pending','open','ready');

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade,
  variant_id uuid references public.product_variants(id),       -- null = external item not linked yet
  name text not null,
  qty numeric(10,3) not null check (qty > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  modifiers jsonb not null default '[]',          -- [{id, name, price}]
  modifiers_total numeric(12,2) not null default 0,
  note text,
  course int not null default 1,
  station_id uuid references public.kitchen_stations(id) on delete set null,
  status text not null default 'new' check (status in ('new','sent','preparing','ready','served','void')),
  source text not null default 'staff',
  sent_at timestamptz,
  ready_at timestamptz,
  served_at timestamptz,
  void_reason text,
  voided_by uuid,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.order_items (order_id);
create index on public.order_items (tenant_id, status) where status in ('sent','preparing');

-- ===== Bookings =====
create table public.booking_services (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  description text,
  duration_minutes int not null check (duration_minutes between 5 and 600),
  buffer_minutes int not null default 0,
  price numeric(12,2) not null default 0,
  variant_id uuid references public.product_variants(id),     -- what is sold at checkout
  online boolean not null default true,
  active boolean not null default true,
  unique (tenant_id, name)
);

create table public.booking_resources (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  name text not null,                         -- "Aina (stylist)", "Room 2", "Court A"
  kind text not null default 'staff' check (kind in ('staff','room','equipment')),
  user_id uuid,
  active boolean not null default true
);

create table public.resource_services (
  resource_id uuid not null references public.booking_resources(id) on delete cascade,
  service_id uuid not null references public.booking_services(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  primary key (resource_id, service_id)
);

create table public.bookings (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id),
  kind text not null check (kind in ('table','service')),
  service_id uuid references public.booking_services(id),
  resource_id uuid references public.booking_resources(id),
  table_id uuid references public.dining_tables(id),
  contact_id uuid references public.contacts(id) on delete set null,
  name text not null,
  phone text,
  email text,
  party_size int not null default 1 check (party_size between 1 and 100),
  start_at timestamptz not null,
  end_at timestamptz not null,
  status text not null default 'confirmed' check (status in ('pending','confirmed','arrived','completed','no_show','cancelled')),
  source text not null default 'staff' check (source in ('staff','web','phone')),
  notes text,
  order_id uuid references public.orders(id),
  sale_id uuid references public.sales(id),
  token text not null default encode(sha256(convert_to(gen_random_uuid()::text || clock_timestamp()::text, 'UTF8')), 'hex'),
  reminder_sent_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (end_at > start_at),
  check ((kind = 'service' and service_id is not null) or (kind = 'table')),
  unique (token),
  -- no double-booking of a person/room or a table
  constraint no_resource_overlap exclude using gist (resource_id with =, tstzrange(start_at, end_at) with &&)
    where (resource_id is not null and status in ('pending','confirmed','arrived')),
  constraint no_table_overlap exclude using gist (table_id with =, tstzrange(start_at, end_at) with &&)
    where (table_id is not null and status in ('pending','confirmed','arrived'))
);
create index on public.bookings (tenant_id, start_at);

-- ===== Online shop sync (Shopify / WooCommerce) =====
alter table public.integration_secrets drop constraint if exists integration_secrets_provider_check;
alter table public.integration_secrets add constraint integration_secrets_provider_check
  check (provider in ('whatsapp_cloud','resend','twilio','myinvois','shopify','woocommerce'));

create table public.shop_channels (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  provider text not null check (provider in ('shopify','woocommerce')),
  outlet_id uuid not null references public.outlets(id),      -- stock comes from / goes to this outlet
  enabled boolean not null default true,
  import_orders boolean not null default true,
  push_stock boolean not null default true,
  last_order_at timestamptz,
  last_map_at timestamptz,
  last_sync_at timestamptz,
  last_error text,
  stats jsonb not null default '{}',
  primary key (tenant_id, provider)
);

create table public.shop_links (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  provider text not null,
  variant_id uuid not null references public.product_variants(id) on delete cascade,
  external_id text not null,                 -- Shopify ProductVariant GID / Woo product or variation id
  external_parent_id text,                   -- Woo parent product of a variation
  inventory_item_id text,                    -- Shopify InventoryItem GID
  last_pushed_qty numeric,
  last_pushed_at timestamptz,
  primary key (tenant_id, provider, variant_id)
);

-- ===== Helpers =====
create or replace function public.ensure_ext_defaults(p_tenant uuid)
returns void language plpgsql security definer set search_path = public as $$
declare pid uuid; vid uuid;
begin
  insert into ext_settings (tenant_id) values (p_tenant) on conflict do nothing;
  insert into kitchen_stations (tenant_id, name) values (p_tenant, 'Kitchen') on conflict do nothing;
  if (select service_variant_id from ext_settings where tenant_id = p_tenant) is null then
    insert into products (tenant_id, name, kind, on_menu) values (p_tenant, 'Service charge', 'service', false) returning id into pid;
    insert into product_variants (tenant_id, product_id, sku, price, track_stock) values (p_tenant, pid, 'SVC-CHARGE', 0, false)
      on conflict (tenant_id, sku) do update set track_stock = false returning id into vid;
    update ext_settings set service_variant_id = vid where tenant_id = p_tenant;
  end if;
  if (select delivery_variant_id from ext_settings where tenant_id = p_tenant) is null then
    insert into products (tenant_id, name, kind, on_menu) values (p_tenant, 'Delivery fee', 'service', false) returning id into pid;
    insert into product_variants (tenant_id, product_id, sku, price, track_stock) values (p_tenant, pid, 'DELIVERY-FEE', 0, false)
      on conflict (tenant_id, sku) do update set track_stock = false returning id into vid;
    update ext_settings set delivery_variant_id = vid where tenant_id = p_tenant;
  end if;
end $$;

create or replace function public.ext_module_on()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.module = 'EXT' and new.enabled then perform ensure_ext_defaults(new.tenant_id); end if;
  return null;
end $$;
create trigger trg_ext_module_on after insert or update on public.tenant_modules for each row execute function public.ext_module_on();
do $$ declare t record; begin
  for t in select tenant_id from public.tenant_modules where module = 'EXT' and enabled loop
    perform public.ensure_ext_defaults(t.tenant_id);
  end loop;
end $$;

create or replace function public.next_order_no(p_outlet uuid)
returns text language plpgsql security definer set search_path = public as $$
declare d date := (now() at time zone tenant_tz((select tenant_id from outlets where id = p_outlet), p_outlet))::date; n int;
begin
  insert into order_counters (outlet_id, day) values (p_outlet, d) on conflict do nothing;
  update order_counters set next_no = next_no + 1 where outlet_id = p_outlet and day = d returning next_no - 1 into n;
  return '#' || lpad(n::text, 3, '0');
end $$;

-- Find or create a customer contact by phone/email
create or replace function public.contact_for(p_tenant uuid, p_name text, p_phone text, p_email text, p_source text)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid; ph text := norm_phone(p_phone); em text := lower(nullif(trim(p_email), ''));
begin
  if ph is null and em is null then return null; end if;
  select id into cid from contacts
  where tenant_id = p_tenant and ((ph is not null and norm_phone(phone) = ph) or (em is not null and lower(email) = em))
  order by created_at limit 1;
  if cid is null then
    insert into contacts (tenant_id, kind, name, phone, email, source, lifecycle)
    values (p_tenant, 'customer', coalesce(nullif(trim(p_name), ''), coalesce(p_phone, em)), nullif(trim(p_phone), ''), em, p_source, 'customer')
    returning id into cid;
  end if;
  return cid;
end $$;

create or replace function public.order_recalc(p_order uuid)
returns void language sql security definer set search_path = public as $$
  update orders set items_total = coalesce((select sum(round(qty * (unit_price + modifiers_total), 2)) from order_items
                                            where order_id = p_order and status <> 'void'), 0)
  where id = p_order;
$$;

create or replace function public.order_item_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform order_recalc(coalesce(new.order_id, old.order_id));
  return null;
end $$;
create trigger trg_order_item_after after insert or update or delete on public.order_items for each row execute function public.order_item_after();

-- Message the customer about their order (if they left a phone/email)
create or replace function public.notify_order_customer(p_order uuid, p_text text)
returns void language plpgsql security definer set search_path = public as $$
declare o orders; base text; biz text;
begin
  select * into o from orders where id = p_order;
  if o.customer_phone is null and o.customer_email is null then return; end if;
  select web_base_url into base from ext_settings where tenant_id = o.tenant_id;
  select name into biz from tenants where id = o.tenant_id;
  insert into outbound_messages (tenant_id, channel, to_address, subject, body)
  values (o.tenant_id, case when o.customer_email is not null then 'email' else 'whatsapp' end,
          coalesce(lower(o.customer_email), norm_phone(o.customer_phone)),
          biz || ' order ' || o.order_no,
          biz || ': order ' || o.order_no || ' ' || p_text
          || case when base is not null then ' Track it: ' || rtrim(base, '/') || '/order.html?o=' || o.track_token else '' end);
end $$;

-- ===== Taking orders (staff) =====
create or replace function public.open_order(p_outlet uuid, p_channel text, p_table uuid default null, p_guests int default null,
                                             p_customer jsonb default '{}')
returns uuid language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; v_id uuid; st ext_settings; v_contact uuid; v_fulfil text;
begin
  select tenant_id into v_tenant from outlets where id = p_outlet;
  if v_tenant is null or not has_perm(v_tenant, 'ord.take') then raise exception 'Not allowed'; end if;
  if p_table is not null then
    if not exists (select 1 from dining_tables where id = p_table and outlet_id = p_outlet and active) then raise exception 'Unknown table'; end if;
    select id into v_id from orders where table_id = p_table and status in ('pending','open','ready');
    if v_id is not null then return v_id; end if;
  end if;
  select * into st from ext_settings where tenant_id = v_tenant;
  v_contact := contact_for(v_tenant, p_customer->>'name', p_customer->>'phone', p_customer->>'email', 'walk-in');
  v_fulfil := case p_channel when 'dine_in' then 'here' when 'delivery' then 'delivery' else 'pickup' end;
  insert into orders (tenant_id, outlet_id, order_no, channel, table_id, guests, contact_id, customer_name, customer_phone, customer_email,
                      fulfilment, delivery_address, delivery_postcode, delivery_fee, external_provider, external_ref, notes,
                      service_charge_pct, status, accepted_at)
  values (v_tenant, p_outlet, next_order_no(p_outlet), p_channel, p_table, p_guests, v_contact,
          nullif(trim(p_customer->>'name'), ''), nullif(trim(p_customer->>'phone'), ''), lower(nullif(trim(p_customer->>'email'), '')),
          v_fulfil, nullif(trim(p_customer->>'address'), ''), nullif(trim(p_customer->>'postcode'), ''),
          coalesce((p_customer->>'delivery_fee')::numeric, 0),
          nullif(p_customer->>'external_provider', ''), nullif(p_customer->>'external_ref', ''), nullif(trim(p_customer->>'notes'), ''),
          case when p_channel = 'dine_in' or not coalesce(st.service_charge_dine_in_only, true) then coalesce(st.service_charge_pct, 0) else 0 end,
          'open', now())
  returning id into v_id;
  return v_id;
end $$;

-- Validates items against the menu and modifier rules; used by staff and the public ordering page.
-- p_items: [{"variant_id":"…","qty":1,"modifier_ids":["…"],"note":"no onion","course":1}]
create or replace function public.order_add_items_internal(p_order uuid, p_items jsonb, p_source text, p_status text)
returns int language plpgsql security definer set search_path = public as $$
declare o orders; it jsonb; v product_variants; p products; mods jsonb; mtotal numeric; g record; cnt int; n int := 0; q numeric;
begin
  select * into o from orders where id = p_order for update;
  if o.status not in ('pending','open','ready') then raise exception 'Order is %', o.status; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then raise exception 'No items'; end if;
  if jsonb_array_length(p_items) > 40 then raise exception 'Too many lines in one go'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    select * into v from product_variants where id = (it->>'variant_id')::uuid and tenant_id = o.tenant_id and active;
    if not found then raise exception 'Unknown item'; end if;
    select * into p from products where id = v.product_id;
    if not p.active then raise exception '% is not available', p.name; end if;
    if p.sold_out then raise exception '% is sold out', p.name; end if;
    q := coalesce((it->>'qty')::numeric, 1);
    if q <= 0 or q > 50 then raise exception 'Check the quantity for %', p.name; end if;
    -- modifiers: must belong to this product's groups and respect min/max per group
    select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'price', m.price_delta, 'group_id', m.group_id) order by mg.name, m.sort_order), '[]'),
           coalesce(sum(m.price_delta), 0)
      into mods, mtotal
    from modifiers m join modifier_groups mg on mg.id = m.group_id
    join product_modifier_groups pmg on pmg.group_id = m.group_id and pmg.product_id = p.id
    where m.active and m.id in (select (x)::uuid from jsonb_array_elements_text(coalesce(it->'modifier_ids', '[]')) x);
    if jsonb_array_length(mods) <> jsonb_array_length(coalesce(it->'modifier_ids', '[]')) then
      raise exception 'An option chosen for % is not available', p.name;
    end if;
    for g in select mg.* from modifier_groups mg join product_modifier_groups pmg on pmg.group_id = mg.id where pmg.product_id = p.id loop
      select count(*) into cnt from jsonb_array_elements(mods) x where (x->>'group_id')::uuid = g.id;
      if cnt < g.min_select then raise exception 'Choose % for %', g.name, p.name; end if;
      if cnt > g.max_select then raise exception 'Choose at most % for % (%)', g.max_select, g.name, p.name; end if;
    end loop;
    insert into order_items (tenant_id, order_id, variant_id, name, qty, unit_price, modifiers, modifiers_total, note, course, station_id,
                             status, source, sent_at)
    values (o.tenant_id, o.id, v.id, p.name || coalesce(' — ' || v.name, ''), q, v.price, mods, mtotal,
            left(nullif(trim(it->>'note'), ''), 200), coalesce((it->>'course')::int, 1), p.station_id,
            p_status, p_source, case when p_status = 'sent' then now() end);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.add_order_items(p_order uuid, p_items jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  select * into o from orders where id = p_order;
  if not found or not has_perm(o.tenant_id, 'ord.take') then raise exception 'Not allowed'; end if;
  return order_add_items_internal(p_order, p_items, 'staff', 'new');
end $$;

-- Send new items to the kitchen (and accept a pending QR/online order)
create or replace function public.send_order(p_order uuid)
returns int language plpgsql security definer set search_path = public as $$
declare o orders; n int;
begin
  select * into o from orders where id = p_order for update;
  if not found or not has_perm(o.tenant_id, 'ord.take') then raise exception 'Not allowed'; end if;
  if o.status not in ('pending','open','ready') then raise exception 'Order is %', o.status; end if;
  update order_items set status = 'sent', sent_at = now() where order_id = o.id and status = 'new';
  get diagnostics n = row_count;
  if o.status = 'pending' then
    update orders set status = 'open', accepted_at = now() where id = o.id;
    perform notify_order_customer(o.id, 'has been accepted and is being prepared.');
  elsif n > 0 and o.status = 'ready' then
    update orders set status = 'open', ready_at = null where id = o.id;
  end if;
  return n;
end $$;

-- Kitchen display: move items along; when everything is ready the order is ready
create or replace function public.set_items_status(p_items uuid[], p_status text)
returns int language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; n int; o record;
begin
  if p_status not in ('preparing','ready','served','sent') then raise exception 'Unknown status'; end if;
  select distinct tenant_id into v_tenant from order_items where id = any(p_items);
  if v_tenant is null then return 0; end if;
  if (select count(distinct tenant_id) from order_items where id = any(p_items)) > 1 then raise exception 'Mixed businesses'; end if;
  if not (has_perm(v_tenant, 'ord.kitchen') or (p_status = 'served' and has_perm(v_tenant, 'ord.take'))) then raise exception 'Not allowed'; end if;
  update order_items set status = p_status,
    ready_at = case when p_status = 'ready' then now() when p_status = 'sent' then null else ready_at end,
    served_at = case when p_status = 'served' then now() else served_at end
  where id = any(p_items) and status not in ('void','new');
  get diagnostics n = row_count;
  for o in select distinct order_id from order_items where id = any(p_items) loop
    if not exists (select 1 from order_items where order_id = o.order_id and status in ('new','sent','preparing'))
       and exists (select 1 from orders where id = o.order_id and status = 'open') then
      update orders set status = 'ready', ready_at = now() where id = o.order_id and channel <> 'dine_in';
      if found then perform notify_order_customer(o.order_id, 'is ready.'); end if;
    end if;
  end loop;
  return n;
end $$;

create or replace function public.void_order_item(p_item uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare i order_items; o orders;
begin
  select * into i from order_items where id = p_item;
  select * into o from orders where id = i.order_id;
  if not found or not has_perm(o.tenant_id, 'ord.take') then raise exception 'Not allowed'; end if;
  if o.status not in ('pending','open','ready') then raise exception 'Order is %', o.status; end if;
  if i.status = 'new' then
    delete from order_items where id = i.id;           -- never sent: just remove
  else
    if not has_perm(o.tenant_id, 'ord.void') then raise exception 'A manager must void items already sent to the kitchen'; end if;
    if coalesce(length(trim(p_reason)), 0) < 3 then raise exception 'Give a reason'; end if;
    update order_items set status = 'void', void_reason = trim(p_reason), voided_by = auth.uid() where id = i.id;
  end if;
end $$;

create or replace function public.move_order_table(p_order uuid, p_table uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  select * into o from orders where id = p_order;
  if not found or not has_perm(o.tenant_id, 'ord.take') then raise exception 'Not allowed'; end if;
  if not exists (select 1 from dining_tables where id = p_table and outlet_id = o.outlet_id and active) then raise exception 'Unknown table'; end if;
  if exists (select 1 from orders where table_id = p_table and status in ('pending','open','ready') and id <> o.id) then
    raise exception 'That table already has an open order';
  end if;
  update orders set table_id = p_table, channel = 'dine_in' where id = o.id;
end $$;

create or replace function public.cancel_order(p_order uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  select * into o from orders where id = p_order for update;
  if not found or not has_perm(o.tenant_id, 'ord.take') then raise exception 'Not allowed'; end if;
  if o.status in ('completed','cancelled') then raise exception 'Order is %', o.status; end if;
  if exists (select 1 from order_items where order_id = o.id and status not in ('new','void')) and not has_perm(o.tenant_id, 'ord.void') then
    raise exception 'A manager must cancel an order that the kitchen has started';
  end if;
  if coalesce(length(trim(p_reason)), 0) < 3 then raise exception 'Give a reason'; end if;
  update order_items set status = 'void', void_reason = 'Order cancelled' where order_id = o.id and status <> 'void';
  update orders set status = 'cancelled', cancelled_at = now(), cancel_reason = trim(p_reason) where id = o.id;
  if o.status = 'pending' or o.source in ('web','qr') then
    perform notify_order_customer(o.id, 'could not be accepted: ' || trim(p_reason));
  end if;
end $$;

-- Lines that will be sold at checkout (items + service charge + delivery fee), with tax as the POS will charge it
create or replace function public.order_quote(p_order uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o orders; st ext_settings; lines jsonb := '[]'; r record; t record; v_net numeric; v_tax numeric; v_tot numeric;
        sub numeric := 0; tax numeric := 0; total numeric := 0; svc numeric; unlinked int;
begin
  select * into o from orders where id = p_order;
  if not found or not (has_perm(o.tenant_id, 'ord.view') or has_perm(o.tenant_id, 'pos.sale.create')) then raise exception 'Not allowed'; end if;
  select * into st from ext_settings where tenant_id = o.tenant_id;
  select count(*) into unlinked from order_items where order_id = o.id and status <> 'void' and variant_id is null;
  for r in
    select x.variant_id, x.name, x.qty, x.price, pr.tax_code from (
      select oi.variant_id, oi.name || case when jsonb_array_length(oi.modifiers) > 0
               then ' (' || (select string_agg(m->>'name', ', ') from jsonb_array_elements(oi.modifiers) m) || ')' else '' end as name,
             oi.qty, oi.unit_price + oi.modifiers_total as price, oi.created_at
      from order_items oi where oi.order_id = o.id and oi.status <> 'void' and oi.variant_id is not null
      union all
      select st.service_variant_id, 'Service charge ' || rtrim(to_char(o.service_charge_pct, 'FM990.##'), '.') || '%', 1,
             round(o.items_total * o.service_charge_pct / 100, 2), 'infinity'::timestamptz
      where o.service_charge_pct > 0 and o.items_total > 0
      union all
      select st.delivery_variant_id, 'Delivery fee', 1, o.delivery_fee, 'infinity'::timestamptz where o.delivery_fee > 0
    ) x join product_variants pv on pv.id = x.variant_id join products pr on pr.id = pv.product_id
    order by x.created_at
  loop
    select * into t from resolve_tax(o.tenant_id, o.outlet_id, r.tax_code, current_date);
    v_net := round(r.price * r.qty, 2);
    if coalesce(t.inclusive, false) then v_tax := round(v_net - v_net / (1 + coalesce(t.rate, 0)), 2); v_tot := v_net;
    else v_tax := round(v_net * coalesce(t.rate, 0), 2); v_tot := v_net + v_tax; end if;
    lines := lines || jsonb_build_object('variant_id', r.variant_id, 'name', r.name, 'qty', r.qty, 'unit_price', r.price,
                                         'tax', v_tax, 'total', v_tot, 'tax_name', t.name);
    sub := sub + v_net; tax := tax + v_tax; total := total + v_tot;
  end loop;
  return jsonb_build_object('order_no', o.order_no, 'lines', lines, 'subtotal', sub, 'tax', tax, 'total', total,
                            'unlinked_items', unlinked, 'prepaid', o.prepaid, 'prepaid_amount', o.prepaid_amount);
end $$;

-- Pay and close: becomes a normal POS sale (receipt, stock, accounts, loyalty)
create or replace function public.checkout_order(p_order uuid, p_payments jsonb, p_shift uuid default null, p_client_sale_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare o orders; q jsonb; v_sale sales; l jsonb; v_lines jsonb := '[]';
begin
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'Unknown order'; end if;
  if o.status in ('completed','cancelled') then raise exception 'Order is %', o.status; end if;
  if exists (select 1 from order_items where order_id = o.id and status = 'new') then
    raise exception 'Some items were not sent to the kitchen — send or remove them first';
  end if;
  q := order_quote(o.id);
  if (q->>'unlinked_items')::int > 0 then raise exception 'Link the online items to your products (by SKU) before checkout'; end if;
  if jsonb_array_length(q->'lines') = 0 then raise exception 'Nothing to charge'; end if;
  for l in select * from jsonb_array_elements(q->'lines') loop
    v_lines := v_lines || jsonb_build_object('variant_id', l->>'variant_id', 'qty', (l->>'qty')::numeric, 'unit_price', (l->>'unit_price')::numeric);
  end loop;
  v_sale := complete_sale(jsonb_build_object(
    'outlet_id', o.outlet_id, 'shift_id', p_shift, 'client_sale_id', coalesce(p_client_sale_id, gen_random_uuid()),
    'customer_id', o.contact_id, 'lines', v_lines, 'payments', p_payments,
    'note', 'Order ' || o.order_no || coalesce(' · ' || (select name from dining_tables where id = o.table_id), '')
            || coalesce(' · ' || o.external_provider || ' ' || o.external_ref, '')));
  update order_items set status = 'served', served_at = coalesce(served_at, now()) where order_id = o.id and status in ('sent','preparing','ready');
  update orders set status = 'completed', completed_at = now(), sale_id = v_sale.id where id = o.id;
  update bookings set status = 'completed', sale_id = v_sale.id where order_id = o.id and status = 'arrived';
  return jsonb_build_object('sale_id', v_sale.id, 'receipt_no', v_sale.receipt_no, 'total', v_sale.total);
end $$;

-- Delivery
create or replace function public.assign_rider(p_order uuid, p_rider uuid)
returns void language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  select * into o from orders where id = p_order;
  if not found or not has_perm(o.tenant_id, 'ord.take') then raise exception 'Not allowed'; end if;
  if o.fulfilment <> 'delivery' then raise exception 'Not a delivery order'; end if;
  if p_rider is not null and not exists (select 1 from memberships m join role_permissions rp on rp.role_id = m.role_id
       where m.tenant_id = o.tenant_id and m.user_id = p_rider and m.active and rp.permission_code = 'ord.deliver') then
    raise exception 'That person is not set up as a rider';
  end if;
  update orders set rider_id = p_rider where id = o.id;
end $$;

create or replace function public.delivery_update(p_order uuid, p_status text)
returns void language plpgsql security definer set search_path = public as $$
declare o orders;
begin
  select * into o from orders where id = p_order for update;
  if not found then raise exception 'Unknown order'; end if;
  if not (has_perm(o.tenant_id, 'ord.take') or (o.rider_id = auth.uid() and has_perm(o.tenant_id, 'ord.deliver'))) then
    raise exception 'Not allowed';
  end if;
  if p_status = 'out_for_delivery' then
    if o.status not in ('open','ready') then raise exception 'Order is %', o.status; end if;
    update orders set status = 'out_for_delivery', dispatched_at = now() where id = o.id;
    perform notify_order_customer(o.id, 'is on the way.');
  elsif p_status = 'delivered' then
    if o.status <> 'out_for_delivery' then raise exception 'Order is not out for delivery'; end if;
    update orders set status = 'delivered', delivered_at = now() where id = o.id;
  else
    raise exception 'Unknown status';
  end if;
end $$;

-- ===== Public (customer) RPCs — no login =====
-- Key = a table's QR token (order at the table) or the business online key (pickup / delivery / bookings)
create or replace function public.resolve_public_key(p_key text, out tenant_id uuid, out outlet_id uuid, out table_id uuid, out mode text)
language plpgsql stable security definer set search_path = public as $$
begin
  select t.tenant_id, t.outlet_id, t.id, 'table' into tenant_id, outlet_id, table_id, mode
  from dining_tables t join ext_settings s on s.tenant_id = t.tenant_id
  where t.qr_token = p_key and t.active and s.qr_ordering;
  if tenant_id is null then
    select s.tenant_id, (select o.id from outlets o where o.tenant_id = s.tenant_id order by o.created_at limit 1), null, 'online'
      into tenant_id, outlet_id, table_id, mode
    from ext_settings s where s.online_key = p_key;
  end if;
  if tenant_id is null or length(coalesce(p_key, '')) < 32
     or not exists (select 1 from tenant_modules m where m.tenant_id = resolve_public_key.tenant_id and m.module = 'EXT' and m.enabled) then
    raise exception 'This link is not valid';
  end if;
end $$;

create or replace function public.open_now(p_outlet uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select case when not exists (select 1 from business_hours where outlet_id = p_outlet) then true
    else exists (select 1 from business_hours h
                 where h.outlet_id = p_outlet
                   and h.weekday = extract(isodow from now() at time zone tenant_tz(h.tenant_id, p_outlet))::int
                   and (now() at time zone tenant_tz(h.tenant_id, p_outlet))::time between h.opens and h.closes) end;
$$;

create or replace function public.public_menu(p_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare k record; st ext_settings; biz tenants;
begin
  select * into k from resolve_public_key(p_key);
  select * into st from ext_settings where tenant_id = k.tenant_id;
  select * into biz from tenants where id = k.tenant_id;
  return jsonb_build_object(
    'business', biz.name, 'currency', biz.base_currency, 'mode', k.mode,
    'table', (select name from dining_tables where id = k.table_id),
    'outlet', (select name from outlets where id = k.outlet_id),
    'open_now', open_now(k.outlet_id),
    'ordering', case when k.mode = 'table' then st.qr_ordering else st.online_ordering end,
    'pickup', st.pickup_enabled, 'delivery', st.delivery_enabled, 'prep_minutes', st.prep_minutes,
    'service_charge_pct', case when k.mode = 'table' or not st.service_charge_dine_in_only then st.service_charge_pct else 0 end,
    'zones', (select coalesce(jsonb_agg(jsonb_build_object('id', z.id, 'name', z.name, 'fee', z.fee, 'min_order', z.min_order, 'postcodes', z.postcodes) order by z.fee), '[]')
              from delivery_zones z where z.outlet_id = k.outlet_id and z.active),
    'categories', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.sort_order, c.name), '[]')
                   from categories c where c.tenant_id = k.tenant_id
                     and exists (select 1 from products p where p.category_id = c.id and p.on_menu and p.active)),
    'items', (select coalesce(jsonb_agg(jsonb_build_object(
                'product_id', p.id, 'variant_id', v.id, 'name', p.name, 'variant', v.name, 'description', p.description,
                'category_id', p.category_id, 'price', v.price, 'sold_out', p.sold_out,
                'groups', (select coalesce(jsonb_agg(jsonb_build_object('id', g.id, 'name', g.name, 'min', g.min_select, 'max', g.max_select,
                             'options', (select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'name', m.name, 'price', m.price_delta) order by m.sort_order, m.name), '[]')
                                         from modifiers m where m.group_id = g.id and m.active)) order by pmg.sort_order, g.name), '[]')
                           from product_modifier_groups pmg join modifier_groups g on g.id = pmg.group_id where pmg.product_id = p.id))
              order by p.menu_sort, p.name, v.price), '[]')
              from products p join product_variants v on v.product_id = p.id and v.active
              where p.tenant_id = k.tenant_id and p.on_menu and p.active and p.kind <> 'bundle'
                and v.id is distinct from st.service_variant_id and v.id is distinct from st.delivery_variant_id)
  );
end $$;

-- p_customer: {"name","phone","email","note","fulfilment":"here|pickup|delivery","address","postcode","zone_id","scheduled_for"}
create or replace function public.public_place_order(p_key text, p_items jsonb, p_customer jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k record; st ext_settings; o orders; v_id uuid; z delivery_zones; v_fulfil text; v_status text; recent int; ph text; v_contact uuid;
begin
  select * into k from resolve_public_key(p_key);
  select * into st from ext_settings where tenant_id = k.tenant_id;
  ph := norm_phone(p_customer->>'phone');
  if k.mode = 'table' then
    if not st.qr_ordering then raise exception 'Ordering at the table is switched off — please ask the staff'; end if;
    select count(*) into recent from order_items oi join orders oo on oo.id = oi.order_id
      where oo.table_id = k.table_id and oi.source = 'qr' and oi.created_at > now() - interval '10 minutes';
    if recent > 60 then raise exception 'Too many orders from this table — please ask the staff'; end if;
    v_fulfil := 'here';
  else
    if not st.online_ordering then raise exception 'Online ordering is closed'; end if;
    if not open_now(k.outlet_id) and p_customer->>'scheduled_for' is null then raise exception 'We are closed right now — choose a later time'; end if;
    if ph is null or length(ph) < 9 then raise exception 'Enter your phone number'; end if;
    if coalesce(length(trim(p_customer->>'name')), 0) < 2 then raise exception 'Enter your name'; end if;
    select count(*) into recent from orders where tenant_id = k.tenant_id and norm_phone(customer_phone) = ph and status = 'pending';
    if recent >= 3 then raise exception 'You already have orders waiting to be accepted'; end if;
    select count(*) into recent from orders where tenant_id = k.tenant_id and status = 'pending' and source = 'web';
    if recent >= 50 then raise exception 'We are very busy — please try again shortly'; end if;
    v_fulfil := coalesce(p_customer->>'fulfilment', 'pickup');
    if v_fulfil not in ('pickup','delivery') then raise exception 'Choose pickup or delivery'; end if;
    if v_fulfil = 'pickup' and not st.pickup_enabled then raise exception 'Pickup is not available'; end if;
    if v_fulfil = 'delivery' then
      if not st.delivery_enabled then raise exception 'Delivery is not available'; end if;
      select * into z from delivery_zones where id = (p_customer->>'zone_id')::uuid and outlet_id = k.outlet_id and active;
      if not found then raise exception 'Choose your delivery area'; end if;
      if cardinality(z.postcodes) > 0 and not (coalesce(trim(p_customer->>'postcode'), '') = any(z.postcodes)) then
        raise exception 'We don''t deliver to that postcode in %', z.name;
      end if;
      if coalesce(length(trim(p_customer->>'address')), 0) < 10 then raise exception 'Enter your full delivery address'; end if;
    end if;
    if (p_customer->>'scheduled_for') is not null
       and ((p_customer->>'scheduled_for')::timestamptz < now() or (p_customer->>'scheduled_for')::timestamptz > now() + interval '7 days') then
      raise exception 'Choose a time within the next 7 days';
    end if;
  end if;

  if k.mode = 'table' then
    select * into o from orders where table_id = k.table_id and status in ('pending','open','ready');
  end if;
  if o.id is null then
    v_contact := contact_for(k.tenant_id, p_customer->>'name', p_customer->>'phone', p_customer->>'email', case when k.mode = 'table' then 'qr' else 'website' end);
    insert into orders (tenant_id, outlet_id, order_no, channel, source, table_id, status, contact_id, customer_name, customer_phone, customer_email,
                        notes, fulfilment, scheduled_for, delivery_address, delivery_postcode, delivery_zone_id, delivery_fee, service_charge_pct)
    values (k.tenant_id, k.outlet_id, next_order_no(k.outlet_id), case when k.mode = 'table' then 'dine_in' else 'online' end,
            case when k.mode = 'table' then 'qr' else 'web' end, k.table_id,
            case when k.mode = 'table' and st.qr_auto_send then 'open' else 'pending' end, v_contact,
            left(nullif(trim(p_customer->>'name'), ''), 80), left(nullif(trim(p_customer->>'phone'), ''), 30),
            lower(left(nullif(trim(p_customer->>'email'), ''), 120)), left(nullif(trim(p_customer->>'note'), ''), 300),
            v_fulfil, (p_customer->>'scheduled_for')::timestamptz,
            case when v_fulfil = 'delivery' then left(trim(p_customer->>'address'), 300) end,
            case when v_fulfil = 'delivery' then left(trim(p_customer->>'postcode'), 10) end,
            case when v_fulfil = 'delivery' then z.id end, case when v_fulfil = 'delivery' then z.fee else 0 end,
            case when k.mode = 'table' or not st.service_charge_dine_in_only then st.service_charge_pct else 0 end)
    returning * into o;
  end if;
  perform order_add_items_internal(o.id, p_items, 'qr',
    case when k.mode = 'table' and st.qr_auto_send and o.status <> 'pending' then 'sent' else 'new' end);
  select * into o from orders where id = o.id;
  if v_fulfil = 'delivery' and o.items_total < z.min_order then
    raise exception 'Minimum order for % is %', z.name, z.min_order;
  end if;
  return jsonb_build_object('order_no', o.order_no, 'track_token', o.track_token, 'status', o.status);
end $$;

create or replace function public.public_order(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'business', t.name, 'currency', t.base_currency, 'order_no', o.order_no, 'status', o.status, 'fulfilment', o.fulfilment,
    'table', (select name from dining_tables where id = o.table_id),
    'created_at', o.created_at, 'accepted_at', o.accepted_at, 'ready_at', o.ready_at, 'dispatched_at', o.dispatched_at,
    'delivered_at', o.delivered_at, 'completed_at', o.completed_at, 'cancelled_at', o.cancelled_at, 'cancel_reason', o.cancel_reason,
    'scheduled_for', o.scheduled_for, 'items_total', o.items_total, 'delivery_fee', o.delivery_fee, 'service_charge_pct', o.service_charge_pct,
    'prep_minutes', s.prep_minutes,
    'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i.name, 'qty', i.qty, 'status', i.status,
                'price', i.unit_price + i.modifiers_total,
                'options', (select string_agg(m->>'name', ', ') from jsonb_array_elements(i.modifiers) m)) order by i.created_at), '[]')
              from order_items i where i.order_id = o.id and i.status <> 'void'))
  from orders o join tenants t on t.id = o.tenant_id left join ext_settings s on s.tenant_id = o.tenant_id
  where o.track_token = p_token and length(p_token) >= 32;
$$;

-- ===== Bookings =====
-- Free start times for a service (any resource that offers it) or a table for a party, on a local date
create or replace function public.booking_slots(p_outlet uuid, p_date date, p_service uuid default null, p_party int default 2)
returns table (slot timestamptz, resource_id uuid, table_id uuid)
language plpgsql stable security definer set search_path = public as $$
declare st ext_settings; v_tenant uuid; tz text; dur interval; step interval; h record; t timestamptz; svc booking_services; earliest timestamptz;
begin
  select tenant_id into v_tenant from outlets where id = p_outlet;
  select * into st from ext_settings where tenant_id = v_tenant;
  tz := tenant_tz(v_tenant, p_outlet);
  step := make_interval(mins => coalesce(st.booking_slot_minutes, 15));
  earliest := now() + make_interval(mins => coalesce(st.booking_min_notice_minutes, 60));
  if p_service is not null then
    select * into svc from booking_services where id = p_service and tenant_id = v_tenant and active;
    if not found then raise exception 'Unknown service'; end if;
    dur := make_interval(mins => svc.duration_minutes + svc.buffer_minutes);
  else
    dur := make_interval(mins => coalesce(st.table_booking_minutes, 90));
  end if;
  for h in select opens, closes from business_hours where outlet_id = p_outlet and weekday = extract(isodow from p_date)::int order by opens loop
    t := (p_date + h.opens) at time zone tz;
    while t + case when p_service is null then interval '60 minutes' else dur end <= (p_date + h.closes) at time zone tz loop
      if t >= earliest then
        if p_service is not null then
          return query
            select t, r.id, null::uuid from booking_resources r join resource_services rs on rs.resource_id = r.id and rs.service_id = p_service
            where r.outlet_id = p_outlet and r.active
              and not exists (select 1 from bookings b where b.resource_id = r.id and b.status in ('pending','confirmed','arrived')
                              and tstzrange(b.start_at, b.end_at) && tstzrange(t, t + dur))
            order by r.name limit 1;
        else
          return query
            select t, null::uuid, d.id from dining_tables d
            where d.outlet_id = p_outlet and d.active and d.bookable and d.seats >= p_party
              and not exists (select 1 from bookings b where b.table_id = d.id and b.status in ('pending','confirmed','arrived')
                              and tstzrange(b.start_at, b.end_at) && tstzrange(t, t + dur))
            order by d.seats, d.name limit 1;
        end if;
      end if;
      t := t + step;
    end loop;
  end loop;
end $$;

create or replace function public.booking_insert(p_outlet uuid, p_kind text, p_service uuid, p_resource uuid, p_table uuid, p_start timestamptz,
                                                 p_party int, p_name text, p_phone text, p_email text, p_notes text, p_source text, p_status text)
returns bookings language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; st ext_settings; svc booking_services; v_end timestamptz; b bookings; biz text; tz text; base text;
begin
  select tenant_id into v_tenant from outlets where id = p_outlet;
  select * into st from ext_settings where tenant_id = v_tenant;
  if coalesce(length(trim(p_name)), 0) < 2 then raise exception 'Enter a name'; end if;
  if p_party < 1 or p_party > coalesce(st.booking_max_party, 12) then raise exception 'For groups over %, please call us', st.booking_max_party; end if;
  if p_kind = 'service' then
    select * into svc from booking_services where id = p_service and tenant_id = v_tenant and active;
    if not found then raise exception 'Choose a service'; end if;
    if p_resource is null or not exists (select 1 from resource_services where resource_id = p_resource and service_id = p_service) then
      raise exception 'Choose who or where';
    end if;
    v_end := p_start + make_interval(mins => svc.duration_minutes + svc.buffer_minutes);
  else
    if p_table is not null and not exists (select 1 from dining_tables where id = p_table and outlet_id = p_outlet and seats >= p_party) then
      raise exception 'That table is too small';
    end if;
    v_end := p_start + make_interval(mins => coalesce(st.table_booking_minutes, 90));
  end if;
  begin
    insert into bookings (tenant_id, outlet_id, kind, service_id, resource_id, table_id, contact_id, name, phone, email, party_size,
                          start_at, end_at, status, source, notes)
    values (v_tenant, p_outlet, p_kind, case when p_kind = 'service' then p_service end, case when p_kind = 'service' then p_resource end,
            case when p_kind = 'table' then p_table end, contact_for(v_tenant, p_name, p_phone, p_email, 'booking'),
            left(trim(p_name), 80), left(nullif(trim(p_phone), ''), 30), lower(left(nullif(trim(p_email), ''), 120)), p_party,
            p_start, v_end, p_status, p_source, left(nullif(trim(p_notes), ''), 500))
    returning * into b;
  exception when exclusion_violation then
    raise exception 'Sorry, that time was just taken — please choose another';
  end;
  if b.phone is not null or b.email is not null then
    select name into biz from tenants where id = v_tenant;
    tz := tenant_tz(v_tenant, p_outlet);
    base := st.web_base_url;
    insert into outbound_messages (tenant_id, channel, to_address, subject, body)
    values (v_tenant, case when b.email is not null then 'email' else 'whatsapp' end, coalesce(b.email, norm_phone(b.phone)),
            biz || ' booking', 'Hi ' || split_part(b.name, ' ', 1) || ', your booking at ' || biz || ' is '
            || case when b.status = 'pending' then 'requested' else 'confirmed' end || ' for '
            || to_char(b.start_at at time zone tz, 'Dy DD Mon, HH24:MI')
            || coalesce(' — ' || svc.name, ' for ' || b.party_size || case when b.party_size = 1 then ' person' else ' people' end) || '.'
            || case when base is not null then ' Change or cancel: ' || rtrim(base, '/') || '/book.html?b=' || b.token else '' end);
  end if;
  return b;
end $$;

create or replace function public.create_booking(p_outlet uuid, p_kind text, p_start timestamptz, p_party int, p_name text,
                                                 p_phone text default null, p_email text default null, p_service uuid default null,
                                                 p_resource uuid default null, p_table uuid default null, p_notes text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_tenant uuid; b bookings; s record;
begin
  select tenant_id into v_tenant from outlets where id = p_outlet;
  if not has_perm(v_tenant, 'book.manage') then raise exception 'Not allowed'; end if;
  -- staff may leave the resource/table empty: take the first free one
  if p_kind = 'service' and p_resource is null then
    select * into s from booking_slots(p_outlet, (p_start at time zone tenant_tz(v_tenant, p_outlet))::date, p_service, p_party) x where x.slot = p_start limit 1;
    p_resource := s.resource_id;
    if p_resource is null then raise exception 'Nobody is free at that time'; end if;
  elsif p_kind = 'table' and p_table is null then
    select * into s from booking_slots(p_outlet, (p_start at time zone tenant_tz(v_tenant, p_outlet))::date, null, p_party) x where x.slot = p_start limit 1;
    p_table := s.table_id;      -- may stay empty for a request without a table
  end if;
  b := booking_insert(p_outlet, p_kind, p_service, p_resource, p_table, p_start, p_party, p_name, p_phone, p_email, p_notes, 'staff', 'confirmed');
  return b.id;
end $$;

create or replace function public.set_booking_status(p_booking uuid, p_status text)
returns uuid language plpgsql security definer set search_path = public as $$
declare b bookings; oid uuid;
begin
  select * into b from bookings where id = p_booking for update;
  if not found or not has_perm(b.tenant_id, 'book.manage') then raise exception 'Not allowed'; end if;
  if p_status not in ('confirmed','arrived','completed','no_show','cancelled') then raise exception 'Unknown status'; end if;
  if b.status in ('completed','cancelled') then raise exception 'Booking is %', b.status; end if;
  update bookings set status = p_status where id = b.id;
  -- seating a table booking opens the table's order
  if p_status = 'arrived' and b.kind = 'table' and b.table_id is not null and has_perm(b.tenant_id, 'ord.take') then
    oid := open_order(b.outlet_id, 'dine_in', b.table_id, b.party_size, jsonb_build_object('name', b.name, 'phone', b.phone, 'email', b.email));
    update bookings set order_id = oid where id = b.id;
  end if;
  return oid;
end $$;

-- Service booking checkout through the POS
create or replace function public.checkout_booking(p_booking uuid, p_payments jsonb, p_shift uuid default null, p_client_sale_id uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare b bookings; svc booking_services; pid uuid; vid uuid; v_sale sales;
begin
  select * into b from bookings where id = p_booking for update;
  if not found or not has_perm(b.tenant_id, 'book.manage') then raise exception 'Not allowed'; end if;
  if b.kind <> 'service' then raise exception 'Table bookings are paid through their order'; end if;
  if b.status in ('completed','cancelled','no_show') then raise exception 'Booking is %', b.status; end if;
  select * into svc from booking_services where id = b.service_id;
  vid := svc.variant_id;
  if vid is null then
    insert into products (tenant_id, name, kind, on_menu) values (b.tenant_id, svc.name, 'service', false) returning id into pid;
    insert into product_variants (tenant_id, product_id, sku, price, track_stock)
    values (b.tenant_id, pid, 'SVC-' || upper(substr(replace(svc.id::text, '-', ''), 1, 8)), svc.price, false) returning id into vid;
    update booking_services set variant_id = vid where id = svc.id;
  end if;
  v_sale := complete_sale(jsonb_build_object('outlet_id', b.outlet_id, 'shift_id', p_shift,
    'client_sale_id', coalesce(p_client_sale_id, gen_random_uuid()), 'customer_id', b.contact_id,
    'lines', jsonb_build_array(jsonb_build_object('variant_id', vid, 'qty', 1, 'unit_price', svc.price)),
    'payments', p_payments, 'note', 'Booking ' || svc.name || ' · ' || b.name));
  update bookings set status = 'completed', sale_id = v_sale.id where id = b.id;
  return jsonb_build_object('sale_id', v_sale.id, 'receipt_no', v_sale.receipt_no, 'total', v_sale.total);
end $$;

-- Public booking page
create or replace function public.public_booking_options(p_key text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare k record; st ext_settings;
begin
  select * into k from resolve_public_key(p_key);
  select * into st from ext_settings where tenant_id = k.tenant_id;
  if not st.booking_enabled then raise exception 'Online booking is not available'; end if;
  return jsonb_build_object(
    'business', (select name from tenants where id = k.tenant_id), 'outlet', (select name from outlets where id = k.outlet_id),
    'currency', (select base_currency from tenants where id = k.tenant_id),
    'tables', exists (select 1 from dining_tables where outlet_id = k.outlet_id and bookable and active),
    'max_party', st.booking_max_party, 'days_ahead', st.booking_days_ahead,
    'services', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'description', s.description,
                   'minutes', s.duration_minutes, 'price', s.price) order by s.name), '[]')
                 from booking_services s where s.tenant_id = k.tenant_id and s.active and s.online
                   and exists (select 1 from resource_services rs join booking_resources r on r.id = rs.resource_id
                               where rs.service_id = s.id and r.active and r.outlet_id = k.outlet_id)));
end $$;

create or replace function public.public_booking_slots(p_key text, p_date date, p_service uuid default null, p_party int default 2)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare k record; st ext_settings;
begin
  select * into k from resolve_public_key(p_key);
  select * into st from ext_settings where tenant_id = k.tenant_id;
  if not st.booking_enabled then raise exception 'Online booking is not available'; end if;
  if p_date > current_date + st.booking_days_ahead then return '[]'; end if;
  return (select coalesce(jsonb_agg(to_char(x.slot at time zone tenant_tz(k.tenant_id, k.outlet_id), 'HH24:MI') order by x.slot), '[]')
          from booking_slots(k.outlet_id, p_date, p_service, p_party) x);
end $$;

create or replace function public.public_book(p_key text, p_date date, p_time text, p_service uuid, p_party int,
                                              p_name text, p_phone text, p_email text, p_notes text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare k record; st ext_settings; s record; v_start timestamptz; b bookings; recent int;
begin
  select * into k from resolve_public_key(p_key);
  select * into st from ext_settings where tenant_id = k.tenant_id;
  if not st.booking_enabled then raise exception 'Online booking is not available'; end if;
  if norm_phone(p_phone) is null or length(norm_phone(p_phone)) < 9 then raise exception 'Enter your phone number'; end if;
  if p_party < 1 or p_party > st.booking_max_party then raise exception 'For groups over %, please call us', st.booking_max_party; end if;
  select count(*) into recent from bookings where tenant_id = k.tenant_id and norm_phone(phone) = norm_phone(p_phone)
    and status in ('pending','confirmed') and start_at > now();
  if recent >= 3 then raise exception 'You already have 3 upcoming bookings — please call us'; end if;
  v_start := (p_date + p_time::time) at time zone tenant_tz(k.tenant_id, k.outlet_id);
  select * into s from booking_slots(k.outlet_id, p_date, p_service, p_party) x where x.slot = v_start limit 1;
  if s.slot is null then raise exception 'Sorry, that time is no longer free'; end if;
  b := booking_insert(k.outlet_id, case when p_service is null then 'table' else 'service' end, p_service, s.resource_id, s.table_id,
                      v_start, p_party, p_name, p_phone, p_email, p_notes, 'web', 'confirmed');
  return jsonb_build_object('token', b.token, 'start', to_char(b.start_at at time zone tenant_tz(k.tenant_id, k.outlet_id), 'Dy DD Mon YYYY, HH24:MI'));
end $$;

create or replace function public.public_booking(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('business', t.name, 'name', b.name, 'status', b.status, 'party_size', b.party_size, 'kind', b.kind,
    'service', (select name from booking_services where id = b.service_id),
    'with', (select name from booking_resources where id = b.resource_id),
    'start', to_char(b.start_at at time zone tenant_tz(b.tenant_id, b.outlet_id), 'Dy DD Mon YYYY, HH24:MI'),
    'can_cancel', b.status in ('pending','confirmed') and b.start_at > now() + interval '2 hours')
  from bookings b join tenants t on t.id = b.tenant_id
  where b.token = p_token and length(p_token) >= 32;
$$;

create or replace function public.public_cancel_booking(p_token text)
returns void language plpgsql security definer set search_path = public as $$
declare b bookings;
begin
  select * into b from bookings where token = p_token and length(p_token) >= 32 for update;
  if not found then raise exception 'Booking not found'; end if;
  if b.status not in ('pending','confirmed') then raise exception 'This booking is %', b.status; end if;
  if b.start_at <= now() + interval '2 hours' then raise exception 'Too late to cancel online — please call us'; end if;
  update bookings set status = 'cancelled', notes = coalesce(notes || E'\n', '') || 'Cancelled online by customer' where id = b.id;
end $$;

-- Reminder messages for tomorrow's bookings (run daily by cron with the service key, or from the app)
create or replace function public.queue_booking_reminders(p_tenant uuid default null)
returns int language plpgsql security definer set search_path = public as $$
declare b record; n int := 0;
begin
  if p_tenant is not null and not has_perm(p_tenant, 'book.manage') then raise exception 'Not allowed'; end if;
  if p_tenant is null and auth.uid() is not null then raise exception 'Not allowed'; end if;
  for b in select bk.*, t.name biz from bookings bk join tenants t on t.id = bk.tenant_id
           where (p_tenant is null or bk.tenant_id = p_tenant) and bk.status = 'confirmed' and bk.reminder_sent_at is null
             and bk.start_at between now() + interval '2 hours' and now() + interval '26 hours'
             and (bk.phone is not null or bk.email is not null) loop
    insert into outbound_messages (tenant_id, channel, to_address, subject, body)
    values (b.tenant_id, case when b.email is not null then 'email' else 'whatsapp' end, coalesce(b.email, norm_phone(b.phone)),
            'Reminder: ' || b.biz, 'Reminder: you are booked at ' || b.biz || ' on '
            || to_char(b.start_at at time zone tenant_tz(b.tenant_id, b.outlet_id), 'Dy DD Mon, HH24:MI') || '. See you soon!');
    update bookings set reminder_sent_at = now() where id = b.id;
    n := n + 1;
  end loop;
  return n;
end $$;

-- ===== Shop sync (called by the shop-sync edge function with the service key) =====
-- Stock to publish: on hand at the channel outlet minus what open orders already promise
create or replace function public.shop_stock_snapshot(p_tenant uuid, p_provider text)
returns table (variant_id uuid, sku text, external_id text, external_parent_id text, inventory_item_id text, available numeric, last_pushed_qty numeric)
language sql stable security definer set search_path = public as $$
  select l.variant_id, v.sku, l.external_id, l.external_parent_id, l.inventory_item_id,
         greatest(0, floor(coalesce(sl.qty, 0) - coalesce((select sum(oi.qty) from order_items oi join orders o on o.id = oi.order_id
                              where oi.variant_id = l.variant_id and o.outlet_id = c.outlet_id and oi.status <> 'void'
                                and o.status in ('pending','open','ready','out_for_delivery','delivered')), 0))),
         l.last_pushed_qty
  from shop_links l join shop_channels c on c.tenant_id = l.tenant_id and c.provider = l.provider
  join product_variants v on v.id = l.variant_id
  left join stock_levels sl on sl.variant_id = l.variant_id and sl.outlet_id = c.outlet_id
  where l.tenant_id = p_tenant and l.provider = p_provider and v.track_stock and auth.uid() is null;
$$;

-- p: {"external_ref","number","created_at","paid":true,"total":123.4,"currency":"MYR","shipping":10,
--     "customer":{"name","email","phone"},"address":"…","postcode":"…","note":"…","items":[{"sku","name","qty","price"}]}
create or replace function public.shop_import_order(p_tenant uuid, p_provider text, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare c shop_channels; oid uuid; it jsonb; v product_variants; n int := 0;
begin
  if auth.uid() is not null then raise exception 'Not allowed'; end if;     -- service key only
  select * into c from shop_channels where tenant_id = p_tenant and provider = p_provider;
  if not found then raise exception 'Channel not set up'; end if;
  select id into oid from orders where tenant_id = p_tenant and external_provider = p_provider and external_ref = p->>'external_ref';
  if oid is not null then return oid; end if;
  insert into orders (tenant_id, outlet_id, order_no, channel, source, status, contact_id, customer_name, customer_phone, customer_email,
                      notes, fulfilment, delivery_address, delivery_postcode, delivery_fee, external_provider, external_ref,
                      prepaid, prepaid_amount, created_at, created_by)
  values (p_tenant, c.outlet_id, next_order_no(c.outlet_id), 'online', p_provider, 'pending',
          contact_for(p_tenant, p->'customer'->>'name', p->'customer'->>'phone', p->'customer'->>'email', p_provider),
          left(p->'customer'->>'name', 80), left(p->'customer'->>'phone', 30), lower(left(p->'customer'->>'email', 120)),
          left(concat_ws(' · ', p_provider || ' ' || coalesce(p->>'number', p->>'external_ref'), nullif(p->>'note', '')), 500),
          case when nullif(p->>'address', '') is null then 'pickup' else 'shipping' end,
          left(p->>'address', 300), left(p->>'postcode', 10), coalesce((p->>'shipping')::numeric, 0), p_provider, p->>'external_ref',
          coalesce((p->>'paid')::boolean, false), (p->>'total')::numeric, coalesce((p->>'created_at')::timestamptz, now()), null)
  returning id into oid;
  for it in select * from jsonb_array_elements(coalesce(p->'items', '[]')) loop
    select * into v from product_variants where tenant_id = p_tenant and sku = it->>'sku' and coalesce(it->>'sku', '') <> '';
    insert into order_items (tenant_id, order_id, variant_id, name, qty, unit_price, status, source, created_by)
    values (p_tenant, oid, v.id, left(coalesce(it->>'name', it->>'sku', 'Item'), 200), greatest((it->>'qty')::numeric, 1),
            coalesce((it->>'price')::numeric, 0), 'new', p_provider, null);
    n := n + 1;
  end loop;
  -- shipping charged by the shop goes on the sale as the delivery fee
  return oid;
end $$;

create or replace function public.set_shop_secret(p_tenant uuid, p_provider text, p_config jsonb, p_outlet uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not has_perm(p_tenant, 'ord.settings') then raise exception 'Not allowed'; end if;
  if p_provider not in ('shopify','woocommerce') then raise exception 'Unknown shop'; end if;
  if not exists (select 1 from outlets where id = p_outlet and tenant_id = p_tenant) then raise exception 'Choose the outlet that holds the stock'; end if;
  if p_provider = 'shopify' and (coalesce(p_config->>'shop_domain', '') !~ '^[a-z0-9-]+\.myshopify\.com$' or coalesce(p_config->>'access_token', '') = '') then
    raise exception 'Enter your-shop.myshopify.com and the Admin API access token';
  end if;
  if p_provider = 'woocommerce' and (coalesce(p_config->>'base_url', '') !~ '^https://' or coalesce(p_config->>'consumer_key', '') = ''
     or coalesce(p_config->>'consumer_secret', '') = '') then
    raise exception 'Enter the https:// shop address, consumer key and consumer secret';
  end if;
  insert into integration_secrets (tenant_id, provider, config) values (p_tenant, p_provider, p_config)
  on conflict (tenant_id, provider) do update set config = excluded.config, updated_at = now();
  insert into shop_channels (tenant_id, provider, outlet_id) values (p_tenant, p_provider, p_outlet)
  on conflict (tenant_id, provider) do update set outlet_id = excluded.outlet_id, enabled = true, last_error = null;
end $$;

-- ===== RLS =====
alter table public.ext_settings enable row level security;
create policy exs_read on public.ext_settings for select using (is_member(tenant_id));
create policy exs_write on public.ext_settings for update using (has_perm(tenant_id, 'ord.settings')) with check (has_perm(tenant_id, 'ord.settings'));

do $$ declare t text; begin
  foreach t in array array['business_hours','dining_areas','dining_tables','kitchen_stations','modifier_groups','modifiers',
                           'product_modifier_groups','delivery_zones','booking_services','booking_resources','resource_services'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %1$s_read on public.%1$I for select using (is_member(tenant_id))', t);
    execute format('create policy %1$s_write on public.%1$I for all using (has_perm(tenant_id, ''ord.settings'')) with check (has_perm(tenant_id, ''ord.settings''))', t);
  end loop;
end $$;

alter table public.order_counters enable row level security;

alter table public.orders enable row level security;
create policy orders_read on public.orders for select using (has_perm(tenant_id, 'ord.view') or has_perm(tenant_id, 'pos.sale.create')
  or (rider_id = auth.uid() and has_perm(tenant_id, 'ord.deliver')));
create policy orders_notes on public.orders for update using (has_perm(tenant_id, 'ord.take')) with check (has_perm(tenant_id, 'ord.take'));

-- only notes/guests/customer fields may be edited directly; everything else goes through the functions
create or replace function public.orders_guard()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') and (
       new.status is distinct from old.status or new.items_total is distinct from old.items_total or new.sale_id is distinct from old.sale_id
    or new.table_id is distinct from old.table_id or new.tenant_id is distinct from old.tenant_id or new.rider_id is distinct from old.rider_id
    or new.prepaid is distinct from old.prepaid or new.track_token is distinct from old.track_token or new.order_no is distinct from old.order_no) then
    raise exception 'Use the order actions to change that';
  end if;
  return new;
end $$;
create trigger trg_orders_guard before update on public.orders for each row execute function public.orders_guard();

alter table public.order_items enable row level security;
create policy oitems_read on public.order_items for select using (has_perm(tenant_id, 'ord.view') or has_perm(tenant_id, 'pos.sale.create')
  or exists (select 1 from orders o where o.id = order_id and o.rider_id = auth.uid()));

alter table public.bookings enable row level security;
create policy bookings_read on public.bookings for select using (has_perm(tenant_id, 'book.view') or has_perm(tenant_id, 'book.manage'));
create policy bookings_notes on public.bookings for update using (has_perm(tenant_id, 'book.manage')) with check (has_perm(tenant_id, 'book.manage'));

create or replace function public.bookings_guard()
returns trigger language plpgsql as $$
begin
  if current_user in ('authenticated','anon') and (new.status is distinct from old.status or new.start_at is distinct from old.start_at
     or new.end_at is distinct from old.end_at or new.token is distinct from old.token or new.sale_id is distinct from old.sale_id
     or new.tenant_id is distinct from old.tenant_id) then
    raise exception 'Use the booking actions to change that';
  end if;
  return new;
end $$;
create trigger trg_bookings_guard before update on public.bookings for each row execute function public.bookings_guard();

alter table public.shop_channels enable row level security;
create policy shopch_read on public.shop_channels for select using (has_perm(tenant_id, 'ord.settings'));
create policy shopch_write on public.shop_channels for update using (has_perm(tenant_id, 'ord.settings')) with check (has_perm(tenant_id, 'ord.settings'));
alter table public.shop_links enable row level security;
create policy shoplinks_read on public.shop_links for select using (has_perm(tenant_id, 'ord.settings'));

-- Staff may "86" items and set menu fields without full product rights
create or replace function public.set_menu_flags(p_product uuid, p_sold_out boolean default null, p_on_menu boolean default null, p_station uuid default null)
returns void language plpgsql security definer set search_path = public as $$
declare p products;
begin
  select * into p from products where id = p_product;
  if not found or not (has_perm(p.tenant_id, 'ord.take') or has_perm(p.tenant_id, 'ord.settings')) then raise exception 'Not allowed'; end if;
  if (p_on_menu is not null or p_station is not null) and not has_perm(p.tenant_id, 'ord.settings') then raise exception 'Not allowed'; end if;
  update products set sold_out = coalesce(p_sold_out, sold_out), on_menu = coalesce(p_on_menu, on_menu),
    station_id = coalesce(p_station, station_id) where id = p.id;
end $$;

do $$ declare t text; begin
  foreach t in array array['orders','bookings','dining_tables','ext_settings','delivery_zones','booking_services','shop_channels'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- Public RPCs: callable without login; everything else stays for signed-in users
do $$ declare f text; begin
  foreach f in array array['public_menu(text)','public_place_order(text, jsonb, jsonb)','public_order(text)',
                           'public_booking_options(text)','public_booking_slots(text, date, uuid, integer)',
                           'public_book(text, date, text, uuid, integer, text, text, text, text)',
                           'public_booking(text)','public_cancel_booking(text)'] loop
    execute format('grant execute on function public.%s to anon, authenticated', f);
  end loop;
end $$;
