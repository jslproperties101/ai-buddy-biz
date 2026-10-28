-- Ai buddy Biz — Batch E: shipping, cargo, air waybills, vessels, customs by zone,
-- supplier CRM and purchasing.
-- Depends on 0001–0004.

-- ===== Modules follow the business template =====
create or replace function public.create_tenant(p_name text, p_template text default null, p_country char(2) default 'MY')
returns uuid language plpgsql security definer set search_path = public as $$
declare tid uuid; owner_role uuid; mods jsonb;
begin
  insert into tenants (name, industry_template, country_code) values (p_name, p_template, p_country) returning id into tid;
  insert into outlets (tenant_id, name) values (tid, 'Main');
  select id into owner_role from roles where tenant_id is null and name = 'Owner';
  insert into memberships (tenant_id, user_id, role_id) values (tid, auth.uid(), owner_role);
  select bundle->'modules' into mods from templates where code = p_template;
  insert into tenant_modules (tenant_id, module, enabled)
  select tid, m, true from jsonb_array_elements_text(coalesce(mods, '["POS","INV","FIN","CRM"]')) m
  on conflict (tenant_id, module) do update set enabled = true;
  return tid;
end $$;

-- Existing businesses: switch on what their template promises (FIN was missing before)
insert into public.tenant_modules (tenant_id, module, enabled)
select t.id, m, true
from public.tenants t
cross join lateral jsonb_array_elements_text(
  coalesce((select bundle->'modules' from public.templates where code = t.industry_template), '["POS","INV","FIN","CRM"]')) m
on conflict (tenant_id, module) do nothing;

update public.templates set bundle = '{"modules":["INV","FIN","CRM","LOG"]}' where code = 'logistics';
insert into public.templates (code, name, bundle) values
  ('freight_forwarder','Freight forwarder / NVOCC','{"modules":["FIN","CRM","LOG"]}'),
  ('wholesale','Wholesale & distribution','{"modules":["POS","INV","FIN","CRM","LOG"]}')
on conflict (code) do nothing;

-- ===== Permissions & roles =====
insert into public.permissions (code, module, description) values
  ('log.shipment.view','LOG','View shipments and tracking'),
  ('log.shipment.manage','LOG','Create and edit shipments, cargo, containers, charges'),
  ('log.event.add','LOG','Post tracking updates (drivers, warehouse)'),
  ('log.rate.manage','LOG','Manage freight rate cards'),
  ('log.customs.manage','LOG','Manage customs profiles and duty rates'),
  ('log.fleet.manage','LOG','Manage vessels, voyages and ports'),
  ('log.finance','LOG','Invoice shipments and post shipment costs');

insert into public.roles (tenant_id, name, is_builtin) values (null, 'Operations', true);

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r join public.permissions p on p.module = 'LOG'
where r.tenant_id is null and r.name in ('Owner','Admin','Manager')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r,
  unnest(array['log.shipment.view','log.shipment.manage','log.event.add','log.rate.manage','log.fleet.manage',
               'crm.contact.view','crm.contact.create','inv.supplier.manage','inv.product.view','fin.invoice.view']) c
where r.tenant_id is null and r.name = 'Operations'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r, unnest(array['log.shipment.view','log.event.add']) c
where r.tenant_id is null and r.name in ('Driver','Warehouse')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r, unnest(array['log.shipment.view','log.finance']) c
where r.tenant_id is null and r.name = 'Accountant'
on conflict do nothing;

-- ===== Check-digit validators =====
-- Shipping container numbers (ISO 6346), e.g. CSQU3054383
create or replace function public.iso6346_valid(p text)
returns boolean language plpgsql immutable as $$
declare c text := upper(regexp_replace(coalesce(p,''), '\s', '', 'g')); s int := 0; v int; ch text; i int;
  letters constant text := 'A10B12C13D14E15F16G17H18I19J20K21L23M24N25O26P27Q28R29S30T31U32V34W35X36Y37Z38';
begin
  if c !~ '^[A-Z]{3}[UJZ][0-9]{7}$' then return false; end if;
  for i in 1..10 loop
    ch := substr(c, i, 1);
    if ch ~ '[0-9]' then v := ch::int;
    else v := substr(letters, position(ch in letters) + 1, 2)::int; end if;
    s := s + v * (1 << (i - 1));
  end loop;
  return (s % 11) % 10 = substr(c, 11, 1)::int;
end $$;

-- Air waybills: 3-digit airline prefix + 8-digit serial; last digit = first 7 of serial mod 7
create or replace function public.awb_valid(p text)
returns boolean language sql immutable as $$
  select d ~ '^[0-9]{11}$' and (substr(d, 4, 7)::bigint % 7) = substr(d, 11, 1)::int
  from (select regexp_replace(coalesce(p,''), '[^0-9]', '', 'g') d) x;
$$;

-- IMO ship numbers: 7 digits, weights 7..2 on the first six, sum mod 10 = last digit
create or replace function public.imo_valid(p text)
returns boolean language sql immutable as $$
  select d ~ '^[0-9]{7}$' and (
    substr(d,1,1)::int*7 + substr(d,2,1)::int*6 + substr(d,3,1)::int*5 +
    substr(d,4,1)::int*4 + substr(d,5,1)::int*3 + substr(d,6,1)::int*2) % 10 = substr(d,7,1)::int
  from (select regexp_replace(upper(coalesce(p,'')), '^IMO\s*', '') d) x;
$$;

-- ===== Ports & airports =====
create table public.ports (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references public.tenants(id) on delete cascade,     -- null = shared list
  code text not null,                                                   -- UN/LOCODE (5) or IATA (3)
  name text not null,
  country_code char(2) not null,
  kind text not null check (kind in ('sea','air','inland','rail','border')),
  unique nulls not distinct (tenant_id, code, kind)
);
insert into public.ports (code, name, country_code, kind) values
  ('MYPKG','Port Klang','MY','sea'),('MYTPP','Tanjung Pelepas','MY','sea'),('MYPEN','Penang','MY','sea'),
  ('MYPGU','Pasir Gudang','MY','sea'),('MYKCH','Kuching','MY','sea'),('MYBKI','Kota Kinabalu','MY','sea'),
  ('SGSIN','Singapore','SG','sea'),('IDJKT','Jakarta (Tanjung Priok)','ID','sea'),('THLCH','Laem Chabang','TH','sea'),
  ('VNSGN','Ho Chi Minh City','VN','sea'),('VNHPH','Hai Phong','VN','sea'),('PHMNL','Manila','PH','sea'),
  ('CNSHA','Shanghai','CN','sea'),('CNNGB','Ningbo','CN','sea'),('CNSZX','Shenzhen','CN','sea'),('CNQIN','Qingdao','CN','sea'),
  ('HKHKG','Hong Kong','HK','sea'),('KRPUS','Busan','KR','sea'),('JPTYO','Tokyo','JP','sea'),('TWKHH','Kaohsiung','TW','sea'),
  ('INNSA','Nhava Sheva','IN','sea'),('AEJEA','Jebel Ali','AE','sea'),('SAJED','Jeddah','SA','sea'),
  ('NLRTM','Rotterdam','NL','sea'),('BEANR','Antwerp','BE','sea'),('DEHAM','Hamburg','DE','sea'),('GBFXT','Felixstowe','GB','sea'),
  ('USLAX','Los Angeles','US','sea'),('USLGB','Long Beach','US','sea'),('USNYC','New York / New Jersey','US','sea'),
  ('AUSYD','Sydney','AU','sea'),('AUMEL','Melbourne','AU','sea'),
  ('KUL','Kuala Lumpur Intl','MY','air'),('PEN','Penang Intl','MY','air'),('BKI','Kota Kinabalu Intl','MY','air'),
  ('SIN','Singapore Changi','SG','air'),('BKK','Bangkok Suvarnabhumi','TH','air'),('CGK','Jakarta Soekarno-Hatta','ID','air'),
  ('HKG','Hong Kong Intl','HK','air'),('PVG','Shanghai Pudong','CN','air'),('CAN','Guangzhou Baiyun','CN','air'),
  ('ICN','Seoul Incheon','KR','air'),('NRT','Tokyo Narita','JP','air'),('DXB','Dubai Intl','AE','air'),
  ('DOH','Doha Hamad','QA','air'),('LHR','London Heathrow','GB','air'),('FRA','Frankfurt','DE','air'),
  ('AMS','Amsterdam Schiphol','NL','air'),('LAX','Los Angeles Intl','US','air'),('JFK','New York JFK','US','air'),
  ('SYD','Sydney','AU','air');

-- ===== Supplier CRM =====
alter table public.suppliers
  add column category text not null default 'vendor'
    check (category in ('vendor','carrier_sea','carrier_air','trucking','forwarder','customs_broker','warehouse','agent','insurer','other')),
  add column rating smallint check (rating between 1 and 5),
  add column website text,
  add column tin text,
  add column currency char(3),
  add column lead_time_days int,
  add column iata_prefix char(3),                -- airlines: 3-digit AWB prefix
  add column scac text,                           -- shipping lines: carrier code
  add column tags text[] not null default '{}',
  add column notes text,
  add column active boolean not null default true,
  add column created_at timestamptz not null default now();

create table public.supplier_contacts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete cascade,
  name text not null, role text, phone text, email text,
  is_primary boolean not null default false
);

create table public.supplier_documents (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete cascade,
  kind text not null check (kind in ('licence','insurance','contract','certificate','tax','bank','other')),
  title text not null,
  doc_no text,
  issued_on date,
  expires_on date,
  file_path text,
  created_at timestamptz not null default now()
);

-- Activities can now belong to suppliers and shipments too
alter table public.activities add column supplier_id uuid references public.suppliers(id) on delete cascade;
alter table public.activities drop constraint activities_check;
alter table public.activities add constraint activities_owner_check
  check (contact_id is not null or deal_id is not null or supplier_id is not null);
create index on public.activities (tenant_id, supplier_id, created_at desc);

-- ===== Purchasing =====
alter table public.purchase_orders
  add column number text,
  add column currency char(3),
  add column notes text,
  add column sent_at timestamptz,
  add column received_at timestamptz,
  add column created_by uuid default auth.uid();
create unique index on public.purchase_orders (tenant_id, number);

create table public.po_counters (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  next_no bigint not null default 1
);
alter table public.po_counters enable row level security;

create or replace function public.po_before()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.number is null then
    insert into po_counters (tenant_id) values (new.tenant_id) on conflict do nothing;
    update po_counters set next_no = next_no + 1 where tenant_id = new.tenant_id
      returning 'PO-' || lpad((next_no - 1)::text, 5, '0') into new.number;
  end if;
  new.currency := coalesce(new.currency, (select base_currency from tenants where id = new.tenant_id));
  return new;
end $$;
create trigger trg_po_before before insert on public.purchase_orders for each row execute function public.po_before();

create or replace view public.po_list with (security_invoker = true) as
select po.*, s.name as supplier_name, o.name as outlet_name,
       round(coalesce((select sum(l.qty_ordered * l.unit_cost) from purchase_order_lines l where l.po_id = po.id),0), 2) as total,
       round(coalesce((select sum(l.qty_received) / nullif(sum(l.qty_ordered),0) from purchase_order_lines l where l.po_id = po.id),0), 3) as received_ratio,
       (po.status in ('sent','partial') and po.expected_at < current_date) as late
from purchase_orders po
join suppliers s on s.id = po.supplier_id
join outlets o on o.id = po.outlet_id;

create or replace function public.send_po(p_po uuid)
returns void language plpgsql security definer set search_path = public as $$
declare po purchase_orders;
begin
  select * into po from purchase_orders where id = p_po;
  if not has_perm(po.tenant_id, 'inv.supplier.manage') then raise exception 'Not allowed'; end if;
  if po.status <> 'draft' then raise exception 'PO is already %', po.status; end if;
  if not exists (select 1 from purchase_order_lines where po_id = po.id) then raise exception 'PO has no lines'; end if;
  update purchase_orders set status = 'sent', sent_at = now() where id = po.id;
end $$;

-- Receive goods: stock in at the PO cost, moving-average cost update, AP posting (via stock trigger)
-- p_lines: [{"line_id":"…","qty":5,"unit_cost":3.2}]  (unit_cost optional, defaults to PO price)
create or replace function public.receive_po(p_po uuid, p_lines jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare po purchase_orders; l jsonb; pol purchase_order_lines; q numeric; c numeric; on_hand numeric; v product_variants;
begin
  select * into po from purchase_orders where id = p_po for update;
  if not found then raise exception 'Unknown PO'; end if;
  if not has_perm(po.tenant_id, 'inv.stock.adjust') then raise exception 'Not allowed to receive stock'; end if;
  if po.status not in ('sent','partial') then raise exception 'PO is %', po.status; end if;
  for l in select * from jsonb_array_elements(p_lines) loop
    select * into pol from purchase_order_lines where id = (l->>'line_id')::uuid and po_id = po.id for update;
    if not found then raise exception 'Line not on this PO'; end if;
    q := (l->>'qty')::numeric;
    if q is null or q <= 0 then continue; end if;
    if pol.qty_received + q > pol.qty_ordered * 1.10 then
      raise exception 'Receiving % would exceed ordered % by more than 10%%', pol.qty_received + q, pol.qty_ordered;
    end if;
    c := coalesce((l->>'unit_cost')::numeric, pol.unit_cost);
    select * into v from product_variants where id = pol.variant_id for update;
    select coalesce(sum(qty),0) into on_hand from stock_levels where variant_id = v.id;
    if v.track_stock and on_hand + q > 0 then
      update product_variants set cost = round(((greatest(on_hand,0) * cost) + q * c) / (greatest(on_hand,0) + q), 4) where id = v.id;
    end if;
    insert into stock_movements (tenant_id, outlet_id, variant_id, qty_change, reason, unit_cost, ref_type, ref_id, note)
    values (po.tenant_id, po.outlet_id, v.id, q, 'receive', c, 'po', po.id, po.number);
    update purchase_order_lines set qty_received = qty_received + q, unit_cost = c where id = pol.id;
  end loop;
  update purchase_orders set
    status = case when not exists (select 1 from purchase_order_lines where po_id = po.id and qty_received < qty_ordered)
                  then 'received' else 'partial' end,
    received_at = case when not exists (select 1 from purchase_order_lines where po_id = po.id and qty_received < qty_ordered)
                       then now() else received_at end
  where id = po.id returning status into po.status;
  return po.status;
end $$;

-- ===== Vessels & voyages =====
create table public.vessels (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  imo text check (imo is null or imo_valid(imo)),
  mmsi text check (mmsi is null or mmsi ~ '^[0-9]{9}$'),
  call_sign text,
  flag char(2),
  vessel_type text not null default 'container'
    check (vessel_type in ('container','bulk','tanker','general','roro','reefer','barge','feeder','other')),
  teu_capacity int, dwt numeric(12,0),
  operator_id uuid references public.suppliers(id) on delete set null,
  own boolean not null default false,
  active boolean not null default true,
  unique (tenant_id, imo)
);

create table public.voyages (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  vessel_id uuid not null references public.vessels(id) on delete cascade,
  voyage_no text not null,
  service text,
  pol_id uuid references public.ports(id),
  pod_id uuid references public.ports(id),
  cutoff_at timestamptz,
  etd timestamptz, eta timestamptz, atd timestamptz, ata timestamptz,
  status text not null default 'scheduled' check (status in ('scheduled','departed','arrived','cancelled')),
  unique (vessel_id, voyage_no)
);

-- ===== Shipments =====
create table public.shipment_counters (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  next_no bigint not null default 1
);
alter table public.shipment_counters enable row level security;

create table public.shipments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  ref text,
  mode text not null check (mode in ('sea_fcl','sea_lcl','air','road','rail','courier')),
  direction text not null default 'export' check (direction in ('export','import','domestic','cross_trade')),
  status text not null default 'draft' check (status in
    ('draft','quoted','booked','picked_up','at_origin','departed','in_transit','arrived','customs','released','out_for_delivery','delivered','cancelled')),
  incoterm text check (incoterm in ('EXW','FCA','FAS','FOB','CFR','CIF','CPT','CIP','DAP','DPU','DDP')),
  customer_id uuid references public.contacts(id) on delete set null,     -- who pays us
  shipper_id uuid references public.contacts(id) on delete set null,
  consignee_id uuid references public.contacts(id) on delete set null,
  notify_id uuid references public.contacts(id) on delete set null,
  carrier_id uuid references public.suppliers(id) on delete set null,
  agent_id uuid references public.suppliers(id) on delete set null,      -- overseas partner
  origin_port_id uuid references public.ports(id),
  dest_port_id uuid references public.ports(id),
  pickup_address text,
  delivery_address text,
  voyage_id uuid references public.voyages(id) on delete set null,
  flight_no text,
  booking_no text,
  master_no text,                 -- MBL / MAWB
  house_no text,                  -- HBL / HAWB
  etd timestamptz, eta timestamptz, atd timestamptz, ata timestamptz, delivered_at timestamptz,
  cargo_description text,
  packages int not null default 0,
  gross_kg numeric(14,3) not null default 0,
  volume_cbm numeric(14,4) not null default 0,
  chargeable numeric(14,3) not null default 0,
  chargeable_unit text not null default 'kg',
  declared_value numeric(14,2),
  value_currency char(3),
  insured boolean not null default false,
  dangerous_goods boolean not null default false,
  un_number text check (un_number is null or un_number ~ '^UN?[0-9]{4}$'),
  dg_class text,
  temp_min_c numeric(5,1), temp_max_c numeric(5,1),
  customs_status text not null default 'not_required'
    check (customs_status in ('not_required','pending','lodged','inspection','held','cleared')),
  customs_ref text,
  public_token text not null default replace(gen_random_uuid()::text, '-', ''),
  owner_id uuid references auth.users(id) default auth.uid(),
  notes text,
  custom_values jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, ref),
  unique (public_token),
  check (eta is null or etd is null or eta >= etd),
  check (not dangerous_goods or un_number is not null)
);
create index on public.shipments (tenant_id, status, created_at desc);
create index on public.shipments (tenant_id, master_no);
create index on public.shipments (tenant_id, house_no);

alter table public.activities add column shipment_id uuid references public.shipments(id) on delete cascade;
alter table public.activities drop constraint activities_owner_check;
alter table public.activities add constraint activities_owner_check
  check (contact_id is not null or deal_id is not null or supplier_id is not null or shipment_id is not null);

create table public.shipment_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  shipment_id uuid not null references public.shipments(id) on delete cascade,
  variant_id uuid references public.product_variants(id) on delete set null,
  description text not null,
  hs_code text check (hs_code is null or hs_code ~ '^[0-9]{4,12}$'),
  origin_country char(2),
  package_type text not null default 'carton'
    check (package_type in ('carton','pallet','crate','drum','bag','roll','bundle','envelope','piece','other')),
  packages int not null default 1 check (packages > 0),
  length_cm numeric(8,1), width_cm numeric(8,1), height_cm numeric(8,1),
  weight_kg numeric(12,3) not null default 0 check (weight_kg >= 0),   -- per package
  volume_cbm numeric(14,4),                                             -- total; worked out from dims if blank
  units int,                                                            -- pieces inside, for commercial invoice
  unit_value numeric(14,2),
  value numeric(14,2),                                                  -- total value of this line
  sort_order int not null default 0
);

create table public.shipment_containers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  shipment_id uuid not null references public.shipments(id) on delete cascade,
  container_no text,
  size_type text not null check (size_type in ('20GP','40GP','40HC','45HC','20RF','40RF','20OT','40OT','20FR','40FR','20TK')),
  seal_no text,
  tare_kg numeric(10,1),
  cargo_kg numeric(12,1),
  vgm_kg numeric(12,1) generated always as (coalesce(tare_kg,0) + coalesce(cargo_kg,0)) stored,
  status text not null default 'planned'
    check (status in ('planned','empty_released','gated_in','loaded','discharged','gated_out','delivered','returned')),
  check (container_no is null or iso6346_valid(container_no))
);

create table public.shipment_events (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  shipment_id uuid not null references public.shipments(id) on delete cascade,
  code text not null check (code in
    ('booked','picked_up','at_origin','departed','in_transit','transshipment','arrived','customs','released',
     'out_for_delivery','delivered','exception','note')),
  location text,
  port_id uuid references public.ports(id),
  note text,
  at timestamptz not null default now(),
  public boolean not null default true,       -- shown on the customer tracking page
  source text not null default 'manual',
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.shipment_events (shipment_id, at desc);

create table public.shipment_charges (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  shipment_id uuid not null references public.shipments(id) on delete cascade,
  side text not null check (side in ('revenue','cost')),
  code text not null default 'freight' check (code in
    ('freight','fuel','thc','docs','customs_clearance','customs_duty','import_tax','insurance','trucking','storage',
     'handling','dg_surcharge','other')),
  description text not null,
  qty numeric(14,3) not null default 1 check (qty > 0),
  unit_price numeric(14,2) not null check (unit_price >= 0),
  currency char(3) not null,
  fx_rate numeric(14,6) not null default 1 check (fx_rate > 0),     -- to the business's base currency
  amount_base numeric(14,2) generated always as (round(qty * unit_price * fx_rate, 2)) stored,
  supplier_id uuid references public.suppliers(id) on delete set null,
  tax_code text,
  invoice_id uuid references public.invoices(id) on delete set null,
  posted_at timestamptz,                                            -- costs: posted to accounts payable
  created_at timestamptz not null default now()
);
create index on public.shipment_charges (shipment_id);

-- Totals and chargeable weight from the cargo lines
--   air:     max(gross kg, cbm × 166.67)         (IATA 6000 cm³/kg)
--   courier: max(gross kg, cbm × 200)            (5000 cm³/kg)
--   sea LCL: revenue tons W/M = max(cbm, kg/1000)
--   road/rail: max(gross kg, cbm × 333.33)       (3000 cm³/kg)
--   sea FCL: TEU from containers
create or replace function public.shipment_recalc(p_shipment uuid)
returns void language plpgsql security definer set search_path = public as $$
declare sh shipments; pk int; kg numeric; cbm numeric; teu numeric;
begin
  select * into sh from shipments where id = p_shipment;
  if not found then return; end if;
  select coalesce(sum(packages),0), coalesce(sum(packages * weight_kg),0),
         coalesce(sum(coalesce(volume_cbm, packages * length_cm * width_cm * height_cm / 1000000.0)),0)
    into pk, kg, cbm
  from shipment_items where shipment_id = sh.id;
  select coalesce(sum(case when left(size_type,2) = '20' then 1 else 2 end),0) into teu
  from shipment_containers where shipment_id = sh.id;
  update shipments set packages = pk, gross_kg = round(kg,3), volume_cbm = round(cbm,4),
    chargeable = case sh.mode
      when 'air' then round(greatest(kg, cbm * 1000 / 6.0), 1)
      when 'courier' then round(greatest(kg, cbm * 1000 / 5.0), 1)
      when 'sea_lcl' then round(greatest(cbm, kg / 1000.0), 3)
      when 'sea_fcl' then teu
      else round(greatest(kg, cbm * 1000 / 3.0), 1) end,
    chargeable_unit = case sh.mode when 'sea_lcl' then 'w/m' when 'sea_fcl' then 'teu' else 'kg' end,
    declared_value = coalesce((select sum(coalesce(value, units * unit_value)) from shipment_items where shipment_id = sh.id), sh.declared_value),
    updated_at = now()
  where id = sh.id;
end $$;

create or replace function public.shipment_child_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform shipment_recalc(coalesce(new.shipment_id, old.shipment_id));
  return null;
end $$;
create trigger trg_items_after after insert or update or delete on public.shipment_items
  for each row execute function public.shipment_child_after();
create trigger trg_containers_after after insert or update or delete on public.shipment_containers
  for each row execute function public.shipment_child_after();

create or replace function public.shipment_before()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and new.ref is null then
    insert into shipment_counters (tenant_id) values (new.tenant_id) on conflict do nothing;
    update shipment_counters set next_no = next_no + 1 where tenant_id = new.tenant_id
      returning 'SHP-' || lpad((next_no - 1)::text, 6, '0') into new.ref;
  end if;
  if new.mode = 'air' and new.master_no is not null and not awb_valid(new.master_no) then
    raise exception 'Master air waybill % has a wrong check digit', new.master_no;
  end if;
  if new.mode = 'air' and new.house_no is not null and new.house_no ~ '^[0-9 -]{11,13}$' and not awb_valid(new.house_no) then
    raise exception 'House air waybill % has a wrong check digit', new.house_no;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger trg_shipment_before before insert or update on public.shipments
  for each row execute function public.shipment_before();

create or replace function public.shipment_mode_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() = 1 then perform shipment_recalc(new.id); end if;
  return null;
end $$;
create trigger trg_shipment_mode after update of mode on public.shipments
  for each row execute function public.shipment_mode_after();

-- Tracking events move the shipment status forward and fill actual dates
create or replace function public.shipment_event_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare order_of constant text[] := array['draft','quoted','booked','picked_up','at_origin','departed','in_transit',
  'arrived','customs','released','out_for_delivery','delivered'];
  cur text; nxt text;
begin
  select status into cur from shipments where id = new.shipment_id;
  nxt := case new.code when 'transshipment' then 'in_transit' else new.code end;
  if nxt = any(order_of) and cur <> 'cancelled'
     and array_position(order_of, nxt) > coalesce(array_position(order_of, cur), 0) then
    update shipments set status = nxt where id = new.shipment_id;
  end if;
  update shipments set
    atd = case when new.code = 'departed' and atd is null then new.at else atd end,
    ata = case when new.code = 'arrived' and ata is null then new.at else ata end,
    delivered_at = case when new.code = 'delivered' then new.at else delivered_at end,
    customs_status = case when new.code = 'customs' and customs_status in ('not_required','pending') then 'lodged'
                          when new.code = 'released' then 'cleared' else customs_status end
  where id = new.shipment_id;
  return null;
end $$;
create trigger trg_shipment_event_after after insert on public.shipment_events
  for each row execute function public.shipment_event_after();

create or replace function public.add_shipment_event(p_shipment uuid, p_code text, p_location text default null,
                                                     p_note text default null, p_at timestamptz default now(), p_public boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
declare sh shipments; eid uuid;
begin
  select * into sh from shipments where id = p_shipment;
  if not found then raise exception 'Unknown shipment'; end if;
  if not (has_perm(sh.tenant_id, 'log.event.add') or has_perm(sh.tenant_id, 'log.shipment.manage')) then
    raise exception 'Not allowed to post updates';
  end if;
  if sh.status = 'cancelled' then raise exception 'Shipment is cancelled'; end if;
  if p_at > now() + interval '1 hour' then raise exception 'Update time is in the future'; end if;
  insert into shipment_events (tenant_id, shipment_id, code, location, note, at, public)
  values (sh.tenant_id, sh.id, p_code, p_location, p_note, p_at, p_public) returning id into eid;
  return eid;
end $$;

create or replace function public.cancel_shipment(p_shipment uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare sh shipments;
begin
  select * into sh from shipments where id = p_shipment;
  if not has_perm(sh.tenant_id, 'log.shipment.manage') then raise exception 'Not allowed'; end if;
  if sh.status in ('delivered','cancelled') then raise exception 'Shipment is already %', sh.status; end if;
  if exists (select 1 from shipment_charges where shipment_id = sh.id and (invoice_id is not null or posted_at is not null)) then
    raise exception 'Shipment has invoiced or posted charges; void those first';
  end if;
  update shipments set status = 'cancelled', notes = coalesce(notes || E'\n', '') || 'CANCELLED: ' || p_reason where id = sh.id;
  insert into shipment_events (tenant_id, shipment_id, code, note, public) values (sh.tenant_id, sh.id, 'exception', 'Cancelled', true);
end $$;

-- Public tracking (no login): status and milestones only — no prices, no parties
create or replace function public.track_shipment(p_token text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'ref', s.ref, 'mode', s.mode, 'status', s.status, 'business', t.name,
    'origin', op.name || ' (' || op.code || ')', 'destination', dp.name || ' (' || dp.code || ')',
    'etd', s.etd, 'eta', s.eta, 'atd', s.atd, 'ata', s.ata, 'delivered_at', s.delivered_at,
    'packages', s.packages, 'weight_kg', s.gross_kg,
    'events', coalesce((select jsonb_agg(jsonb_build_object('code', e.code, 'location', coalesce(e.location, ep.name), 'note', e.note, 'at', e.at) order by e.at desc)
                        from shipment_events e left join ports ep on ep.id = e.port_id
                        where e.shipment_id = s.id and e.public), '[]'))
  from shipments s
  join tenants t on t.id = s.tenant_id
  left join ports op on op.id = s.origin_port_id
  left join ports dp on dp.id = s.dest_port_id
  where length(coalesce(p_token,'')) >= 24 and s.public_token = p_token and s.status <> 'draft';
$$;
revoke execute on function public.track_shipment(text) from public;
grant execute on function public.track_shipment(text) to anon, authenticated;

-- ===== Money on shipments =====
create or replace view public.shipment_list with (security_invoker = true) as
select s.*,
  cu.name as customer_name, sh.name as shipper_name, co.name as consignee_name,
  ca.name as carrier_name, op.code as origin_code, op.name as origin_name, dp.code as dest_code, dp.name as dest_name,
  dp.country_code as dest_country, op.country_code as origin_country,
  v.voyage_no, ve.name as vessel_name,
  coalesce((select sum(amount_base) from shipment_charges c where c.shipment_id = s.id and c.side = 'revenue'),0) as revenue,
  coalesce((select sum(amount_base) from shipment_charges c where c.shipment_id = s.id and c.side = 'cost'),0) as cost,
  (select string_agg(container_no, ', ') from shipment_containers c where c.shipment_id = s.id and container_no is not null) as containers,
  (s.status not in ('delivered','cancelled','draft','quoted') and s.eta < now() and s.ata is null) as late
from shipments s
left join contacts cu on cu.id = s.customer_id
left join contacts sh on sh.id = s.shipper_id
left join contacts co on co.id = s.consignee_id
left join suppliers ca on ca.id = s.carrier_id
left join ports op on op.id = s.origin_port_id
left join ports dp on dp.id = s.dest_port_id
left join voyages v on v.id = s.voyage_id
left join vessels ve on ve.id = v.vessel_id;

-- Bill the customer: a draft invoice from revenue charges not yet invoiced
create or replace function public.invoice_shipment(p_shipment uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare sh shipments; inv uuid; n int;
begin
  select * into sh from shipments where id = p_shipment;
  if not found then raise exception 'Unknown shipment'; end if;
  if not (has_perm(sh.tenant_id, 'log.finance') and has_perm(sh.tenant_id, 'fin.invoice.manage')) then raise exception 'Not allowed'; end if;
  if sh.customer_id is null then raise exception 'Set the customer (who pays) first'; end if;
  if not exists (select 1 from shipment_charges where shipment_id = sh.id and side = 'revenue' and invoice_id is null) then
    raise exception 'No revenue charges left to invoice';
  end if;
  perform set_config('abb.invoice_fn', 'off', true);
  insert into invoices (tenant_id, contact_id, currency, notes)
  values (sh.tenant_id, sh.customer_id, (select base_currency from tenants where id = sh.tenant_id),
          'Shipment ' || sh.ref || coalesce(' · ' || nullif(sh.house_no,''), '') || coalesce(' · ' || nullif(sh.master_no,''), ''))
  returning id into inv;
  insert into invoice_lines (invoice_id, tenant_id, description, qty, unit_price, tax_code, sort_order)
  select inv, sh.tenant_id, c.description || case when c.currency <> (select base_currency from tenants where id = sh.tenant_id)
                                                then ' (' || c.currency || ' ' || to_char(c.qty * c.unit_price, 'FM999999990.00') || ' @ ' || c.fx_rate || ')' else '' end,
         1, c.amount_base, c.tax_code, row_number() over (order by c.created_at)
  from shipment_charges c where c.shipment_id = sh.id and c.side = 'revenue' and c.invoice_id is null;
  get diagnostics n = row_count;
  update shipment_charges set invoice_id = inv where shipment_id = sh.id and side = 'revenue' and invoice_id is null;
  return inv;
end $$;

-- If a draft shipment invoice is deleted, its charges become billable again (FK sets invoice_id null).
-- If an issued one is voided, release them too.
create or replace function public.invoice_void_release()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'void' and old.status <> 'void' then
    update shipment_charges set invoice_id = null where invoice_id = new.id;
  end if;
  return null;
end $$;
create trigger trg_invoice_void_release after update of status on public.invoices
  for each row execute function public.invoice_void_release();

-- Book supplier costs to accounts payable: Dr Freight & logistics costs, Cr Accounts payable
create or replace function public.post_shipment_costs(p_shipment uuid)
returns int language plpgsql security definer set search_path = public as $$
declare sh shipments; total numeric; n int;
begin
  select * into sh from shipments where id = p_shipment;
  if not has_perm(sh.tenant_id, 'log.finance') then raise exception 'Not allowed'; end if;
  select coalesce(sum(amount_base),0), count(*) into total, n
  from shipment_charges where shipment_id = sh.id and side = 'cost' and posted_at is null;
  if n = 0 then raise exception 'No new costs to post'; end if;
  perform post_entry(sh.tenant_id, current_date, 'Costs ' || sh.ref, 'shipment_cost', sh.id, jsonb_build_array(
    jsonb_build_object('code','5100','debit', total), jsonb_build_object('code','2200','credit', total)));
  update shipment_charges set posted_at = now() where shipment_id = sh.id and side = 'cost' and posted_at is null;
  return n;
end $$;

-- Charges can't change once invoiced / posted
create or replace function public.charge_guard()
returns trigger language plpgsql as $$
begin
  if tg_op in ('UPDATE','DELETE') and (old.invoice_id is not null or old.posted_at is not null)
     and current_setting('abb.charge_fn', true) is distinct from 'on' then
    if tg_op = 'UPDATE' and new.invoice_id is null and old.invoice_id is not null
       and row(new.side,new.code,new.description,new.qty,new.unit_price,new.currency,new.fx_rate,new.posted_at)
           is not distinct from row(old.side,old.code,old.description,old.qty,old.unit_price,old.currency,old.fx_rate,old.posted_at) then
      return new;   -- released by a voided invoice
    end if;
    raise exception 'This charge is already invoiced or posted';
  end if;
  return coalesce(new, old);
end $$;
create trigger trg_charge_guard before update or delete on public.shipment_charges
  for each row execute function public.charge_guard();

create or replace function public.ensure_chart(p_tenant uuid)
returns void language sql security definer set search_path = public as $$
  insert into accounts (tenant_id, code, name, type, is_system) values
    (p_tenant,'1000','Cash on hand','asset',true),
    (p_tenant,'1010','Card & e-payment clearing','asset',true),
    (p_tenant,'1020','Bank','asset',true),
    (p_tenant,'1100','Accounts receivable','asset',true),
    (p_tenant,'1200','Inventory','asset',true),
    (p_tenant,'2100','Tax payable','liability',true),
    (p_tenant,'2200','Accounts payable','liability',true),
    (p_tenant,'3000','Owner''s equity','equity',true),
    (p_tenant,'3100','Retained earnings','equity',true),
    (p_tenant,'4000','Sales','income',true),
    (p_tenant,'4100','Other income','income',true),
    (p_tenant,'5000','Cost of goods sold','expense',true),
    (p_tenant,'5100','Freight & logistics costs','expense',true),
    (p_tenant,'6000','Operating expenses','expense',true),
    (p_tenant,'6100','Inventory adjustments & losses','expense',true),
    (p_tenant,'6200','Loyalty rewards','expense',true)
  on conflict (tenant_id, code) do nothing;
$$;

-- ===== Freight rate cards & quoting =====
create table public.freight_rates (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  carrier_id uuid references public.suppliers(id) on delete cascade,
  mode text not null check (mode in ('sea_fcl','sea_lcl','air','road','rail','courier')),
  origin_port_id uuid not null references public.ports(id),
  dest_port_id uuid not null references public.ports(id),
  container_type text,                      -- FCL only
  unit text not null check (unit in ('container','kg','w/m','shipment')),
  min_charge numeric(14,2) not null default 0,
  buy_rate numeric(14,4) not null check (buy_rate >= 0),
  sell_rate numeric(14,4) not null check (sell_rate >= 0),
  currency char(3) not null,
  transit_days int,
  valid_from date not null default current_date,
  valid_to date not null,
  notes text,
  check (valid_to >= valid_from),
  check ((mode = 'sea_fcl') = (container_type is not null and unit = 'container'))
);
create index on public.freight_rates (tenant_id, mode, origin_port_id, dest_port_id, valid_to);

-- p_containers for FCL: {"40HC":2,"20GP":1}
create or replace function public.freight_quote(p_tenant uuid, p_mode text, p_origin uuid, p_dest uuid,
                                                p_gross_kg numeric default 0, p_cbm numeric default 0,
                                                p_containers jsonb default '{}', p_on date default current_date)
returns table (carrier_id uuid, carrier_name text, currency char(3), buy numeric, sell numeric, margin numeric,
               transit_days int, valid_to date, basis text)
language plpgsql stable security definer set search_path = public as $$
declare chg numeric; unit_name text;
begin
  if not has_perm(p_tenant, 'log.shipment.view') then raise exception 'Not allowed'; end if;
  if p_mode = 'sea_fcl' then
    return query
    with want as (select key as ct, value::numeric as n from jsonb_each_text(coalesce(p_containers,'{}')) where value::numeric > 0),
    best as (
      select distinct on (r.carrier_id, r.currency, w.ct) r.*, w.n
      from freight_rates r join want w on w.ct = r.container_type
      where r.tenant_id = p_tenant and r.mode = 'sea_fcl' and r.origin_port_id = p_origin and r.dest_port_id = p_dest
        and p_on between r.valid_from and r.valid_to
      order by r.carrier_id, r.currency, w.ct, r.sell_rate)
    select b.carrier_id, s.name, b.currency,
           round(sum(b.buy_rate * b.n),2), round(sum(b.sell_rate * b.n),2), round(sum((b.sell_rate - b.buy_rate) * b.n),2),
           max(b.transit_days), min(b.valid_to), string_agg(b.n || '×' || b.container_type, ' + ' order by b.container_type)
    from best b left join suppliers s on s.id = b.carrier_id
    group by b.carrier_id, s.name, b.currency
    having count(*) = (select count(*) from want)          -- carrier must price every container type asked for
    order by 5;
  else
    chg := case p_mode
      when 'air' then round(greatest(p_gross_kg, p_cbm * 1000 / 6.0), 1)
      when 'courier' then round(greatest(p_gross_kg, p_cbm * 1000 / 5.0), 1)
      when 'sea_lcl' then round(greatest(p_cbm, p_gross_kg / 1000.0), 3)
      else round(greatest(p_gross_kg, p_cbm * 1000 / 3.0), 1) end;
    unit_name := case p_mode when 'sea_lcl' then 'w/m' else 'kg' end;
    return query
    select r.carrier_id, s.name, r.currency,
           round(case when r.unit = 'shipment' then r.buy_rate else chg * r.buy_rate end, 2),
           round(case when r.unit = 'shipment' then r.sell_rate else greatest(r.min_charge, chg * r.sell_rate) end, 2),
           round(case when r.unit = 'shipment' then r.sell_rate - r.buy_rate
                      else greatest(r.min_charge, chg * r.sell_rate) - chg * r.buy_rate end, 2),
           r.transit_days, r.valid_to,
           case when r.unit = 'shipment' then 'flat per shipment' else round(chg,2) || ' ' || unit_name || ' chargeable' end
    from freight_rates r left join suppliers s on s.id = r.carrier_id
    where r.tenant_id = p_tenant and r.mode = p_mode and r.origin_port_id = p_origin and r.dest_port_id = p_dest
      and p_on between r.valid_from and r.valid_to and (r.unit in ('shipment', unit_name))
    order by 5;
  end if;
end $$;

-- ===== Customs by zone =====
-- Valuation basis and low-value thresholds per destination country. VERIFY before relying on them:
-- these rules have changed often since 2025.
create table public.customs_profiles (
  country_code char(2) not null,
  valid_from date not null default '2000-01-01',
  valuation_basis text not null default 'CIF' check (valuation_basis in ('CIF','FOB')),
  duty_free_upto numeric(14,2),        -- consignment value at or below which no duty (null = no relief)
  tax_free_upto numeric(14,2),         -- same for import VAT/GST/sales tax
  currency char(3) not null,
  flat_charge numeric(14,2),           -- e.g. EU €3 per low-value B2C consignment
  note text,
  source text,
  primary key (country_code, valid_from)
);
insert into public.customs_profiles (country_code, valid_from, valuation_basis, duty_free_upto, tax_free_upto, currency, flat_charge, note, source) values
  ('MY','2023-04-01','CIF',500,null,'MYR',null,'Duty waived up to RM500 CIF. Low-value goods sold by LVG-registered foreign sellers carry 10% sales tax at checkout.','DHL MY de minimis guide, Jun 2026'),
  ('US','2025-08-29','FOB',0,null,'USD',null,'$800 de minimis suspended for all countries from 29 Aug 2025; duty is due on all imports. Valuation is transaction (FOB) value.','EY tax alert, Aug 2025'),
  ('DE','2026-07-01','CIF',0,0,'EUR',3,'EU €150 duty relief removed 1 Jul 2026; €3 flat charge on low-value B2C parcels; import VAT due on all goods (IOSS).','EU Council / Trade Hub, Jul 2026'),
  ('FR','2026-07-01','CIF',0,0,'EUR',3,'As for EU: €150 duty relief removed 1 Jul 2026; €3 flat charge on low-value B2C parcels.','EU Council / Trade Hub, Jul 2026'),
  ('NL','2026-07-01','CIF',0,0,'EUR',3,'As for EU: €150 duty relief removed 1 Jul 2026; €3 flat charge on low-value B2C parcels.','EU Council / Trade Hub, Jul 2026'),
  ('GB','2021-01-01','CIF',135,null,'GBP',null,'Goods up to £135: no customs duty; VAT charged by the seller at sale. Check for changes.','HMRC (verify)'),
  ('AU','2018-07-01','FOB',1000,1000,'AUD',null,'Up to A$1,000: no duty or GST at the border (GST collected by registered sellers). Customs value is FOB.','ABF (verify)'),
  ('SG','2023-01-01','CIF',null,400,'SGD',null,'Most goods carry no duty (except liquor, tobacco, motor vehicles, petroleum). GST on low-value goods ≤S$400 collected by sellers.','Singapore Customs (verify)');

create table public.duty_rates (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references public.tenants(id) on delete cascade,      -- null = shared (from a data provider)
  country_code char(2) not null,
  hs_prefix text not null check (hs_prefix ~ '^[0-9]{2,12}$'),
  rate numeric(7,5) not null check (rate >= 0 and rate < 5),           -- ad valorem, e.g. 0.05 = 5%
  preference text,                                                     -- null = general (MFN); ATIGA, RCEP, CPTPP…
  origin_countries char(2)[],                                          -- for preferential rates
  description text,
  valid_from date not null default '2000-01-01',
  valid_to date,
  source text not null default 'manual'
);
create index on public.duty_rates (country_code, hs_prefix);

-- Longest HS prefix wins; a preferential rate is used only when requested and the origin qualifies.
create or replace function public.landed_cost(p_tenant uuid, p_dest_country char(2), p_hs_code text, p_origin_country char(2),
                                              p_goods_value numeric, p_freight numeric default 0, p_insurance numeric default 0,
                                              p_preference text default null, p_manual_duty_rate numeric default null,
                                              p_consignment_value numeric default null, p_on date default current_date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare prof customs_profiles; d record; tax record; basis text; cval numeric; duty_rate numeric; duty numeric := 0;
  tax_rate numeric := 0; tax_amt numeric := 0; flat numeric := 0; notes jsonb := '[]'; found_duty boolean := false;
  hs text := regexp_replace(coalesce(p_hs_code,''), '[^0-9]', '', 'g'); cons numeric;
begin
  if not is_member(p_tenant) then raise exception 'Not allowed'; end if;
  select * into prof from customs_profiles where country_code = p_dest_country and valid_from <= p_on order by valid_from desc limit 1;
  basis := coalesce(prof.valuation_basis, 'CIF');
  cval := round(p_goods_value + case when basis = 'CIF' then coalesce(p_freight,0) + coalesce(p_insurance,0) else 0 end, 2);
  cons := coalesce(p_consignment_value, cval);
  if prof.country_code is null then notes := notes || to_jsonb('No customs profile for ' || p_dest_country || ' — assumed CIF valuation and no low-value relief.'); end if;

  if p_manual_duty_rate is not null then
    duty_rate := p_manual_duty_rate; found_duty := true; notes := notes || to_jsonb('Duty rate entered by hand.'::text);
  else
    select * into d from duty_rates r
    where r.country_code = p_dest_country and hs like r.hs_prefix || '%'
      and (r.tenant_id is null or r.tenant_id = p_tenant)
      and r.valid_from <= p_on and (r.valid_to is null or r.valid_to >= p_on)
      and (r.preference is null or (r.preference = p_preference and (r.origin_countries is null or p_origin_country = any(r.origin_countries))))
    order by length(r.hs_prefix) desc, (r.preference is not null) desc, (r.tenant_id is not null) desc, r.rate
    limit 1;
    if found then
      duty_rate := d.rate; found_duty := true;
      if d.preference is not null then notes := notes || to_jsonb('Preferential rate (' || d.preference || ') — keep the certificate of origin.'); end if;
    else
      duty_rate := 0;
      notes := notes || to_jsonb('No duty rate on file for HS ' || coalesce(nullif(hs,''),'?') || ' into ' || p_dest_country || ' — enter it or load a tariff schedule.');
    end if;
  end if;

  if prof.duty_free_upto is not null and cons <= prof.duty_free_upto then
    duty := 0; notes := notes || to_jsonb('Below the ' || prof.currency || ' ' || prof.duty_free_upto || ' duty-free limit.');
  else
    duty := round(cval * duty_rate, 2);
  end if;

  select r.rate, r.name into tax from tax_rates r join tax_zones z on z.id = r.zone_id
  where z.country_code = p_dest_country and z.region is null and r.tax_code = 'standard'
    and (r.tenant_id is null or r.tenant_id = p_tenant) and r.valid_from <= p_on and (r.valid_to is null or r.valid_to >= p_on)
  order by (r.tenant_id is not null) desc, r.valid_from desc limit 1;
  tax_rate := coalesce(tax.rate, 0);
  if tax.rate is null then notes := notes || to_jsonb('No import tax rate on file for ' || p_dest_country || '.'); end if;
  if prof.tax_free_upto is not null and cons <= prof.tax_free_upto then
    tax_amt := 0; notes := notes || to_jsonb('Below the import-tax-free limit (tax may be collected by the seller instead).'::text);
  else
    tax_amt := round((cval + duty) * tax_rate, 2);
  end if;
  if prof.flat_charge is not null then
    flat := prof.flat_charge; notes := notes || to_jsonb('Flat low-value charge may apply: ' || prof.currency || ' ' || prof.flat_charge || '.');
  end if;

  return jsonb_build_object(
    'basis', basis, 'customs_value', cval, 'duty_rate', duty_rate, 'duty_found', found_duty, 'duty', duty,
    'tax_name', coalesce(tax.name, 'Import tax'), 'tax_rate', tax_rate, 'import_tax', tax_amt,
    'flat_charge', flat, 'total_taxes', duty + tax_amt,
    'landed_cost', round(p_goods_value + coalesce(p_freight,0) + coalesce(p_insurance,0) + duty + tax_amt, 2),
    'currency_note', 'Enter all amounts in ' || coalesce(prof.currency, 'the destination currency') || '.',
    'notes', notes);
end $$;

-- Whole-shipment estimate: freight/insurance spread over items by value
create or replace function public.shipment_customs_estimate(p_shipment uuid, p_freight numeric default null, p_insurance numeric default 0)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare sh shipment_list; tot numeric; fr numeric; it record; r jsonb; lines jsonb := '[]'; duty numeric := 0; tax numeric := 0;
begin
  select * into sh from shipment_list where id = p_shipment;
  if sh.id is null then raise exception 'Unknown shipment'; end if;
  if sh.dest_country is null then raise exception 'Set the destination port first'; end if;
  select coalesce(sum(coalesce(value, units * unit_value)),0) into tot from shipment_items where shipment_id = sh.id;
  if tot = 0 then raise exception 'Add item values first'; end if;
  fr := coalesce(p_freight, (select sum(amount_base) from shipment_charges where shipment_id = sh.id and side = 'cost' and code = 'freight'), 0);
  for it in select * from shipment_items where shipment_id = sh.id order by sort_order loop
    r := landed_cost(sh.tenant_id, sh.dest_country, it.hs_code, coalesce(it.origin_country, sh.origin_country),
                     coalesce(it.value, it.units * it.unit_value, 0),
                     fr * coalesce(it.value, it.units * it.unit_value, 0) / tot,
                     coalesce(p_insurance,0) * coalesce(it.value, it.units * it.unit_value, 0) / tot,
                     null, null, tot + fr + coalesce(p_insurance,0));
    lines := lines || jsonb_build_object('description', it.description, 'hs_code', it.hs_code) || r;
    duty := duty + (r->>'duty')::numeric; tax := tax + (r->>'import_tax')::numeric;
  end loop;
  return jsonb_build_object('destination', sh.dest_country, 'goods_value', tot, 'freight', fr, 'insurance', coalesce(p_insurance,0),
                            'duty', duty, 'import_tax', tax, 'total_taxes', duty + tax, 'lines', lines);
end $$;

-- ===== Supplier scorecard =====
create or replace view public.supplier_scorecard with (security_invoker = true) as
select s.id, s.tenant_id, s.name, s.category, s.rating, s.active, s.phone, s.email, s.tags,
  (select count(*) from purchase_orders po where po.supplier_id = s.id and po.status in ('sent','partial')) as open_pos,
  (select round(100.0 * count(*) filter (where po.received_at::date <= po.expected_at) / nullif(count(*),0), 0)
     from purchase_orders po where po.supplier_id = s.id and po.status = 'received' and po.expected_at is not null) as po_on_time_pct,
  (select round(coalesce(sum(l.qty_received * l.unit_cost),0), 2) from purchase_order_lines l join purchase_orders po on po.id = l.po_id
     where po.supplier_id = s.id and po.created_at > now() - interval '365 days') as spend_12m,
  (select count(*) from shipments sh where sh.carrier_id = s.id and sh.created_at > now() - interval '365 days') as shipments_12m,
  (select round(100.0 * count(*) filter (where sh.ata <= sh.eta + interval '1 day') / nullif(count(*),0), 0)
     from shipments sh where sh.carrier_id = s.id and sh.ata is not null and sh.eta is not null) as transit_on_time_pct,
  (select coalesce(sum(c.amount_base),0) from shipment_charges c where c.supplier_id = s.id and c.side = 'cost'
     and c.created_at > now() - interval '365 days') as freight_spend_12m,
  (select count(*) from supplier_documents d where d.supplier_id = s.id and d.expires_on between current_date and current_date + 30) as docs_expiring,
  (select count(*) from supplier_documents d where d.supplier_id = s.id and d.expires_on < current_date) as docs_expired
from suppliers s;

-- ===== RLS =====
alter table public.ports enable row level security;
create policy ports_read on public.ports for select to authenticated using (tenant_id is null or is_member(tenant_id));
create policy ports_write on public.ports for all
  using (tenant_id is not null and has_perm(tenant_id, 'log.fleet.manage'))
  with check (tenant_id is not null and has_perm(tenant_id, 'log.fleet.manage'));

alter table public.customs_profiles enable row level security;
create policy customs_profiles_read on public.customs_profiles for select to authenticated using (true);

alter table public.duty_rates enable row level security;
create policy duty_read on public.duty_rates for select to authenticated using (tenant_id is null or is_member(tenant_id));
create policy duty_write on public.duty_rates for all
  using (tenant_id is not null and has_perm(tenant_id, 'log.customs.manage'))
  with check (tenant_id is not null and has_perm(tenant_id, 'log.customs.manage'));

do $$ declare t text; begin
  foreach t in array array['supplier_contacts','supplier_documents'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %1$s_rw on public.%1$I for all using (has_perm(tenant_id, ''inv.supplier.manage'') or has_perm(tenant_id, ''log.shipment.manage'')) with check (has_perm(tenant_id, ''inv.supplier.manage''))', t);
  end loop;
  foreach t in array array['vessels','voyages'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %1$s_read on public.%1$I for select using (has_perm(tenant_id, ''log.shipment.view''))', t);
    execute format('create policy %1$s_write on public.%1$I for all using (has_perm(tenant_id, ''log.fleet.manage'')) with check (has_perm(tenant_id, ''log.fleet.manage''))', t);
  end loop;
  foreach t in array array['shipments','shipment_items','shipment_containers'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('create policy %1$s_read on public.%1$I for select using (has_perm(tenant_id, ''log.shipment.view''))', t);
    execute format('create policy %1$s_write on public.%1$I for all using (has_perm(tenant_id, ''log.shipment.manage'')) with check (has_perm(tenant_id, ''log.shipment.manage''))', t);
  end loop;
end $$;

-- Logistics staff can see suppliers (carriers, agents) even without purchasing rights
create policy suppliers_log_read on public.suppliers for select using (has_perm(tenant_id, 'log.shipment.view'));
-- Logistics staff can pick shippers/consignees from contacts
create policy contacts_log_read on public.contacts for select using (has_perm(tenant_id, 'log.shipment.manage'));

alter table public.shipment_events enable row level security;
create policy events_read on public.shipment_events for select using (has_perm(tenant_id, 'log.shipment.view'));
-- inserts go through add_shipment_event()

alter table public.shipment_charges enable row level security;
create policy charges_read on public.shipment_charges for select
  using (has_perm(tenant_id, 'log.shipment.manage') or has_perm(tenant_id, 'log.finance'));
create policy charges_write on public.shipment_charges for all
  using (has_perm(tenant_id, 'log.shipment.manage')) with check (has_perm(tenant_id, 'log.shipment.manage'));

alter table public.freight_rates enable row level security;
create policy rates_read on public.freight_rates for select using (has_perm(tenant_id, 'log.shipment.manage') or has_perm(tenant_id, 'log.rate.manage'));
create policy rates_write on public.freight_rates for all
  using (has_perm(tenant_id, 'log.rate.manage')) with check (has_perm(tenant_id, 'log.rate.manage'));

-- Activities on suppliers / shipments
create policy activities_log_read on public.activities for select
  using ((supplier_id is not null and has_perm(tenant_id, 'inv.supplier.manage'))
      or (shipment_id is not null and has_perm(tenant_id, 'log.shipment.view')));
create policy activities_log_insert on public.activities for insert
  with check (kind <> 'system' and (
    (supplier_id is not null and has_perm(tenant_id, 'inv.supplier.manage'))
    or (shipment_id is not null and has_perm(tenant_id, 'log.shipment.manage'))));

do $$ declare t text; begin
  foreach t in array array['shipments','shipment_charges','vessels','voyages','freight_rates','duty_rates','supplier_documents','purchase_orders'] loop
    execute format('drop trigger if exists audit_%1$s on public.%1$I', t);
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;
