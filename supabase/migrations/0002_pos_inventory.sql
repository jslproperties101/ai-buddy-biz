-- Ai buddy Biz — Batch B: POS, inventory, SKU, barcode and labeling
-- Depends on 0001_core.sql

-- ===== Permissions for this batch =====
insert into public.permissions (code, module, description) values
  ('inv.product.view','INV','View products and stock'),
  ('inv.product.manage','INV','Create/edit products, SKUs, barcodes, prices'),
  ('inv.stock.adjust','INV','Adjust, receive and transfer stock'),
  ('inv.supplier.manage','INV','Manage suppliers and purchase orders'),
  ('inv.label.print','INV','Print barcode/price labels'),
  ('pos.sale.create','POS','Ring up sales'),
  ('pos.sale.discount','POS','Give discounts above the cashier limit'),
  ('pos.sale.void','POS','Void or refund a completed sale'),
  ('pos.report.view','POS','View sales reports'),
  ('pos.shift.manage','POS','Open/close shifts and cash drawers');

-- Owner and Admin get everything; others get role-appropriate sets
insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r join public.permissions p on p.module in ('POS','INV')
where r.tenant_id is null and r.name in ('Owner','Admin');

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r,
  unnest(array['inv.product.view','inv.product.manage','inv.stock.adjust','inv.supplier.manage','inv.label.print',
               'pos.sale.create','pos.sale.discount','pos.sale.void','pos.report.view','pos.shift.manage']) c
where r.tenant_id is null and r.name = 'Manager';

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r,
  unnest(array['inv.product.view','pos.sale.create','pos.shift.manage','inv.label.print']) c
where r.tenant_id is null and r.name = 'Cashier';

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r,
  unnest(array['inv.product.view','inv.stock.adjust','inv.supplier.manage','inv.label.print']) c
where r.tenant_id is null and r.name = 'Warehouse';

insert into public.role_permissions (role_id, permission_code)
select r.id, 'inv.product.view' from public.roles r
where r.tenant_id is null and r.name in ('Accountant','Viewer');

-- ===== Catalogue =====
create table public.categories (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  parent_id uuid references public.categories(id) on delete set null,
  name text not null,
  sort_order int not null default 0
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  category_id uuid references public.categories(id) on delete set null,
  name text not null,
  description text,
  kind text not null default 'stock' check (kind in ('stock','service','non_stock','bundle')),
  unit text not null default 'pcs',
  tax_code text,                       -- resolved by the Batch C tax engine; null = default rate
  image_path text,
  active boolean not null default true,
  custom_values jsonb not null default '{}',
  created_at timestamptz not null default now()
);

create table public.product_variants (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  sku text not null,
  name text,                           -- e.g. 'Red / XL'; null for single-variant products
  attributes jsonb not null default '{}',
  price numeric(14,2) not null default 0 check (price >= 0),
  cost numeric(14,4) not null default 0 check (cost >= 0),
  track_stock boolean not null default true,
  weight_g numeric(12,2),
  hs_code text,                        -- customs code, used in Batch E
  active boolean not null default true,
  unique (tenant_id, sku)
);

create table public.barcodes (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  variant_id uuid not null references public.product_variants(id) on delete cascade,
  code text not null,
  symbology text not null default 'EAN13' check (symbology in ('EAN13','EAN8','UPCA','CODE128','CODE39','QR','DATAMATRIX','ITF14')),
  pack_qty numeric(12,3) not null default 1 check (pack_qty > 0),  -- e.g. carton barcode = 24 units
  unique (tenant_id, code)
);

-- ===== Stock =====
create table public.stock_levels (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id) on delete cascade,
  variant_id uuid not null references public.product_variants(id) on delete cascade,
  qty numeric(14,3) not null default 0,
  reorder_point numeric(14,3),
  bin_location text,
  primary key (outlet_id, variant_id)
);

create table public.stock_movements (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id),
  variant_id uuid not null references public.product_variants(id),
  qty_change numeric(14,3) not null,
  reason text not null check (reason in ('receive','sale','refund','adjust','count','transfer_out','transfer_in','damage','opening')),
  unit_cost numeric(14,4),
  ref_type text,                       -- 'sale','po','transfer'
  ref_id uuid,
  note text,
  user_id uuid default auth.uid(),
  at timestamptz not null default now()
);
create index on public.stock_movements (tenant_id, variant_id, at desc);

-- Movements are the source of truth; levels follow them
create or replace function public.apply_stock_movement()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into stock_levels (tenant_id, outlet_id, variant_id, qty)
  values (new.tenant_id, new.outlet_id, new.variant_id, new.qty_change)
  on conflict (outlet_id, variant_id) do update set qty = stock_levels.qty + excluded.qty;
  return new;
end $$;
create trigger trg_apply_stock after insert on public.stock_movements
  for each row execute function public.apply_stock_movement();

-- ===== Suppliers & purchase orders =====
create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  contact_name text, phone text, email text,
  address jsonb,
  payment_terms_days int,
  custom_values jsonb not null default '{}'
);

create table public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id),
  outlet_id uuid not null references public.outlets(id),
  status text not null default 'draft' check (status in ('draft','sent','partial','received','cancelled')),
  expected_at date,
  created_at timestamptz not null default now()
);

create table public.purchase_order_lines (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  po_id uuid not null references public.purchase_orders(id) on delete cascade,
  variant_id uuid not null references public.product_variants(id),
  qty_ordered numeric(14,3) not null check (qty_ordered > 0),
  qty_received numeric(14,3) not null default 0,
  unit_cost numeric(14,4) not null default 0
);

-- ===== POS: shifts, sales, payments =====
create table public.shifts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id),
  user_id uuid not null default auth.uid(),
  opened_at timestamptz not null default now(),
  opening_cash numeric(14,2) not null default 0,
  closed_at timestamptz,
  counted_cash numeric(14,2)
);

create table public.receipt_counters (
  outlet_id uuid primary key references public.outlets(id) on delete cascade,
  prefix text not null default 'R',
  next_no bigint not null default 1
);

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  outlet_id uuid not null references public.outlets(id),
  shift_id uuid references public.shifts(id),
  client_sale_id uuid not null,        -- generated on the device; makes offline sync safe to retry
  receipt_no text not null,
  status text not null default 'completed' check (status in ('completed','voided','refunded','partially_refunded')),
  customer_id uuid,                    -- FK added in Batch D (CRM)
  subtotal numeric(14,2) not null,
  discount_total numeric(14,2) not null default 0,
  tax_total numeric(14,2) not null default 0,
  total numeric(14,2) not null,
  currency char(3) not null,
  note text,
  cashier_id uuid not null default auth.uid(),
  sold_at timestamptz not null default now(),   -- device time (may be earlier if offline)
  synced_at timestamptz not null default now(),
  unique (tenant_id, client_sale_id),
  unique (outlet_id, receipt_no)
);
create index on public.sales (tenant_id, sold_at desc);

create table public.sale_lines (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  sale_id uuid not null references public.sales(id) on delete cascade,
  variant_id uuid not null references public.product_variants(id),
  name text not null,                  -- snapshot at time of sale
  sku text not null,
  qty numeric(14,3) not null check (qty <> 0),
  unit_price numeric(14,2) not null,
  discount numeric(14,2) not null default 0,
  tax_rate numeric(6,4) not null default 0,
  tax_amount numeric(14,2) not null default 0,
  line_total numeric(14,2) not null
);

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  sale_id uuid not null references public.sales(id) on delete cascade,
  method text not null check (method in ('cash','card','qr','ewallet','bank_transfer','voucher','store_credit','other')),
  amount numeric(14,2) not null,
  reference text,
  at timestamptz not null default now()
);

-- ===== Labels =====
create table public.label_templates (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  width_mm numeric(6,1) not null default 40,
  height_mm numeric(6,1) not null default 30,
  layout jsonb not null,               -- [{type:'barcode',field:'barcode',x,y,w,h},{type:'text',field:'name',...}]
  is_default boolean not null default false
);

-- ===== Complete a sale atomically (works for live and offline-synced sales) =====
-- p: {client_sale_id, outlet_id, shift_id?, currency?, note?, sold_at?,
--     lines:[{variant_id, qty, unit_price, discount?, tax_rate?}],
--     payments:[{method, amount, reference?}]}
create or replace function public.complete_sale(p jsonb)
returns public.sales language plpgsql security definer set search_path = public as $$
declare
  v_outlet uuid := (p->>'outlet_id')::uuid;
  v_tenant uuid;
  v_existing sales;
  v_sale sales;
  v_line jsonb;
  v_var product_variants;
  v_name text;
  v_qty numeric; v_price numeric; v_disc numeric; v_rate numeric;
  v_net numeric; v_tax numeric;
  v_sub numeric := 0; v_disc_tot numeric := 0; v_tax_tot numeric := 0;
  v_paid numeric := 0;
  v_no text;
begin
  select tenant_id into v_tenant from outlets where id = v_outlet;
  if v_tenant is null then raise exception 'Unknown outlet'; end if;
  if not has_perm(v_tenant, 'pos.sale.create') then raise exception 'Not allowed to sell'; end if;

  -- Idempotent: re-sending the same offline sale returns the original
  select * into v_existing from sales where tenant_id = v_tenant and client_sale_id = (p->>'client_sale_id')::uuid;
  if found then return v_existing; end if;

  if jsonb_array_length(coalesce(p->'lines','[]')) = 0 then raise exception 'Sale has no items'; end if;

  -- Receipt number per outlet
  insert into receipt_counters (outlet_id) values (v_outlet) on conflict do nothing;
  update receipt_counters set next_no = next_no + 1 where outlet_id = v_outlet
    returning prefix || lpad((next_no - 1)::text, 6, '0') into v_no;

  insert into sales (tenant_id, outlet_id, shift_id, client_sale_id, receipt_no, subtotal, total, currency, note, sold_at)
  values (v_tenant, v_outlet, nullif(p->>'shift_id','')::uuid, (p->>'client_sale_id')::uuid, v_no, 0, 0,
          coalesce(p->>'currency', (select base_currency from tenants where id = v_tenant)),
          p->>'note', coalesce((p->>'sold_at')::timestamptz, now()))
  returning * into v_sale;

  for v_line in select * from jsonb_array_elements(p->'lines') loop
    select * into v_var from product_variants where id = (v_line->>'variant_id')::uuid and tenant_id = v_tenant;
    if not found then raise exception 'Unknown item %', v_line->>'variant_id'; end if;
    select pr.name || coalesce(' — ' || v_var.name, '') into v_name from products pr where pr.id = v_var.product_id;

    v_qty := (v_line->>'qty')::numeric;
    v_price := coalesce((v_line->>'unit_price')::numeric, v_var.price);
    v_disc := coalesce((v_line->>'discount')::numeric, 0);
    v_rate := coalesce((v_line->>'tax_rate')::numeric, 0);
    if v_disc > 0 and v_disc > round(v_price * v_qty * 0.10, 2) and not has_perm(v_tenant, 'pos.sale.discount') then
      raise exception 'Discount above 10%% needs a manager';
    end if;
    v_net := round(v_price * v_qty - v_disc, 2);
    v_tax := round(v_net * v_rate, 2);

    insert into sale_lines (tenant_id, sale_id, variant_id, name, sku, qty, unit_price, discount, tax_rate, tax_amount, line_total)
    values (v_tenant, v_sale.id, v_var.id, v_name, v_var.sku, v_qty, v_price, v_disc, v_rate, v_tax, v_net + v_tax);

    if v_var.track_stock then
      insert into stock_movements (tenant_id, outlet_id, variant_id, qty_change, reason, unit_cost, ref_type, ref_id)
      values (v_tenant, v_outlet, v_var.id, -v_qty, 'sale', v_var.cost, 'sale', v_sale.id);
    end if;

    v_sub := v_sub + round(v_price * v_qty, 2);
    v_disc_tot := v_disc_tot + v_disc;
    v_tax_tot := v_tax_tot + v_tax;
  end loop;

  insert into payments (tenant_id, sale_id, method, amount, reference)
  select v_tenant, v_sale.id, x->>'method', (x->>'amount')::numeric, x->>'reference'
  from jsonb_array_elements(coalesce(p->'payments','[]')) x;
  select coalesce(sum(amount),0) into v_paid from payments where sale_id = v_sale.id;

  if v_paid < v_sub - v_disc_tot + v_tax_tot then
    raise exception 'Payment % is less than total %', v_paid, v_sub - v_disc_tot + v_tax_tot;
  end if;

  update sales set subtotal = v_sub, discount_total = v_disc_tot, tax_total = v_tax_tot,
                   total = v_sub - v_disc_tot + v_tax_tot
  where id = v_sale.id returning * into v_sale;
  return v_sale;
end $$;

-- ===== Void a sale (puts stock back) =====
create or replace function public.void_sale(p_sale_id uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare s sales;
begin
  select * into s from sales where id = p_sale_id;
  if not found then raise exception 'Unknown sale'; end if;
  if not has_perm(s.tenant_id, 'pos.sale.void') then raise exception 'Not allowed to void'; end if;
  if s.status <> 'completed' then raise exception 'Sale is already %', s.status; end if;
  insert into stock_movements (tenant_id, outlet_id, variant_id, qty_change, reason, ref_type, ref_id, note)
  select s.tenant_id, s.outlet_id, l.variant_id, l.qty, 'refund', 'sale', s.id, p_reason
  from sale_lines l join product_variants v on v.id = l.variant_id
  where l.sale_id = s.id and v.track_stock;
  update sales set status = 'voided', note = coalesce(note || ' | ', '') || 'VOID: ' || p_reason where id = s.id;
end $$;

-- ===== Adjust stock =====
create or replace function public.adjust_stock(p_outlet uuid, p_variant uuid, p_qty_change numeric, p_reason text, p_note text default null, p_unit_cost numeric default null)
returns void language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  select tenant_id into t from outlets where id = p_outlet;
  if not has_perm(t, 'inv.stock.adjust') then raise exception 'Not allowed to adjust stock'; end if;
  if p_reason not in ('receive','adjust','count','damage','opening') then raise exception 'Bad reason'; end if;
  if not exists (select 1 from product_variants where id = p_variant and tenant_id = t) then raise exception 'Unknown item'; end if;
  insert into stock_movements (tenant_id, outlet_id, variant_id, qty_change, reason, note, unit_cost)
  values (t, p_outlet, p_variant, p_qty_change, p_reason, p_note, p_unit_cost);
end $$;

-- ===== Transfer stock between outlets =====
create or replace function public.transfer_stock(p_from uuid, p_to uuid, p_variant uuid, p_qty numeric)
returns void language plpgsql security definer set search_path = public as $$
declare t uuid; t2 uuid; ref uuid := gen_random_uuid();
begin
  select tenant_id into t from outlets where id = p_from;
  select tenant_id into t2 from outlets where id = p_to;
  if t is distinct from t2 then raise exception 'Outlets belong to different businesses'; end if;
  if not has_perm(t, 'inv.stock.adjust') then raise exception 'Not allowed'; end if;
  if p_qty <= 0 then raise exception 'Quantity must be positive'; end if;
  insert into stock_movements (tenant_id, outlet_id, variant_id, qty_change, reason, ref_type, ref_id)
  values (t, p_from, p_variant, -p_qty, 'transfer_out', 'transfer', ref),
         (t, p_to,   p_variant,  p_qty, 'transfer_in',  'transfer', ref);
end $$;

-- ===== Barcode lookup for the scanner =====
create or replace function public.lookup_barcode(p_tenant uuid, p_code text)
returns table (variant_id uuid, product_name text, variant_name text, sku text, price numeric, pack_qty numeric)
language sql stable security definer set search_path = public as $$
  select v.id, pr.name, v.name, v.sku, v.price, b.pack_qty
  from barcodes b join product_variants v on v.id = b.variant_id join products pr on pr.id = v.product_id
  where b.tenant_id = p_tenant and b.code = p_code and is_member(p_tenant)
  union all
  select v.id, pr.name, v.name, v.sku, v.price, 1
  from product_variants v join products pr on pr.id = v.product_id
  where v.tenant_id = p_tenant and v.sku = p_code and is_member(p_tenant)
    and not exists (select 1 from barcodes b where b.tenant_id = p_tenant and b.code = p_code)
  limit 1;
$$;

-- ===== Low stock view =====
create or replace view public.low_stock with (security_invoker = true) as
select sl.tenant_id, sl.outlet_id, o.name as outlet_name, v.id as variant_id, v.sku,
       pr.name as product_name, v.name as variant_name, sl.qty, sl.reorder_point
from stock_levels sl
join product_variants v on v.id = sl.variant_id
join products pr on pr.id = v.product_id
join outlets o on o.id = sl.outlet_id
where sl.reorder_point is not null and sl.qty <= sl.reorder_point;

-- ===== Audit triggers =====
do $$ declare t text; begin
  foreach t in array array['categories','products','product_variants','barcodes','suppliers','purchase_orders','sales','label_templates'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- ===== RLS =====
do $$ declare t text; begin
  foreach t in array array['categories','products','product_variants','barcodes','label_templates'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %1$s_read on public.%1$I for select using (has_perm(tenant_id, ''inv.product.view''))', t);
    execute format('create policy %1$s_write on public.%1$I for all using (has_perm(tenant_id, ''inv.product.manage'')) with check (has_perm(tenant_id, ''inv.product.manage''))', t);
  end loop;
  foreach t in array array['suppliers','purchase_orders','purchase_order_lines'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %1$s_read on public.%1$I for select using (has_perm(tenant_id, ''inv.supplier.manage''))', t);
    execute format('create policy %1$s_write on public.%1$I for all using (has_perm(tenant_id, ''inv.supplier.manage'')) with check (has_perm(tenant_id, ''inv.supplier.manage''))', t);
  end loop;
end $$;

-- Stock: read with product view; writes only through the functions above
alter table public.stock_levels enable row level security;
alter table public.stock_movements enable row level security;
create policy stock_levels_read on public.stock_levels for select using (has_perm(tenant_id, 'inv.product.view'));
create policy stock_levels_reorder on public.stock_levels for update
  using (has_perm(tenant_id, 'inv.product.manage')) with check (has_perm(tenant_id, 'inv.product.manage'));
create policy stock_movements_read on public.stock_movements for select using (has_perm(tenant_id, 'inv.stock.adjust') or has_perm(tenant_id, 'pos.report.view'));

-- Sales: written only through complete_sale / void_sale.
-- Cashiers see their own sales; report viewers see all.
alter table public.shifts enable row level security;
alter table public.sales enable row level security;
alter table public.sale_lines enable row level security;
alter table public.payments enable row level security;
alter table public.receipt_counters enable row level security;

create policy shifts_own on public.shifts for all
  using (user_id = auth.uid() or has_perm(tenant_id, 'pos.report.view'))
  with check (user_id = auth.uid() and has_perm(tenant_id, 'pos.shift.manage'));
create policy sales_read on public.sales for select
  using (has_perm(tenant_id, 'pos.report.view') or (cashier_id = auth.uid() and is_member(tenant_id)));
create policy sale_lines_read on public.sale_lines for select
  using (exists (select 1 from sales s where s.id = sale_id));
create policy payments_read on public.payments for select
  using (exists (select 1 from sales s where s.id = sale_id));
