-- Ai buddy Biz — Batch C: zone-based tax engine, double-entry accounting,
-- invoicing (e-invoice ready), shifts and reports.
-- Depends on 0001_core.sql and 0002_pos_inventory.sql

-- ===== Permissions =====
insert into public.permissions (code, module, description) values
  ('fin.invoice.view','FIN','View invoices'),
  ('fin.invoice.manage','FIN','Create, edit, issue and void invoices'),
  ('fin.payment.record','FIN','Record payments against invoices'),
  ('fin.ledger.view','FIN','View chart of accounts and journals'),
  ('fin.journal.post','FIN','Post manual journals and edit accounts'),
  ('fin.tax.manage','FIN','Manage tax zones, rates and codes'),
  ('fin.report.view','FIN','View financial reports'),
  ('crm.contact.view','CRM','View customers and suppliers'),
  ('crm.contact.manage','CRM','Add/edit customers and suppliers');

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r join public.permissions p on p.module in ('FIN','CRM')
where r.tenant_id is null and r.name in ('Owner','Admin','Accountant');

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r,
  unnest(array['fin.invoice.view','fin.invoice.manage','fin.payment.record','fin.report.view',
               'crm.contact.view','crm.contact.manage']) c
where r.tenant_id is null and r.name = 'Manager';

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r, unnest(array['crm.contact.view']) c
where r.tenant_id is null and r.name in ('Cashier','Viewer');

-- Accountant also needs to read sales
insert into public.role_permissions (role_id, permission_code)
select r.id, 'pos.report.view' from public.roles r
where r.tenant_id is null and r.name = 'Accountant'
on conflict do nothing;

-- ===== Tenant / outlet tax settings =====
alter table public.tenants
  add column default_tax_code text not null default 'standard',
  add column tax_registration_no text,          -- e.g. SST no., GST/VAT no.
  add column tin text,                          -- tax identification number (needed for e-invoice)
  add column einvoice_enabled boolean not null default false,
  add column invoice_terms_days int not null default 30;

alter table public.outlets
  add column country_code char(2),
  add column region text;                       -- state / province code for sub-national tax (US, CA, IN…)

update public.outlets o set country_code = t.country_code from public.tenants t where t.id = o.tenant_id and o.country_code is null;

-- ===== Tax engine =====
-- Zones are countries or regions. Rates are data with validity dates, never hard-coded.
-- tenant_id null = shared starter rates; a tenant row overrides it for that business.
create table public.tax_zones (
  id uuid primary key default gen_random_uuid(),
  country_code char(2) not null,
  region text,                                  -- null = whole country
  name text not null,
  unique nulls not distinct (country_code, region)
);

create table public.tax_rates (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references public.tenants(id) on delete cascade,
  zone_id uuid not null references public.tax_zones(id) on delete cascade,
  tax_code text not null,                       -- standard, reduced, service, service_fnb, zero, exempt…
  name text not null,                           -- shown on receipts/invoices, e.g. 'SST 10%'
  rate numeric(7,5) not null check (rate >= 0 and rate < 1),
  inclusive boolean not null default false,     -- true where shelf prices include tax (AU, NZ, UK, EU)
  valid_from date not null default '2000-01-01',
  valid_to date,
  source text not null default 'seed',          -- seed | manual | provider:<name>
  note text
);
create index on public.tax_rates (zone_id, tax_code, valid_from);

-- Finds the rate for a business + place + tax code + date.
-- Order: tenant override over shared; region over country; latest valid_from.
-- If the place has no rate for that code, the place's 'standard' rate applies,
-- except 'exempt' / 'zero' items, which stay at 0%.
create or replace function public.resolve_tax(p_tenant uuid, p_outlet uuid, p_tax_code text, p_at date default current_date)
returns table (rate numeric, name text, inclusive boolean)
language sql stable security definer set search_path = public as $$
  with place as (
    select coalesce(o.country_code, t.country_code) as cc, o.region
    from tenants t left join outlets o on o.id = p_outlet and o.tenant_id = t.id
    where t.id = p_tenant
  ), code as (
    select coalesce(nullif(p_tax_code, ''), (select default_tax_code from tenants where id = p_tenant)) as c
  ), found as (
    select r.rate, r.name, r.inclusive, (r.tax_code = code.c) as exact,
           (r.tenant_id is not null) as own, (z.region is not null) as regional, r.valid_from
    from tax_rates r
    join tax_zones z on z.id = r.zone_id
    cross join place cross join code
    where z.country_code = place.cc
      and (z.region is null or z.region = place.region)
      and (r.tax_code = code.c or (r.tax_code = 'standard' and code.c not in ('exempt','zero')))
      and (r.tenant_id is null or r.tenant_id = p_tenant)
      and r.valid_from <= p_at and (r.valid_to is null or r.valid_to >= p_at)
  )
  select rate, name, inclusive from (
    select f.rate, f.name, f.inclusive, f.exact, f.own, f.regional, f.valid_from from found f
    union all
    select 0, 'Exempt', coalesce((select bool_or(f2.inclusive) from found f2), false), true, false, false, '1900-01-01'::date
    from code where code.c in ('exempt','zero')
  ) x
  order by exact desc, own desc, regional desc, valid_from desc
  limit 1;
$$;

-- All codes that apply to an outlet today (the app caches this for offline selling)
create or replace function public.outlet_tax_table(p_outlet uuid)
returns table (tax_code text, rate numeric, name text, inclusive boolean)
language sql stable security definer set search_path = public as $$
  select c.tax_code, r.rate, r.name, r.inclusive
  from outlets o
  cross join lateral (
    select distinct tr.tax_code from tax_rates tr join tax_zones z on z.id = tr.zone_id
    where z.country_code = coalesce(o.country_code, (select country_code from tenants where id = o.tenant_id))
      and (tr.tenant_id is null or tr.tenant_id = o.tenant_id)
  ) c
  cross join lateral resolve_tax(o.tenant_id, o.id, c.tax_code) r
  where o.id = p_outlet and is_member(o.tenant_id);
$$;

-- Starter rates. VERIFY before go-live: rates change and some have sector rules.
-- A tax-data provider adapter (Avalara, Vertex, TaxJar…) writes rows with source='provider:…'.
insert into public.tax_zones (country_code, region, name) values
  ('MY',null,'Malaysia'),('SG',null,'Singapore'),('TH',null,'Thailand'),('ID',null,'Indonesia'),
  ('PH',null,'Philippines'),('VN',null,'Vietnam'),('IN',null,'India'),('AE',null,'United Arab Emirates'),
  ('SA',null,'Saudi Arabia'),('AU',null,'Australia'),('NZ',null,'New Zealand'),('GB',null,'United Kingdom'),
  ('DE',null,'Germany'),('FR',null,'France'),('US',null,'United States (no federal sales tax)'),
  ('US','CA','California (state base)'),('US','NY','New York (state base)'),('US','TX','Texas (state base)'),
  ('US','FL','Florida (state base)'),('CA',null,'Canada (GST)'),('CA','ON','Ontario (HST)');

insert into public.tax_rates (zone_id, tax_code, name, rate, inclusive, note)
select z.id, v.code, v.name, v.rate, v.incl, v.note
from (values
  ('MY',null,'standard','Sales tax 10%',0.10,false,'Most manufactured/imported goods'),
  ('MY',null,'reduced','Sales tax 5%',0.05,false,'Selected goods'),
  ('MY',null,'service','Service tax 8%',0.08,false,'Most taxable services'),
  ('MY',null,'service_fnb','Service tax 6%',0.06,false,'F&B, telco, parking, logistics'),
  ('MY',null,'exempt','Exempt',0,false,null),
  ('SG',null,'standard','GST 9%',0.09,true,null),
  ('SG',null,'zero','GST 0%',0,true,null),
  ('TH',null,'standard','VAT 7%',0.07,true,null),
  ('ID',null,'standard','PPN 11%',0.11,false,'Effective general rate; luxury goods 12%'),
  ('ID',null,'luxury','PPN 12%',0.12,false,null),
  ('PH',null,'standard','VAT 12%',0.12,false,null),
  ('VN',null,'standard','VAT 10%',0.10,false,'Temporary 8% applies to many goods — check'),
  ('VN',null,'reduced','VAT 8%',0.08,false,null),
  ('IN',null,'standard','GST 18%',0.18,true,null),
  ('IN',null,'reduced','GST 5%',0.05,true,null),
  ('AE',null,'standard','VAT 5%',0.05,true,null),
  ('SA',null,'standard','VAT 15%',0.15,true,null),
  ('AU',null,'standard','GST 10%',0.10,true,null),
  ('AU',null,'exempt','GST-free',0,true,null),
  ('NZ',null,'standard','GST 15%',0.15,true,null),
  ('GB',null,'standard','VAT 20%',0.20,true,null),
  ('GB',null,'reduced','VAT 5%',0.05,true,null),
  ('GB',null,'zero','VAT 0%',0,true,null),
  ('DE',null,'standard','MwSt 19%',0.19,true,null),
  ('DE',null,'reduced','MwSt 7%',0.07,true,null),
  ('FR',null,'standard','TVA 20%',0.20,true,null),
  ('FR',null,'reduced','TVA 5.5%',0.055,true,null),
  ('US',null,'standard','No sales tax',0,false,'Set state/local rates per outlet region'),
  ('US','CA','standard','CA sales tax 7.25%',0.0725,false,'State base only; add district tax'),
  ('US','NY','standard','NY sales tax 4%',0.04,false,'State base only; add local tax'),
  ('US','TX','standard','TX sales tax 6.25%',0.0625,false,'State base only; add local tax'),
  ('US','FL','standard','FL sales tax 6%',0.06,false,'State base only; add county surtax'),
  ('CA',null,'standard','GST 5%',0.05,false,null),
  ('CA','ON','standard','HST 13%',0.13,false,null)
) as v(cc, region, code, name, rate, incl, note)
join public.tax_zones z on z.country_code = v.cc and z.region is not distinct from v.region;

alter table public.tax_zones enable row level security;
alter table public.tax_rates enable row level security;
create policy tax_zones_read on public.tax_zones for select to authenticated using (true);
create policy tax_rates_read on public.tax_rates for select to authenticated
  using (tenant_id is null or is_member(tenant_id));
create policy tax_rates_write on public.tax_rates for all
  using (tenant_id is not null and has_perm(tenant_id, 'fin.tax.manage'))
  with check (tenant_id is not null and has_perm(tenant_id, 'fin.tax.manage'));

-- ===== Contacts (customers & suppliers; CRM batch extends this) =====
create table public.contacts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  kind text not null default 'customer' check (kind in ('customer','supplier','both')),
  name text not null,
  company text,
  email text,
  phone text,
  tin text,                                     -- tax ID, needed for B2B e-invoices
  reg_no text,                                  -- business registration no.
  address jsonb,
  custom_values jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index on public.contacts (tenant_id, name);
alter table public.sales add constraint sales_customer_fk foreign key (customer_id) references public.contacts(id) on delete set null;

alter table public.contacts enable row level security;
create policy contacts_read on public.contacts for select using (has_perm(tenant_id, 'crm.contact.view'));
create policy contacts_write on public.contacts for all
  using (has_perm(tenant_id, 'crm.contact.manage')) with check (has_perm(tenant_id, 'crm.contact.manage'));

-- ===== Chart of accounts & journals =====
create table public.accounts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  code text not null,
  name text not null,
  type text not null check (type in ('asset','liability','equity','income','expense')),
  is_system boolean not null default false,
  active boolean not null default true,
  unique (tenant_id, code)
);

create table public.journal_counters (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  next_no bigint not null default 1
);

create table public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  entry_no bigint not null,
  entry_date date not null,
  memo text,
  source_type text,                             -- sale, sale_void, invoice, invoice_payment, invoice_void, stock, manual
  source_id uuid,
  reverses uuid references public.journal_entries(id),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  unique (tenant_id, entry_no)
);
create index on public.journal_entries (tenant_id, entry_date);
create index on public.journal_entries (source_type, source_id);

create table public.journal_lines (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  entry_id uuid not null references public.journal_entries(id) on delete cascade,
  account_id uuid not null references public.accounts(id),
  debit numeric(16,2) not null default 0 check (debit >= 0),
  credit numeric(16,2) not null default 0 check (credit >= 0),
  check (debit = 0 or credit = 0)
);
create index on public.journal_lines (tenant_id, account_id);

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
    (p_tenant,'6000','Operating expenses','expense',true),
    (p_tenant,'6100','Inventory adjustments & losses','expense',true)
  on conflict (tenant_id, code) do nothing;
$$;

-- Posts a balanced entry. p_lines: [{"code":"1000","debit":10},{"code":"4000","credit":10}]
create or replace function public.post_entry(p_tenant uuid, p_date date, p_memo text, p_source_type text, p_source_id uuid, p_lines jsonb, p_reverses uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_no bigint; v_dr numeric; v_cr numeric; l jsonb; v_acc uuid;
begin
  perform ensure_chart(p_tenant);
  select coalesce(sum(round(coalesce((x->>'debit')::numeric,0),2)),0), coalesce(sum(round(coalesce((x->>'credit')::numeric,0),2)),0)
    into v_dr, v_cr from jsonb_array_elements(p_lines) x;
  if v_dr <> v_cr then raise exception 'Journal does not balance: debit % vs credit %', v_dr, v_cr; end if;
  if v_dr = 0 then return null; end if;

  insert into journal_counters (tenant_id) values (p_tenant) on conflict do nothing;
  update journal_counters set next_no = next_no + 1 where tenant_id = p_tenant returning next_no - 1 into v_no;
  insert into journal_entries (tenant_id, entry_no, entry_date, memo, source_type, source_id, reverses)
  values (p_tenant, v_no, p_date, p_memo, p_source_type, p_source_id, p_reverses) returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    if round(coalesce((l->>'debit')::numeric,0),2) = 0 and round(coalesce((l->>'credit')::numeric,0),2) = 0 then continue; end if;
    select id into v_acc from accounts where tenant_id = p_tenant and code = l->>'code';
    if v_acc is null then raise exception 'Unknown account %', l->>'code'; end if;
    insert into journal_lines (tenant_id, entry_id, account_id, debit, credit)
    values (p_tenant, v_id, v_acc, round(coalesce((l->>'debit')::numeric,0),2), round(coalesce((l->>'credit')::numeric,0),2));
  end loop;
  return v_id;
end $$;

-- Reverses every entry posted for a source (used by voids)
create or replace function public.reverse_source(p_tenant uuid, p_source_type text, p_source_id uuid, p_new_source_type text, p_memo text)
returns void language plpgsql security definer set search_path = public as $$
declare e record;
begin
  for e in select je.* from journal_entries je
           where je.tenant_id = p_tenant and je.source_type = p_source_type and je.source_id = p_source_id
             and not exists (select 1 from journal_entries r where r.reverses = je.id) loop
    perform post_entry(p_tenant, current_date, p_memo, p_new_source_type, p_source_id,
      (select jsonb_agg(jsonb_build_object('code', a.code, 'debit', jl.credit, 'credit', jl.debit))
         from journal_lines jl join accounts a on a.id = jl.account_id where jl.entry_id = e.id),
      e.id);
  end loop;
end $$;

create or replace function public.post_manual_journal(p_tenant uuid, p_date date, p_memo text, p_lines jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
begin
  if not has_perm(p_tenant, 'fin.journal.post') then raise exception 'Not allowed to post journals'; end if;
  return post_entry(p_tenant, p_date, p_memo, 'manual', null, p_lines);
end $$;

-- ===== Posting rules =====
-- Sale: Dr cash (cash part) + Dr clearing (card/QR/e-wallet), Cr Sales (net), Cr Tax payable.
--       Dr COGS / Cr Inventory at cost for stock-tracked lines.
create or replace function public.post_sale(p_sale uuid)
returns void language plpgsql security definer set search_path = public as $$
declare s sales; v_noncash numeric; v_tax numeric; v_cogs numeric;
begin
  select * into s from sales where id = p_sale;
  select coalesce(sum(amount),0) into v_noncash from payments where sale_id = s.id and method <> 'cash';
  v_noncash := least(v_noncash, s.total);
  select coalesce(sum(tax_amount),0) into v_tax from sale_lines where sale_id = s.id;
  select coalesce(sum(l.qty * v.cost),0) into v_cogs
    from sale_lines l join product_variants v on v.id = l.variant_id where l.sale_id = s.id and v.track_stock;
  perform post_entry(s.tenant_id, (s.sold_at at time zone 'UTC')::date, 'Sale ' || s.receipt_no, 'sale', s.id, jsonb_build_array(
    jsonb_build_object('code','1000','debit', s.total - v_noncash),
    jsonb_build_object('code','1010','debit', v_noncash),
    jsonb_build_object('code','4000','credit', s.total - v_tax),
    jsonb_build_object('code','2100','credit', v_tax),
    jsonb_build_object('code','5000','debit', round(v_cogs,2)),
    jsonb_build_object('code','1200','credit', round(v_cogs,2))));
end $$;

-- Stock value changes outside sales
create or replace function public.post_stock_movement()
returns trigger language plpgsql security definer set search_path = public as $$
declare v_cost numeric; v_val numeric; v_other text;
begin
  if new.reason not in ('receive','opening','count','adjust','damage') then return new; end if;
  select coalesce(new.unit_cost, cost) into v_cost from product_variants where id = new.variant_id;
  v_val := round(new.qty_change * coalesce(v_cost,0), 2);
  if v_val = 0 then return new; end if;
  v_other := case new.reason when 'receive' then '2200' when 'opening' then '3000' else '6100' end;
  perform post_entry(new.tenant_id, (new.at at time zone 'UTC')::date, 'Stock ' || new.reason, 'stock', null,
    case when v_val > 0 then jsonb_build_array(
           jsonb_build_object('code','1200','debit', v_val), jsonb_build_object('code', v_other, 'credit', v_val))
         else jsonb_build_array(
           jsonb_build_object('code', v_other, 'debit', -v_val), jsonb_build_object('code','1200','credit', -v_val)) end);
  return new;
end $$;
create trigger trg_post_stock after insert on public.stock_movements
  for each row execute function public.post_stock_movement();

-- ===== POS: server-side tax, inclusive pricing, auto-posting, shifts =====
alter table public.sale_lines add column tax_name text, add column tax_inclusive boolean not null default false;

create or replace function public.complete_sale(p jsonb)
returns public.sales language plpgsql security definer set search_path = public as $$
declare
  v_outlet uuid := (p->>'outlet_id')::uuid;
  v_tenant uuid;
  v_existing sales;
  v_sale sales;
  v_line jsonb;
  v_var product_variants;
  v_prod products;
  v_name text;
  v_qty numeric; v_price numeric; v_disc numeric; v_rate numeric; v_tname text; v_incl boolean;
  v_net numeric; v_tax numeric; v_ltotal numeric;
  v_sub numeric := 0; v_disc_tot numeric := 0; v_tax_tot numeric := 0; v_total numeric := 0;
  v_paid numeric := 0;
  v_no text;
  v_at timestamptz;
begin
  select tenant_id into v_tenant from outlets where id = v_outlet;
  if v_tenant is null then raise exception 'Unknown outlet'; end if;
  if not has_perm(v_tenant, 'pos.sale.create') then raise exception 'Not allowed to sell'; end if;

  select * into v_existing from sales where tenant_id = v_tenant and client_sale_id = (p->>'client_sale_id')::uuid;
  if found then return v_existing; end if;
  if jsonb_array_length(coalesce(p->'lines','[]')) = 0 then raise exception 'Sale has no items'; end if;

  v_at := coalesce((p->>'sold_at')::timestamptz, now());
  insert into receipt_counters (outlet_id) values (v_outlet) on conflict do nothing;
  update receipt_counters set next_no = next_no + 1 where outlet_id = v_outlet
    returning prefix || lpad((next_no - 1)::text, 6, '0') into v_no;

  insert into sales (tenant_id, outlet_id, shift_id, client_sale_id, receipt_no, subtotal, total, currency, note, sold_at, customer_id)
  values (v_tenant, v_outlet, nullif(p->>'shift_id','')::uuid, (p->>'client_sale_id')::uuid, v_no, 0, 0,
          coalesce(p->>'currency', (select base_currency from tenants where id = v_tenant)),
          p->>'note', v_at, nullif(p->>'customer_id','')::uuid)
  returning * into v_sale;

  for v_line in select * from jsonb_array_elements(p->'lines') loop
    select * into v_var from product_variants where id = (v_line->>'variant_id')::uuid and tenant_id = v_tenant;
    if not found then raise exception 'Unknown item %', v_line->>'variant_id'; end if;
    select * into v_prod from products where id = v_var.product_id;
    v_name := v_prod.name || coalesce(' — ' || v_var.name, '');

    v_qty := (v_line->>'qty')::numeric;
    v_price := coalesce((v_line->>'unit_price')::numeric, v_var.price);
    v_disc := coalesce((v_line->>'discount')::numeric, 0);
    if v_disc > 0 and v_disc > round(v_price * v_qty * 0.10, 2) and not has_perm(v_tenant, 'pos.sale.discount') then
      raise exception 'Discount above 10%% needs a manager';
    end if;

    if v_line ? 'tax_rate' then          -- older app versions send the rate themselves
      v_rate := coalesce((v_line->>'tax_rate')::numeric, 0); v_tname := null; v_incl := false;
    else
      select r.rate, r.name, r.inclusive into v_rate, v_tname, v_incl
      from resolve_tax(v_tenant, v_outlet, v_prod.tax_code, (v_at at time zone 'UTC')::date) r;
      v_rate := coalesce(v_rate, 0); v_incl := coalesce(v_incl, false);
    end if;

    v_net := round(v_price * v_qty - v_disc, 2);
    if v_incl then
      v_tax := round(v_net - v_net / (1 + v_rate), 2); v_ltotal := v_net;
    else
      v_tax := round(v_net * v_rate, 2); v_ltotal := v_net + v_tax;
    end if;

    insert into sale_lines (tenant_id, sale_id, variant_id, name, sku, qty, unit_price, discount, tax_rate, tax_amount, line_total, tax_name, tax_inclusive)
    values (v_tenant, v_sale.id, v_var.id, v_name, v_var.sku, v_qty, v_price, v_disc, v_rate, v_tax, v_ltotal, v_tname, v_incl);

    if v_var.track_stock then
      insert into stock_movements (tenant_id, outlet_id, variant_id, qty_change, reason, unit_cost, ref_type, ref_id)
      values (v_tenant, v_outlet, v_var.id, -v_qty, 'sale', v_var.cost, 'sale', v_sale.id);
    end if;

    v_sub := v_sub + round(v_price * v_qty, 2);
    v_disc_tot := v_disc_tot + v_disc;
    v_tax_tot := v_tax_tot + v_tax;
    v_total := v_total + v_ltotal;
  end loop;

  insert into payments (tenant_id, sale_id, method, amount, reference)
  select v_tenant, v_sale.id, x->>'method', (x->>'amount')::numeric, x->>'reference'
  from jsonb_array_elements(coalesce(p->'payments','[]')) x;
  select coalesce(sum(amount),0) into v_paid from payments where sale_id = v_sale.id;
  if v_paid < v_total then raise exception 'Payment % is less than total %', v_paid, v_total; end if;

  update sales set subtotal = v_sub, discount_total = v_disc_tot, tax_total = v_tax_tot, total = v_total
  where id = v_sale.id returning * into v_sale;

  perform post_sale(v_sale.id);
  return v_sale;
end $$;

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
  perform reverse_source(s.tenant_id, 'sale', s.id, 'sale_void', 'Void ' || s.receipt_no || ': ' || p_reason);
  update sales set status = 'voided', note = coalesce(note || ' | ', '') || 'VOID: ' || p_reason where id = s.id;
end $$;

-- Shifts
alter table public.shifts add column expected_cash numeric(14,2), add column note text;

create or replace function public.open_shift(p_outlet uuid, p_opening_cash numeric)
returns public.shifts language plpgsql security definer set search_path = public as $$
declare t uuid; sh shifts;
begin
  select tenant_id into t from outlets where id = p_outlet;
  if not has_perm(t, 'pos.shift.manage') then raise exception 'Not allowed to open shifts'; end if;
  if exists (select 1 from shifts where outlet_id = p_outlet and user_id = auth.uid() and closed_at is null) then
    raise exception 'You already have an open shift here';
  end if;
  insert into shifts (tenant_id, outlet_id, user_id, opening_cash) values (t, p_outlet, auth.uid(), coalesce(p_opening_cash,0))
  returning * into sh;
  return sh;
end $$;

create or replace function public.shift_expected_cash(p_shift uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select sh.opening_cash + coalesce((
    select sum(s.total - least(s.total, coalesce((select sum(p.amount) from payments p where p.sale_id = s.id and p.method <> 'cash'),0)))
    from sales s where s.shift_id = sh.id and s.status = 'completed'), 0)
  from shifts sh where sh.id = p_shift;
$$;

create or replace function public.close_shift(p_shift uuid, p_counted_cash numeric, p_note text default null)
returns public.shifts language plpgsql security definer set search_path = public as $$
declare sh shifts;
begin
  select * into sh from shifts where id = p_shift;
  if not found then raise exception 'Unknown shift'; end if;
  if sh.user_id <> auth.uid() and not has_perm(sh.tenant_id, 'pos.report.view') then raise exception 'Not your shift'; end if;
  if sh.closed_at is not null then raise exception 'Shift already closed'; end if;
  update shifts set closed_at = now(), counted_cash = p_counted_cash, expected_cash = shift_expected_cash(p_shift), note = p_note
  where id = p_shift returning * into sh;
  return sh;
end $$;

-- ===== Invoicing =====
create table public.invoice_counters (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  prefix text not null default 'INV-',
  next_no bigint not null default 1
);

create table public.invoices (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  outlet_id uuid references public.outlets(id),        -- stock is taken from here; also sets the tax zone
  contact_id uuid references public.contacts(id),
  number text,                                          -- given when issued
  status text not null default 'draft' check (status in ('draft','issued','partial','paid','void')),
  issue_date date,
  due_date date,
  currency char(3) not null,
  subtotal numeric(14,2) not null default 0,
  discount_total numeric(14,2) not null default 0,
  tax_total numeric(14,2) not null default 0,
  total numeric(14,2) not null default 0,
  amount_paid numeric(14,2) not null default 0,
  notes text,
  terms text,
  einvoice_status text not null default 'not_required'
    check (einvoice_status in ('not_required','pending','submitted','validated','rejected','cancelled')),
  einvoice_uuid text,                                   -- e.g. MyInvois UUID once validated
  einvoice_long_id text,
  einvoice_error text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  unique (tenant_id, number)
);
create index on public.invoices (tenant_id, status, due_date);

create table public.invoice_lines (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  variant_id uuid references public.product_variants(id),
  description text not null,
  qty numeric(14,3) not null default 1 check (qty > 0),
  unit_price numeric(14,2) not null default 0 check (unit_price >= 0),
  discount numeric(14,2) not null default 0 check (discount >= 0),
  tax_code text,                                        -- null = product's code or business default
  tax_rate numeric(7,5) not null default 0,
  tax_name text,
  tax_inclusive boolean not null default false,
  tax_amount numeric(14,2) not null default 0,
  line_total numeric(14,2) not null default 0,
  sort_order int not null default 0
);

create table public.invoice_payments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  paid_on date not null default current_date,
  method text not null check (method in ('cash','card','qr','ewallet','bank_transfer','cheque','other')),
  amount numeric(14,2) not null check (amount > 0),
  reference text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

-- Lines: only editable while draft; tax worked out automatically
create or replace function public.invoice_line_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare inv invoices; v_code text; r record; v_net numeric;
begin
  select * into inv from invoices where id = coalesce(new.invoice_id, old.invoice_id);
  if inv.status <> 'draft' then raise exception 'Invoice % is %, it can no longer be edited', coalesce(inv.number,''), inv.status; end if;
  if tg_op = 'DELETE' then return old; end if;
  new.tenant_id := inv.tenant_id;
  v_code := coalesce(new.tax_code, (select pr.tax_code from product_variants v join products pr on pr.id = v.product_id where v.id = new.variant_id));
  select * into r from resolve_tax(inv.tenant_id, inv.outlet_id, v_code, coalesce(inv.issue_date, current_date));
  new.tax_rate := coalesce(r.rate, 0);
  new.tax_name := r.name;
  new.tax_inclusive := coalesce(r.inclusive, false);
  v_net := round(new.qty * new.unit_price - new.discount, 2);
  if v_net < 0 then raise exception 'Discount is bigger than the line amount'; end if;
  if new.tax_inclusive then
    new.tax_amount := round(v_net - v_net / (1 + new.tax_rate), 2); new.line_total := v_net;
  else
    new.tax_amount := round(v_net * new.tax_rate, 2); new.line_total := v_net + new.tax_amount;
  end if;
  return new;
end $$;
create trigger trg_invoice_line_before before insert or update or delete on public.invoice_lines
  for each row execute function public.invoice_line_before();

create or replace function public.invoice_recalc(p_invoice uuid)
returns void language sql security definer set search_path = public as $$
  update invoices i set
    subtotal = coalesce(x.sub,0), discount_total = coalesce(x.disc,0), tax_total = coalesce(x.tax,0), total = coalesce(x.tot,0)
  from (select sum(round(qty*unit_price,2)) sub, sum(discount) disc, sum(tax_amount) tax, sum(line_total) tot
        from invoice_lines where invoice_id = p_invoice) x
  where i.id = p_invoice;
$$;

create or replace function public.invoice_line_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform invoice_recalc(coalesce(new.invoice_id, old.invoice_id));
  return null;
end $$;
create trigger trg_invoice_line_after after insert or update or delete on public.invoice_lines
  for each row execute function public.invoice_line_after();

-- Header guard: only drafts can be changed directly; status changes go through the functions below
create or replace function public.invoice_guard()
returns trigger language plpgsql as $$
begin
  if current_setting('abb.invoice_fn', true) = 'on' then return coalesce(new, old); end if;
  if tg_op = 'DELETE' then
    if old.status <> 'draft' then raise exception 'Only draft invoices can be deleted; void it instead'; end if;
    return old;
  end if;
  if tg_op = 'UPDATE' and old.status <> 'draft' then
    raise exception 'Issued invoices cannot be edited';
  end if;
  if new.status <> 'draft' or new.number is not null or new.amount_paid <> 0 then
    raise exception 'Use issue_invoice / record_invoice_payment / void_invoice';
  end if;
  return new;
end $$;
create trigger trg_invoice_guard before insert or update or delete on public.invoices
  for each row execute function public.invoice_guard();

create or replace function public.issue_invoice(p_invoice uuid, p_issue_date date default current_date)
returns public.invoices language plpgsql security definer set search_path = public as $$
declare inv invoices; t tenants; v_no text; v_cogs numeric := 0; l record;
begin
  select * into inv from invoices where id = p_invoice for update;
  if not found then raise exception 'Unknown invoice'; end if;
  if not has_perm(inv.tenant_id, 'fin.invoice.manage') then raise exception 'Not allowed'; end if;
  if inv.status <> 'draft' then raise exception 'Invoice is already %', inv.status; end if;
  if not exists (select 1 from invoice_lines where invoice_id = inv.id) then raise exception 'Invoice has no lines'; end if;
  select * into t from tenants where id = inv.tenant_id;

  -- re-price lines at the issue date (tax may have changed since drafting)
  update invoices set issue_date = p_issue_date where id = inv.id;
  update invoice_lines set qty = qty where invoice_id = inv.id;
  select * into inv from invoices where id = p_invoice;

  insert into invoice_counters (tenant_id) values (inv.tenant_id) on conflict do nothing;
  update invoice_counters set next_no = next_no + 1 where tenant_id = inv.tenant_id
    returning prefix || lpad((next_no - 1)::text, 5, '0') into v_no;

  -- take stock for stocked items when an outlet is set
  if inv.outlet_id is not null then
    for l in select il.variant_id, il.qty, v.cost from invoice_lines il join product_variants v on v.id = il.variant_id
             where il.invoice_id = inv.id and v.track_stock loop
      insert into stock_movements (tenant_id, outlet_id, variant_id, qty_change, reason, unit_cost, ref_type, ref_id)
      values (inv.tenant_id, inv.outlet_id, l.variant_id, -l.qty, 'sale', l.cost, 'invoice', inv.id);
      v_cogs := v_cogs + l.qty * l.cost;
    end loop;
  end if;

  perform set_config('abb.invoice_fn', 'on', true);
  update invoices set number = v_no, status = 'issued',
    due_date = coalesce(due_date, p_issue_date + t.invoice_terms_days),
    einvoice_status = case when t.einvoice_enabled then 'pending' else 'not_required' end
  where id = inv.id returning * into inv;
  perform set_config('abb.invoice_fn', 'off', true);

  perform post_entry(inv.tenant_id, p_issue_date, 'Invoice ' || v_no, 'invoice', inv.id, jsonb_build_array(
    jsonb_build_object('code','1100','debit', inv.total),
    jsonb_build_object('code','4000','credit', inv.total - inv.tax_total),
    jsonb_build_object('code','2100','credit', inv.tax_total),
    jsonb_build_object('code','5000','debit', round(v_cogs,2)),
    jsonb_build_object('code','1200','credit', round(v_cogs,2))));
  return inv;
end $$;

create or replace function public.record_invoice_payment(p_invoice uuid, p_amount numeric, p_method text, p_paid_on date default current_date, p_reference text default null)
returns public.invoices language plpgsql security definer set search_path = public as $$
declare inv invoices; v_pid uuid;
begin
  select * into inv from invoices where id = p_invoice for update;
  if not found then raise exception 'Unknown invoice'; end if;
  if not has_perm(inv.tenant_id, 'fin.payment.record') then raise exception 'Not allowed to record payments'; end if;
  if inv.status not in ('issued','partial') then raise exception 'Invoice is %', inv.status; end if;
  if p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  if p_amount > inv.total - inv.amount_paid then
    raise exception 'Payment % is more than the balance %', p_amount, inv.total - inv.amount_paid;
  end if;
  insert into invoice_payments (tenant_id, invoice_id, paid_on, method, amount, reference)
  values (inv.tenant_id, inv.id, p_paid_on, p_method, p_amount, p_reference) returning id into v_pid;

  perform post_entry(inv.tenant_id, p_paid_on, 'Payment for ' || inv.number, 'invoice_payment', v_pid, jsonb_build_array(
    jsonb_build_object('code', case p_method when 'cash' then '1000' when 'bank_transfer' then '1020' when 'cheque' then '1020' else '1010' end,
                       'debit', p_amount),
    jsonb_build_object('code','1100','credit', p_amount)));

  perform set_config('abb.invoice_fn', 'on', true);
  update invoices set amount_paid = amount_paid + p_amount,
    status = case when amount_paid + p_amount >= total then 'paid' else 'partial' end
  where id = inv.id returning * into inv;
  perform set_config('abb.invoice_fn', 'off', true);
  return inv;
end $$;

create or replace function public.void_invoice(p_invoice uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare inv invoices;
begin
  select * into inv from invoices where id = p_invoice for update;
  if not found then raise exception 'Unknown invoice'; end if;
  if not has_perm(inv.tenant_id, 'fin.invoice.manage') then raise exception 'Not allowed'; end if;
  if inv.status = 'draft' then raise exception 'Delete drafts instead of voiding'; end if;
  if inv.status = 'void' then raise exception 'Already void'; end if;
  if inv.amount_paid > 0 then raise exception 'Invoice has payments; refund them first (credit notes arrive in a later batch)'; end if;
  insert into stock_movements (tenant_id, outlet_id, variant_id, qty_change, reason, ref_type, ref_id, note)
  select inv.tenant_id, inv.outlet_id, sm.variant_id, -sm.qty_change, 'refund', 'invoice', inv.id, p_reason
  from stock_movements sm where sm.ref_type = 'invoice' and sm.ref_id = inv.id and sm.reason = 'sale';
  perform reverse_source(inv.tenant_id, 'invoice', inv.id, 'invoice_void', 'Void ' || inv.number || ': ' || p_reason);
  perform set_config('abb.invoice_fn', 'on', true);
  update invoices set status = 'void',
    einvoice_status = case when einvoice_status in ('submitted','validated') then 'cancelled' else einvoice_status end,
    notes = coalesce(notes || E'\n', '') || 'VOID: ' || p_reason
  where id = inv.id;
  perform set_config('abb.invoice_fn', 'off', true);
end $$;

create or replace view public.invoice_list with (security_invoker = true) as
select i.*, c.name as contact_name,
       case when i.status in ('draft','void') then 0 else i.total - i.amount_paid end as balance,
       (i.status in ('issued','partial') and i.due_date < current_date) as overdue
from invoices i left join contacts c on c.id = i.contact_id;

-- ===== RLS for finance =====
alter table public.accounts enable row level security;
alter table public.journal_entries enable row level security;
alter table public.journal_lines enable row level security;
alter table public.journal_counters enable row level security;
alter table public.invoices enable row level security;
alter table public.invoice_lines enable row level security;
alter table public.invoice_payments enable row level security;
alter table public.invoice_counters enable row level security;

create policy accounts_read on public.accounts for select using (has_perm(tenant_id, 'fin.ledger.view'));
create policy accounts_write on public.accounts for all
  using (has_perm(tenant_id, 'fin.journal.post') and not is_system)
  with check (has_perm(tenant_id, 'fin.journal.post') and not is_system);
create policy je_read on public.journal_entries for select using (has_perm(tenant_id, 'fin.ledger.view'));
create policy jl_read on public.journal_lines for select using (has_perm(tenant_id, 'fin.ledger.view'));

create policy inv_read on public.invoices for select using (has_perm(tenant_id, 'fin.invoice.view'));
create policy inv_write on public.invoices for all
  using (has_perm(tenant_id, 'fin.invoice.manage')) with check (has_perm(tenant_id, 'fin.invoice.manage'));
create policy invl_read on public.invoice_lines for select using (has_perm(tenant_id, 'fin.invoice.view'));
create policy invl_write on public.invoice_lines for all
  using (has_perm(tenant_id, 'fin.invoice.manage'))
  with check (exists (select 1 from invoices i where i.id = invoice_id and has_perm(i.tenant_id, 'fin.invoice.manage')));
create policy invp_read on public.invoice_payments for select using (has_perm(tenant_id, 'fin.invoice.view'));

do $$ declare t text; begin
  foreach t in array array['contacts','accounts','invoices','invoice_payments','tax_rates'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- ===== Reports =====
create or replace function public.sales_summary(p_tenant uuid, p_from date, p_to date, p_outlet uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not (has_perm(p_tenant, 'pos.report.view') or has_perm(p_tenant, 'fin.report.view')) then
    raise exception 'Not allowed to view reports';
  end if;
  with s as (
    select * from sales where tenant_id = p_tenant and status = 'completed'
      and (sold_at at time zone 'UTC')::date between p_from and p_to
      and (p_outlet is null or outlet_id = p_outlet)
  )
  select jsonb_build_object(
    'count', (select count(*) from s),
    'gross', (select coalesce(sum(subtotal),0) from s),
    'discount', (select coalesce(sum(discount_total),0) from s),
    'tax', (select coalesce(sum(tax_total),0) from s),
    'total', (select coalesce(sum(total),0) from s),
    'voided', (select count(*) from sales where tenant_id = p_tenant and status = 'voided'
                 and (sold_at at time zone 'UTC')::date between p_from and p_to and (p_outlet is null or outlet_id = p_outlet)),
    'by_day', (select coalesce(jsonb_agg(d order by d->>'day'),'[]') from (
                 select jsonb_build_object('day', (sold_at at time zone 'UTC')::date, 'count', count(*), 'total', sum(total)) d
                 from s group by (sold_at at time zone 'UTC')::date) x),
    'by_method', (select coalesce(jsonb_agg(m),'[]') from (
                 select jsonb_build_object('method', p.method, 'amount',
                   sum(case when p.method = 'cash' then p.amount - greatest(0, (select sum(p2.amount) from payments p2 where p2.sale_id = s.id) - s.total) else p.amount end)) m
                 from payments p join s on s.id = p.sale_id group by p.method) y),
    'top_items', (select coalesce(jsonb_agg(i order by (i->>'revenue')::numeric desc),'[]') from (
                 select jsonb_build_object('name', l.name, 'sku', l.sku, 'qty', sum(l.qty), 'revenue', sum(l.line_total - l.tax_amount)) i
                 from sale_lines l join s on s.id = l.sale_id group by l.name, l.sku
                 order by sum(l.line_total - l.tax_amount) desc limit 10) z)
  ) into r;
  return r;
end $$;

create or replace function public.trial_balance(p_tenant uuid, p_as_of date default current_date)
returns table (code text, name text, type text, debit numeric, credit numeric, balance numeric)
language plpgsql stable security definer set search_path = public as $$
begin
  if not has_perm(p_tenant, 'fin.ledger.view') then raise exception 'Not allowed'; end if;
  return query
  select a.code, a.name, a.type, coalesce(sum(jl.debit),0), coalesce(sum(jl.credit),0),
         case when a.type in ('asset','expense') then coalesce(sum(jl.debit - jl.credit),0)
              else coalesce(sum(jl.credit - jl.debit),0) end
  from accounts a
  left join journal_lines jl on jl.account_id = a.id
    and exists (select 1 from journal_entries je where je.id = jl.entry_id and je.entry_date <= p_as_of)
  where a.tenant_id = p_tenant
  group by a.id order by a.code;
end $$;

create or replace function public.profit_and_loss(p_tenant uuid, p_from date, p_to date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not has_perm(p_tenant, 'fin.report.view') then raise exception 'Not allowed'; end if;
  with x as (
    select a.code, a.name, a.type,
           sum(case when a.type = 'income' then jl.credit - jl.debit else jl.debit - jl.credit end) amt
    from journal_lines jl join journal_entries je on je.id = jl.entry_id join accounts a on a.id = jl.account_id
    where je.tenant_id = p_tenant and je.entry_date between p_from and p_to and a.type in ('income','expense')
    group by a.code, a.name, a.type
  )
  select jsonb_build_object(
    'income', coalesce((select sum(amt) from x where type = 'income'),0),
    'cogs', coalesce((select sum(amt) from x where code = '5000'),0),
    'expenses', coalesce((select sum(amt) from x where type = 'expense' and code <> '5000'),0),
    'net', coalesce((select sum(case when type = 'income' then amt else -amt end) from x),0),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('code',code,'name',name,'type',type,'amount',amt) order by code) from x),'[]')
  ) into r;
  return r;
end $$;

create or replace function public.tax_report(p_tenant uuid, p_from date, p_to date)
returns table (tax_name text, rate numeric, taxable numeric, tax numeric, source text)
language plpgsql stable security definer set search_path = public as $$
begin
  if not has_perm(p_tenant, 'fin.report.view') then raise exception 'Not allowed'; end if;
  return query
  select coalesce(l.tax_name, 'Tax ' || round(l.tax_rate*100,2) || '%'), l.tax_rate,
         sum(l.line_total - l.tax_amount), sum(l.tax_amount), 'POS'::text
  from sale_lines l join sales s on s.id = l.sale_id
  where s.tenant_id = p_tenant and s.status = 'completed' and (s.sold_at at time zone 'UTC')::date between p_from and p_to
  group by 1, 2
  union all
  select coalesce(l.tax_name, 'Tax ' || round(l.tax_rate*100,2) || '%'), l.tax_rate,
         sum(l.line_total - l.tax_amount), sum(l.tax_amount), 'Invoices'::text
  from invoice_lines l join invoices i on i.id = l.invoice_id
  where i.tenant_id = p_tenant and i.status in ('issued','partial','paid') and i.issue_date between p_from and p_to
  group by 1, 2
  order by 1, 5;
end $$;
