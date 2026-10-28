-- Ai buddy Biz — Batch D: CRM & leads
-- Contacts profile, sales pipeline (deals), activities & tasks, lead scoring,
-- web lead capture, loyalty points (earn/redeem at POS), segments & campaigns
-- with a consent-aware outbound message queue (WhatsApp / email / SMS).
-- Depends on 0001–0003.

-- ===== Permissions & roles =====
insert into public.permissions (code, module, description) values
  ('crm.contact.create','CRM','Add new customers (e.g. at the till)'),
  ('crm.deal.view','CRM','View leads and the sales pipeline'),
  ('crm.deal.manage','CRM','Create/move/close leads, log activities'),
  ('crm.campaign.manage','CRM','Create and send campaigns'),
  ('crm.loyalty.adjust','CRM','Manually adjust loyalty points'),
  ('crm.settings.manage','CRM','Pipelines, loyalty rules, lead form, messaging keys');

insert into public.roles (tenant_id, name, is_builtin) values (null, 'Sales', true);

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r join public.permissions p on p.code like 'crm.%'
where r.tenant_id is null and r.name in ('Owner','Admin')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r,
  unnest(array['crm.contact.create','crm.deal.view','crm.deal.manage','crm.campaign.manage','crm.loyalty.adjust']) c
where r.tenant_id is null and r.name = 'Manager'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r,
  unnest(array['crm.contact.view','crm.contact.manage','crm.contact.create','crm.deal.view','crm.deal.manage',
               'fin.invoice.view','fin.invoice.manage','inv.product.view']) c
where r.tenant_id is null and r.name = 'Sales'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, 'crm.contact.create' from public.roles r where r.tenant_id is null and r.name = 'Cashier'
on conflict do nothing;

-- ===== Contact profile =====
alter table public.contacts
  add column lifecycle text not null default 'lead' check (lifecycle in ('lead','prospect','customer','inactive')),
  add column source text,                               -- walk-in, website, facebook, referral, import…
  add column owner_id uuid references auth.users(id),
  add column tags text[] not null default '{}',
  add column birthday date,
  add column marketing_consent boolean not null default false,
  add column consent_at timestamptz,
  add column consent_source text,
  add column loyalty_points numeric(14,2) not null default 0,
  add column total_spent numeric(14,2) not null default 0,
  add column visits int not null default 0,
  add column last_purchase_at timestamptz,
  add column notes text,
  add column updated_at timestamptz not null default now();

create index on public.contacts (tenant_id, phone);
create index on public.contacts (tenant_id, lower(email));
create index on public.contacts using gin (tags);

-- Normalise phone numbers so "+60 12-345 6789" and "60123456789" match
create or replace function public.norm_phone(p text)
returns text language sql immutable as $$
  select nullif(regexp_replace(coalesce(p,''), '[^0-9]', '', 'g'), '');
$$;

create or replace function public.contact_before()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  if new.marketing_consent and (tg_op = 'INSERT' or not old.marketing_consent) then
    new.consent_at := coalesce(new.consent_at, now());
  end if;
  if not new.marketing_consent then new.consent_at := null; end if;
  new.tags := coalesce((select array_agg(distinct lower(trim(t))) from unnest(new.tags) t where trim(t) <> ''), '{}');
  return new;
end $$;
create trigger trg_contact_before before insert or update on public.contacts
  for each row execute function public.contact_before();

-- Cashiers may add customers but not edit or delete them
create policy contacts_create on public.contacts for insert
  with check (has_perm(tenant_id, 'crm.contact.create'));

-- ===== Pipelines =====
create table public.pipelines (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  is_default boolean not null default false,
  created_at timestamptz not null default now()
);

create table public.pipeline_stages (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  pipeline_id uuid not null references public.pipelines(id) on delete cascade,
  name text not null,
  sort_order int not null default 0,
  probability int not null default 0 check (probability between 0 and 100),
  kind text not null default 'open' check (kind in ('open','won','lost'))
);

create or replace function public.ensure_pipeline(p_tenant uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  select id into pid from pipelines where tenant_id = p_tenant and is_default;
  if pid is not null then return pid; end if;
  insert into pipelines (tenant_id, name, is_default) values (p_tenant, 'Sales', true) returning id into pid;
  insert into pipeline_stages (tenant_id, pipeline_id, name, sort_order, probability, kind) values
    (p_tenant, pid, 'New', 1, 10, 'open'),
    (p_tenant, pid, 'Contacted', 2, 25, 'open'),
    (p_tenant, pid, 'Qualified', 3, 50, 'open'),
    (p_tenant, pid, 'Proposal', 4, 70, 'open'),
    (p_tenant, pid, 'Negotiation', 5, 85, 'open'),
    (p_tenant, pid, 'Won', 6, 100, 'won'),
    (p_tenant, pid, 'Lost', 7, 0, 'lost');
  return pid;
end $$;

-- ===== Deals (leads in the pipeline) =====
create table public.deals (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  pipeline_id uuid not null references public.pipelines(id),
  stage_id uuid not null references public.pipeline_stages(id),
  contact_id uuid references public.contacts(id) on delete set null,
  title text not null,
  value numeric(14,2) not null default 0 check (value >= 0),
  currency char(3) not null,
  source text,
  owner_id uuid references auth.users(id) default auth.uid(),
  expected_close date,
  status text not null default 'open' check (status in ('open','won','lost')),
  lost_reason text,
  score int not null default 0,
  score_reasons jsonb not null default '[]',
  stage_changed_at timestamptz not null default now(),
  closed_at timestamptz,
  custom_values jsonb not null default '{}',
  created_at timestamptz not null default now()
);
create index on public.deals (tenant_id, status, stage_id);
create index on public.deals (contact_id);

-- Status follows the stage kind; contact lifecycle moves with it
create or replace function public.deal_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare st pipeline_stages;
begin
  select * into st from pipeline_stages where id = new.stage_id;
  if st.pipeline_id <> new.pipeline_id or st.tenant_id <> new.tenant_id then
    raise exception 'Stage does not belong to this pipeline';
  end if;
  if tg_op = 'INSERT' or new.stage_id <> old.stage_id then
    new.stage_changed_at := now();
    new.status := st.kind;
    new.closed_at := case when st.kind = 'open' then null else now() end;
  end if;
  if new.status <> 'lost' then new.lost_reason := null; end if;
  return new;
end $$;
create trigger trg_deal_before before insert or update on public.deals
  for each row execute function public.deal_before();

-- ===== Activities & tasks =====
create table public.activities (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  contact_id uuid references public.contacts(id) on delete cascade,
  deal_id uuid references public.deals(id) on delete cascade,
  kind text not null check (kind in ('note','call','whatsapp','email','meeting','task','visit','system')),
  body text,
  due_at timestamptz,                                   -- tasks/meetings
  done_at timestamptz,
  owner_id uuid references auth.users(id) default auth.uid(),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (contact_id is not null or deal_id is not null)
);
create index on public.activities (tenant_id, contact_id, created_at desc);
create index on public.activities (tenant_id, deal_id, created_at desc);
create index on public.activities (tenant_id, owner_id, due_at) where kind in ('task','meeting') and done_at is null;

-- ===== Lead scoring (rules; AI scoring is layered on in the AI batch) =====
create or replace function public.score_deal(p_deal uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  d deals; c contacts; st pipeline_stages;
  s int := 0; r jsonb := '[]';
  n_recent int; n_total int; last_touch timestamptz; avg_value numeric;
begin
  select * into d from deals where id = p_deal;
  if not found then return; end if;
  select * into st from pipeline_stages where id = d.stage_id;
  if d.status <> 'open' then
    update deals set score = case when d.status = 'won' then 100 else 0 end, score_reasons = '[]' where id = d.id;
    return;
  end if;
  select * into c from contacts where id = d.contact_id;

  s := s + st.probability * 3 / 10;  r := r || jsonb_build_object('stage', st.probability * 3 / 10);
  if c.phone is not null then s := s + 8;  r := r || '{"has_phone":8}'; end if;
  if c.email is not null then s := s + 4;  r := r || '{"has_email":4}'; end if;
  if c.lifecycle = 'customer' then s := s + 12; r := r || '{"existing_customer":12}'; end if;
  if c.marketing_consent then s := s + 3; r := r || '{"consented":3}'; end if;

  select count(*) filter (where created_at > now() - interval '7 days'), count(*), max(created_at)
    into n_recent, n_total, last_touch
  from activities where deal_id = d.id and kind <> 'system';
  if n_recent > 0 then s := s + least(20, n_recent * 7); r := r || jsonb_build_object('recent_activity', least(20, n_recent * 7)); end if;
  if n_total > 0 then s := s + least(10, n_total * 2); r := r || jsonb_build_object('engagement', least(10, n_total * 2)); end if;

  select avg(value) into avg_value from deals where tenant_id = d.tenant_id and value > 0;
  if d.value > 0 and avg_value > 0 and d.value >= avg_value then s := s + 8; r := r || '{"above_avg_value":8}'; end if;
  if d.expected_close is not null and d.expected_close <= current_date + 30 then s := s + 5; r := r || '{"closing_soon":5}'; end if;

  -- going cold
  if coalesce(last_touch, d.created_at) < now() - interval '14 days' then s := s - 15; r := r || '{"no_contact_14d":-15}'; end if;
  if d.expected_close is not null and d.expected_close < current_date then s := s - 10; r := r || '{"past_close_date":-10}'; end if;

  update deals set score = greatest(0, least(100, s)), score_reasons = r where id = d.id;
end $$;

create or replace function public.rescore_deals(p_tenant uuid)
returns int language plpgsql security definer set search_path = public as $$
declare d record; n int := 0;
begin
  if not has_perm(p_tenant, 'crm.deal.view') then raise exception 'Not allowed'; end if;
  for d in select id from deals where tenant_id = p_tenant and status = 'open' loop
    perform score_deal(d.id); n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.deal_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if pg_trigger_depth() > 1 then return null; end if;
  perform score_deal(new.id);
  if tg_op = 'UPDATE' and new.stage_id <> old.stage_id then
    insert into activities (tenant_id, contact_id, deal_id, kind, body)
    values (new.tenant_id, new.contact_id, new.id, 'system',
            'Moved to ' || (select name from pipeline_stages where id = new.stage_id)
            || case when new.lost_reason is not null then ' — ' || new.lost_reason else '' end);
  end if;
  if new.status = 'won' and new.contact_id is not null then
    update contacts set lifecycle = 'customer' where id = new.contact_id and lifecycle in ('lead','prospect');
  elsif new.status = 'open' and new.contact_id is not null then
    update contacts set lifecycle = 'prospect' where id = new.contact_id and lifecycle = 'lead'
      and (select probability from pipeline_stages where id = new.stage_id) >= 50;
  end if;
  return null;
end $$;
create trigger trg_deal_after after insert or update of stage_id, value, expected_close, contact_id on public.deals
  for each row execute function public.deal_after();

create or replace function public.activity_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.deal_id is not null and new.kind <> 'system' then perform score_deal(new.deal_id); end if;
  return null;
end $$;
create trigger trg_activity_after after insert on public.activities
  for each row execute function public.activity_after();

-- ===== CRM settings (per tenant) =====
-- Stored in tenant_modules where module = 'CRM':
--   {"loyalty":{"enabled":true,"points_per_unit":1,"point_value":0.01,"min_redeem":100},
--    "lead_form_key":"…"}
create or replace function public.crm_settings(p_tenant uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s jsonb;
begin
  insert into tenant_modules (tenant_id, module, settings)
  values (p_tenant, 'CRM', jsonb_build_object(
    'loyalty', jsonb_build_object('enabled', true, 'points_per_unit', 1, 'point_value', 0.01, 'min_redeem', 100),
    'lead_form_key', replace(gen_random_uuid()::text, '-', '')))
  on conflict (tenant_id, module) do nothing;
  select settings into s from tenant_modules where tenant_id = p_tenant and module = 'CRM';
  if s->'loyalty' is null or s->>'lead_form_key' is null then
    s := jsonb_build_object(
      'loyalty', coalesce(s->'loyalty', jsonb_build_object('enabled', true, 'points_per_unit', 1, 'point_value', 0.01, 'min_redeem', 100)),
      'lead_form_key', coalesce(s->>'lead_form_key', replace(gen_random_uuid()::text, '-', ''))) || s;
    update tenant_modules set settings = s where tenant_id = p_tenant and module = 'CRM';
  end if;
  return s;
end $$;

create or replace function public.update_crm_settings(p_tenant uuid, p_settings jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare cur jsonb; lo jsonb;
begin
  if not has_perm(p_tenant, 'crm.settings.manage') then raise exception 'Not allowed'; end if;
  cur := crm_settings(p_tenant);
  lo := coalesce(cur->'loyalty','{}') || coalesce(p_settings->'loyalty','{}');
  if (lo->>'points_per_unit')::numeric < 0 or (lo->>'point_value')::numeric < 0 or (lo->>'min_redeem')::numeric < 0 then
    raise exception 'Loyalty values cannot be negative';
  end if;
  cur := jsonb_set(cur, '{loyalty}', lo);
  if (p_settings->>'rotate_lead_form_key')::boolean then
    cur := jsonb_set(cur, '{lead_form_key}', to_jsonb(replace(gen_random_uuid()::text, '-', '')));
  end if;
  update tenant_modules set settings = cur where tenant_id = p_tenant and module = 'CRM';
  return cur;
end $$;

-- Readable CRM settings for members (the lead form key only for settings managers)
create or replace function public.get_crm_settings(p_tenant uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s jsonb;
begin
  if not is_member(p_tenant) then raise exception 'Not allowed'; end if;
  s := crm_settings(p_tenant);
  if not has_perm(p_tenant, 'crm.settings.manage') then s := s - 'lead_form_key'; end if;
  return s;
end $$;

-- ===== Web lead capture (callable without login using the form key) =====
create table public.lead_capture_log (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  at timestamptz not null default now()
);
create index on public.lead_capture_log (tenant_id, at);

create or replace function public.capture_lead(p_form_key text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  t uuid; cid uuid; did uuid; pid uuid; sid uuid;
  v_name text := left(trim(coalesce(p->>'name','')), 120);
  v_phone text := left(trim(coalesce(p->>'phone','')), 40);
  v_email text := lower(left(trim(coalesce(p->>'email','')), 160));
  v_msg text := left(coalesce(p->>'message',''), 2000);
  v_source text := left(coalesce(nullif(p->>'source',''), 'website'), 60);
  v_consent boolean := coalesce((p->>'marketing_consent')::boolean, false);
begin
  select tenant_id into t from tenant_modules where module = 'CRM' and settings->>'lead_form_key' = p_form_key;
  if t is null or length(coalesce(p_form_key,'')) < 16 then raise exception 'Invalid form'; end if;
  if v_name = '' or (v_phone = '' and v_email = '') then raise exception 'Name and phone or email are required'; end if;
  if v_email <> '' and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Invalid email'; end if;
  if (select count(*) from lead_capture_log where tenant_id = t and at > now() - interval '1 hour') >= 200 then
    raise exception 'Too many submissions, try later';
  end if;
  insert into lead_capture_log (tenant_id) values (t);

  -- de-duplicate by phone or email
  select id into cid from contacts
  where tenant_id = t and ((v_phone <> '' and norm_phone(phone) = norm_phone(v_phone)) or (v_email <> '' and lower(email) = v_email))
  order by created_at limit 1;
  if cid is null then
    insert into contacts (tenant_id, kind, name, phone, email, source, lifecycle, marketing_consent, consent_source)
    values (t, 'customer', v_name, nullif(v_phone,''), nullif(v_email,''), v_source, 'lead', v_consent,
            case when v_consent then 'web form' end)
    returning id into cid;
  elsif v_consent then
    update contacts set marketing_consent = true, consent_source = 'web form' where id = cid and not marketing_consent;
  end if;

  pid := ensure_pipeline(t);
  select id into sid from pipeline_stages where pipeline_id = pid and kind = 'open' order by sort_order limit 1;
  insert into deals (tenant_id, pipeline_id, stage_id, contact_id, title, value, currency, source, owner_id)
  values (t, pid, sid, cid, left(coalesce(nullif(p->>'interest',''), 'Enquiry from ' || v_name), 160),
          greatest(0, coalesce((p->>'value')::numeric, 0)), (select base_currency from tenants where id = t), v_source, null)
  returning id into did;
  if v_msg <> '' then
    insert into activities (tenant_id, contact_id, deal_id, kind, body, owner_id, created_by)
    values (t, cid, did, 'note', 'Web enquiry: ' || v_msg, null, null);
  end if;
  return jsonb_build_object('ok', true);
end $$;

-- ===== Loyalty =====
create table public.loyalty_ledger (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete cascade,
  points numeric(14,2) not null,
  reason text not null check (reason in ('earn','redeem','adjust','void','expire')),
  sale_id uuid references public.sales(id) on delete set null,
  note text,
  created_by uuid default auth.uid(),
  at timestamptz not null default now()
);
create index on public.loyalty_ledger (contact_id, at desc);

create or replace function public.loyalty_ledger_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update contacts set loyalty_points = loyalty_points + new.points where id = new.contact_id;
  return null;
end $$;
create trigger trg_loyalty_after after insert on public.loyalty_ledger
  for each row execute function public.loyalty_ledger_after();

alter table public.payments drop constraint payments_method_check;
alter table public.payments add constraint payments_method_check
  check (method in ('cash','card','qr','ewallet','bank_transfer','voucher','store_credit','loyalty','other'));

-- Paying with points: checks and deducts the balance as the payment is recorded
create or replace function public.loyalty_payment_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare s sales; lo jsonb; pts numeric; bal numeric;
begin
  if new.method <> 'loyalty' then return new; end if;
  select * into s from sales where id = new.sale_id;
  if s.customer_id is null then raise exception 'Choose a customer to pay with points'; end if;
  lo := crm_settings(s.tenant_id)->'loyalty';
  if not coalesce((lo->>'enabled')::boolean, false) then raise exception 'Loyalty is turned off'; end if;
  pts := ceil(new.amount / nullif((lo->>'point_value')::numeric, 0));
  if pts is null then raise exception 'Point value is not set'; end if;
  select loyalty_points into bal from contacts where id = s.customer_id for update;
  if pts < coalesce((lo->>'min_redeem')::numeric, 0) then
    raise exception 'Minimum % points to redeem', (lo->>'min_redeem');
  end if;
  if bal < pts then raise exception 'Not enough points: has %, needs %', bal, pts; end if;
  insert into loyalty_ledger (tenant_id, contact_id, points, reason, sale_id)
  values (s.tenant_id, s.customer_id, -pts, 'redeem', s.id);
  return new;
end $$;
create trigger trg_loyalty_payment before insert on public.payments
  for each row execute function public.loyalty_payment_before();

-- Earn points and update customer stats when a sale completes; reverse on void
create or replace function public.sale_crm_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare lo jsonb; pts numeric; paid_points numeric;
begin
  if new.customer_id is null then return null; end if;
  -- complete_sale writes totals in one update after inserting the sale
  if old.total = 0 and new.total > 0 and new.status = 'completed' then
    select coalesce(sum(amount),0) into paid_points from payments where sale_id = new.id and method = 'loyalty';
    lo := crm_settings(new.tenant_id)->'loyalty';
    if coalesce((lo->>'enabled')::boolean, false) then
      pts := floor((new.total - paid_points) * coalesce((lo->>'points_per_unit')::numeric, 0));
      if pts > 0 then
        insert into loyalty_ledger (tenant_id, contact_id, points, reason, sale_id, created_by)
        values (new.tenant_id, new.customer_id, pts, 'earn', new.id, new.cashier_id);
      end if;
    end if;
    update contacts set total_spent = total_spent + new.total, visits = visits + 1,
      last_purchase_at = greatest(coalesce(last_purchase_at, new.sold_at), new.sold_at),
      lifecycle = 'customer'
    where id = new.customer_id;
  elsif old.status = 'completed' and new.status = 'voided' then
    insert into loyalty_ledger (tenant_id, contact_id, points, reason, sale_id, note)
    select new.tenant_id, new.customer_id, -sum(points), 'void', new.id, 'Sale ' || new.receipt_no || ' voided'
    from loyalty_ledger where sale_id = new.id and reason in ('earn','redeem')
    having sum(points) <> 0;
    update contacts set total_spent = greatest(0, total_spent - new.total), visits = greatest(0, visits - 1)
    where id = new.customer_id;
  end if;
  return null;
end $$;
create trigger trg_sale_crm after update of total, status on public.sales
  for each row execute function public.sale_crm_after();

create or replace function public.adjust_points(p_contact uuid, p_points numeric, p_note text)
returns numeric language plpgsql security definer set search_path = public as $$
declare c contacts;
begin
  select * into c from contacts where id = p_contact;
  if not found then raise exception 'Unknown customer'; end if;
  if not has_perm(c.tenant_id, 'crm.loyalty.adjust') then raise exception 'Not allowed to adjust points'; end if;
  if coalesce(trim(p_note),'') = '' then raise exception 'A reason is required'; end if;
  if c.loyalty_points + p_points < 0 then raise exception 'Balance cannot go below zero'; end if;
  insert into loyalty_ledger (tenant_id, contact_id, points, reason, note) values (c.tenant_id, c.id, p_points, 'adjust', p_note);
  return c.loyalty_points + p_points;
end $$;

-- Accounting: points used as payment are a loyalty cost, not money in the card account
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
    (p_tenant,'6100','Inventory adjustments & losses','expense',true),
    (p_tenant,'6200','Loyalty rewards','expense',true)
  on conflict (tenant_id, code) do nothing;
$$;

create or replace function public.post_sale(p_sale uuid)
returns void language plpgsql security definer set search_path = public as $$
declare s sales; v_loyalty numeric; v_noncash numeric; v_tax numeric; v_cogs numeric;
begin
  select * into s from sales where id = p_sale;
  select coalesce(sum(amount),0) into v_loyalty from payments where sale_id = s.id and method = 'loyalty';
  v_loyalty := least(v_loyalty, s.total);
  select coalesce(sum(amount),0) into v_noncash from payments where sale_id = s.id and method not in ('cash','loyalty');
  v_noncash := least(v_noncash, s.total - v_loyalty);
  select coalesce(sum(tax_amount),0) into v_tax from sale_lines where sale_id = s.id;
  select coalesce(sum(l.qty * v.cost),0) into v_cogs
    from sale_lines l join product_variants v on v.id = l.variant_id where l.sale_id = s.id and v.track_stock;
  perform post_entry(s.tenant_id, (s.sold_at at time zone 'UTC')::date, 'Sale ' || s.receipt_no, 'sale', s.id, jsonb_build_array(
    jsonb_build_object('code','1000','debit', s.total - v_noncash - v_loyalty),
    jsonb_build_object('code','1010','debit', v_noncash),
    jsonb_build_object('code','6200','debit', v_loyalty),
    jsonb_build_object('code','4000','credit', s.total - v_tax),
    jsonb_build_object('code','2100','credit', v_tax),
    jsonb_build_object('code','5000','debit', round(v_cogs,2)),
    jsonb_build_object('code','1200','credit', round(v_cogs,2))));
end $$;

-- Cash expected in drawer must ignore points payments as well as card/QR
create or replace function public.shift_expected_cash(p_shift uuid)
returns numeric language sql stable security definer set search_path = public as $$
  select sh.opening_cash + coalesce((
    select sum(s.total - least(s.total, coalesce((select sum(p.amount) from payments p where p.sale_id = s.id and p.method <> 'cash'),0)))
    from sales s where s.shift_id = sh.id and s.status = 'completed'), 0)
  from shifts sh where sh.id = p_shift;
$$;

-- ===== Segments & campaigns =====
-- Filter keys (all optional): tags_any[], lifecycle[], min_spent, max_spent, min_visits,
-- inactive_days (no purchase for N days), active_days (bought within N days),
-- birthday_month (1–12), min_points, source
create or replace function public.segment_match(c public.contacts, f jsonb)
returns boolean language sql stable as $$
  select
    (f->'tags_any' is null or jsonb_array_length(f->'tags_any') = 0
       or c.tags && array(select lower(jsonb_array_elements_text(f->'tags_any'))))
    and (f->'lifecycle' is null or jsonb_array_length(f->'lifecycle') = 0
       or c.lifecycle = any(array(select jsonb_array_elements_text(f->'lifecycle'))))
    and (f->>'min_spent' is null or c.total_spent >= (f->>'min_spent')::numeric)
    and (f->>'max_spent' is null or c.total_spent <= (f->>'max_spent')::numeric)
    and (f->>'min_visits' is null or c.visits >= (f->>'min_visits')::int)
    and (f->>'min_points' is null or c.loyalty_points >= (f->>'min_points')::numeric)
    and (f->>'inactive_days' is null or c.last_purchase_at is null
       or c.last_purchase_at < now() - make_interval(days => (f->>'inactive_days')::int))
    and (f->>'active_days' is null
       or c.last_purchase_at >= now() - make_interval(days => (f->>'active_days')::int))
    and (f->>'birthday_month' is null or extract(month from c.birthday) = (f->>'birthday_month')::int)
    and (f->>'source' is null or c.source = f->>'source');
$$;

create or replace function public.segment_preview(p_tenant uuid, p_filter jsonb, p_channel text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare total int; reachable int;
begin
  if not has_perm(p_tenant, 'crm.campaign.manage') then raise exception 'Not allowed'; end if;
  select count(*),
         count(*) filter (where c.marketing_consent and case p_channel
             when 'email' then c.email is not null else norm_phone(c.phone) is not null end)
    into total, reachable
  from contacts c where c.tenant_id = p_tenant and c.kind in ('customer','both') and segment_match(c, coalesce(p_filter,'{}'));
  return jsonb_build_object('matched', total, 'reachable', reachable, 'no_consent_or_address', total - reachable);
end $$;

create table public.campaigns (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  channel text not null check (channel in ('whatsapp','email','sms')),
  filter jsonb not null default '{}',
  subject text,                                         -- email
  body text not null,                                   -- supports {{name}}, {{first_name}}, {{points}}, {{business}}
  wa_template text,                                     -- approved WhatsApp template name (required by Meta for marketing)
  wa_language text default 'en',
  status text not null default 'draft' check (status in ('draft','queued','sending','sent','cancelled')),
  scheduled_at timestamptz,
  queued_count int not null default 0,
  sent_count int not null default 0,
  failed_count int not null default 0,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create table public.outbound_messages (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  campaign_id uuid references public.campaigns(id) on delete cascade,
  contact_id uuid references public.contacts(id) on delete set null,
  channel text not null check (channel in ('whatsapp','email','sms')),
  to_address text not null,
  subject text,
  body text not null,
  wa_template text,
  wa_language text,
  wa_params jsonb,
  status text not null default 'queued' check (status in ('queued','sending','sent','failed','cancelled')),
  send_after timestamptz not null default now(),
  attempts int not null default 0,
  provider_id text,
  error text,
  sent_at timestamptz,
  created_at timestamptz not null default now(),
  unique (campaign_id, contact_id)
);
create index on public.outbound_messages (status, send_after) where status = 'queued';

create or replace function public.render_template(p_body text, c public.contacts, p_business text)
returns text language sql immutable as $$
  select replace(replace(replace(replace(p_body,
    '{{name}}', coalesce(c.name,'')),
    '{{first_name}}', coalesce(split_part(c.name,' ',1),'')),
    '{{points}}', trim(to_char(c.loyalty_points, 'FM999999990'))),
    '{{business}}', coalesce(p_business,''));
$$;

-- Builds the message list for a campaign. Only contacts who consented and have an address are included.
create or replace function public.queue_campaign(p_campaign uuid)
returns int language plpgsql security definer set search_path = public as $$
declare cp campaigns; biz text; n int;
begin
  select * into cp from campaigns where id = p_campaign for update;
  if not found then raise exception 'Unknown campaign'; end if;
  if not has_perm(cp.tenant_id, 'crm.campaign.manage') then raise exception 'Not allowed'; end if;
  if cp.status <> 'draft' then raise exception 'Campaign is already %', cp.status; end if;
  if cp.channel = 'whatsapp' and coalesce(cp.wa_template,'') = '' then
    raise exception 'WhatsApp campaigns need an approved template name';
  end if;
  if cp.channel = 'email' and coalesce(cp.subject,'') = '' then raise exception 'Email campaigns need a subject'; end if;
  select name into biz from tenants where id = cp.tenant_id;

  insert into outbound_messages (tenant_id, campaign_id, contact_id, channel, to_address, subject, body,
                                 wa_template, wa_language, wa_params, send_after)
  select cp.tenant_id, cp.id, c.id, cp.channel,
         case when cp.channel = 'email' then lower(c.email) else norm_phone(c.phone) end,
         cp.subject, render_template(cp.body, c, biz),
         cp.wa_template, cp.wa_language,
         case when cp.channel = 'whatsapp' then jsonb_build_array(split_part(c.name,' ',1)) end,
         coalesce(cp.scheduled_at, now())
  from contacts c
  where c.tenant_id = cp.tenant_id and c.kind in ('customer','both')
    and c.marketing_consent
    and case when cp.channel = 'email' then c.email is not null else norm_phone(c.phone) is not null end
    and segment_match(c, cp.filter)
  on conflict (campaign_id, contact_id) do nothing;
  get diagnostics n = row_count;

  update campaigns set status = 'queued', queued_count = n where id = cp.id;
  insert into activities (tenant_id, contact_id, kind, body, created_by)
  select cp.tenant_id, contact_id, 'system', 'Campaign "' || cp.name || '" queued (' || cp.channel || ')', auth.uid()
  from outbound_messages where campaign_id = cp.id;
  return n;
end $$;

create or replace function public.cancel_campaign(p_campaign uuid)
returns void language plpgsql security definer set search_path = public as $$
declare cp campaigns;
begin
  select * into cp from campaigns where id = p_campaign;
  if not has_perm(cp.tenant_id, 'crm.campaign.manage') then raise exception 'Not allowed'; end if;
  update outbound_messages set status = 'cancelled' where campaign_id = cp.id and status = 'queued';
  update campaigns set status = 'cancelled' where id = cp.id and status in ('draft','queued');
end $$;

-- One-off message to a single customer (e.g. "your order is ready"); transactional, so no marketing consent needed
create or replace function public.send_message(p_contact uuid, p_channel text, p_body text, p_subject text default null,
                                               p_wa_template text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare c contacts; mid uuid; addr text;
begin
  select * into c from contacts where id = p_contact;
  if not found or not (has_perm(c.tenant_id, 'crm.deal.manage') or has_perm(c.tenant_id, 'crm.contact.manage')) then
    raise exception 'Not allowed';
  end if;
  addr := case when p_channel = 'email' then lower(c.email) else norm_phone(c.phone) end;
  if addr is null then raise exception 'Customer has no % address', p_channel; end if;
  insert into outbound_messages (tenant_id, contact_id, channel, to_address, subject, body, wa_template, wa_params)
  values (c.tenant_id, c.id, p_channel, addr, p_subject, p_body, p_wa_template,
          case when p_wa_template is not null then jsonb_build_array(split_part(c.name,' ',1)) end)
  returning id into mid;
  insert into activities (tenant_id, contact_id, kind, body) values (c.tenant_id, c.id,
    case p_channel when 'email' then 'email' when 'whatsapp' then 'whatsapp' else 'note' end, p_body);
  return mid;
end $$;

-- Called by the sender (service role) after each attempt
create or replace function public.campaign_refresh_counts(p_campaign uuid)
returns void language sql security definer set search_path = public as $$
  update campaigns cp set
    sent_count = (select count(*) from outbound_messages where campaign_id = cp.id and status = 'sent'),
    failed_count = (select count(*) from outbound_messages where campaign_id = cp.id and status = 'failed'),
    status = case
      when cp.status in ('queued','sending') and not exists
        (select 1 from outbound_messages where campaign_id = cp.id and status in ('queued','sending')) then 'sent'
      when cp.status = 'queued' then 'sending' else cp.status end
  where cp.id = p_campaign;
$$;

-- ===== Messaging credentials (never readable by app users) =====
create table public.integration_secrets (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  provider text not null check (provider in ('whatsapp_cloud','resend','twilio','myinvois')),
  config jsonb not null,                                -- e.g. {"phone_number_id":"…","token":"…"}
  updated_at timestamptz not null default now(),
  primary key (tenant_id, provider)
);
alter table public.integration_secrets enable row level security;  -- no policies: only the service role reads it

create or replace function public.set_integration_secret(p_tenant uuid, p_provider text, p_config jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  if not has_perm(p_tenant, 'crm.settings.manage') then raise exception 'Not allowed'; end if;
  insert into integration_secrets (tenant_id, provider, config) values (p_tenant, p_provider, p_config)
  on conflict (tenant_id, provider) do update set config = excluded.config, updated_at = now();
end $$;

create or replace function public.integration_status(p_tenant uuid)
returns table (provider text, configured boolean, updated_at timestamptz)
language sql stable security definer set search_path = public as $$
  select p, s.tenant_id is not null, s.updated_at
  from unnest(array['whatsapp_cloud','resend','twilio','myinvois']) p
  left join integration_secrets s on s.tenant_id = p_tenant and s.provider = p
  where is_member(p_tenant);
$$;

-- ===== Helpful views =====
create or replace view public.my_tasks with (security_invoker = true) as
select a.*, c.name as contact_name, c.phone as contact_phone, d.title as deal_title,
       (a.due_at < now()) as overdue
from activities a
left join contacts c on c.id = a.contact_id
left join deals d on d.id = a.deal_id
where a.kind in ('task','meeting') and a.done_at is null;

create or replace view public.deal_board with (security_invoker = true) as
select d.*, s.name as stage_name, s.sort_order as stage_order, s.probability,
       c.name as contact_name, c.phone as contact_phone, c.email as contact_email,
       (select max(created_at) from activities a where a.deal_id = d.id and a.kind <> 'system') as last_activity_at
from deals d
join pipeline_stages s on s.id = d.stage_id
left join contacts c on c.id = d.contact_id;

create or replace function public.pipeline_summary(p_tenant uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r jsonb;
begin
  if not has_perm(p_tenant, 'crm.deal.view') then raise exception 'Not allowed'; end if;
  select jsonb_build_object(
    'open_count', count(*) filter (where d.status = 'open'),
    'open_value', coalesce(sum(d.value) filter (where d.status = 'open'),0),
    'weighted_value', round(coalesce(sum(d.value * s.probability / 100.0) filter (where d.status = 'open'),0), 2),
    'won_30d', count(*) filter (where d.status = 'won' and d.closed_at > now() - interval '30 days'),
    'won_value_30d', coalesce(sum(d.value) filter (where d.status = 'won' and d.closed_at > now() - interval '30 days'),0),
    'lost_30d', count(*) filter (where d.status = 'lost' and d.closed_at > now() - interval '30 days'),
    'win_rate_90d', round(100.0 * count(*) filter (where d.status = 'won' and d.closed_at > now() - interval '90 days')
                     / nullif(count(*) filter (where d.status in ('won','lost') and d.closed_at > now() - interval '90 days'),0), 1)
  ) into r
  from deals d join pipeline_stages s on s.id = d.stage_id where d.tenant_id = p_tenant;
  return r;
end $$;

-- ===== RLS =====
alter table public.pipelines enable row level security;
alter table public.pipeline_stages enable row level security;
alter table public.deals enable row level security;
alter table public.activities enable row level security;
alter table public.loyalty_ledger enable row level security;
alter table public.campaigns enable row level security;
alter table public.outbound_messages enable row level security;
alter table public.lead_capture_log enable row level security;

create policy pipelines_read on public.pipelines for select using (has_perm(tenant_id, 'crm.deal.view'));
create policy pipelines_write on public.pipelines for all
  using (has_perm(tenant_id, 'crm.settings.manage')) with check (has_perm(tenant_id, 'crm.settings.manage'));
create policy stages_read on public.pipeline_stages for select using (has_perm(tenant_id, 'crm.deal.view'));
create policy stages_write on public.pipeline_stages for all
  using (has_perm(tenant_id, 'crm.settings.manage')) with check (has_perm(tenant_id, 'crm.settings.manage'));

create policy deals_read on public.deals for select using (has_perm(tenant_id, 'crm.deal.view'));
create policy deals_write on public.deals for all
  using (has_perm(tenant_id, 'crm.deal.manage')) with check (has_perm(tenant_id, 'crm.deal.manage'));

create policy activities_read on public.activities for select
  using (has_perm(tenant_id, 'crm.deal.view') or has_perm(tenant_id, 'crm.contact.view'));
create policy activities_insert on public.activities for insert
  with check ((has_perm(tenant_id, 'crm.deal.manage') or has_perm(tenant_id, 'crm.contact.manage')) and kind <> 'system');
create policy activities_update on public.activities for update
  using (has_perm(tenant_id, 'crm.deal.manage') and (owner_id = auth.uid() or created_by = auth.uid() or has_perm(tenant_id, 'crm.settings.manage')))
  with check (kind <> 'system');
create policy activities_delete on public.activities for delete
  using (kind <> 'system' and (created_by = auth.uid() or has_perm(tenant_id, 'crm.settings.manage')));

create policy loyalty_read on public.loyalty_ledger for select using (has_perm(tenant_id, 'crm.contact.view'));

create policy campaigns_read on public.campaigns for select using (has_perm(tenant_id, 'crm.campaign.manage'));
create policy campaigns_insert on public.campaigns for insert
  with check (has_perm(tenant_id, 'crm.campaign.manage') and status = 'draft');
create policy campaigns_update on public.campaigns for update
  using (has_perm(tenant_id, 'crm.campaign.manage') and status = 'draft')
  with check (has_perm(tenant_id, 'crm.campaign.manage') and status = 'draft');
create policy campaigns_delete on public.campaigns for delete
  using (has_perm(tenant_id, 'crm.campaign.manage') and status = 'draft');
create policy outbound_read on public.outbound_messages for select
  using (has_perm(tenant_id, 'crm.campaign.manage') or has_perm(tenant_id, 'crm.contact.manage'));

do $$ declare t text; begin
  foreach t in array array['deals','pipelines','pipeline_stages','campaigns','loyalty_ledger'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- Lead form is public: allow the anonymous role to call only this function
revoke execute on function public.capture_lead(text, jsonb) from public;
grant execute on function public.capture_lead(text, jsonb) to anon, authenticated;

-- New tenants get a pipeline and CRM settings straight away
create or replace function public.tenant_crm_init()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform ensure_pipeline(new.id);
  perform crm_settings(new.id);
  return null;
end $$;
create trigger trg_tenant_crm_init after insert on public.tenants
  for each row execute function public.tenant_crm_init();

do $$ declare t record; begin
  for t in select id from public.tenants loop
    perform public.ensure_pipeline(t.id);
    perform public.crm_settings(t.id);
  end loop;
end $$;
