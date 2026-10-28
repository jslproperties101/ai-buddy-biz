-- Ai buddy Biz — Batch D: CRM and leads
-- Customer profiles with consent, pipeline & deals, activities/tasks, lead scoring,
-- loyalty points (earn on sale, redeem at POS), segments, campaigns, web lead forms.
-- Depends on 0001–0003.

-- ===== Permissions =====
insert into public.permissions (code, module, description) values
  ('crm.contact.create','CRM','Add customers (e.g. at the POS)'),
  ('crm.deal.manage','CRM','Manage pipeline and deals'),
  ('crm.campaign.manage','CRM','Create and send campaigns'),
  ('crm.loyalty.manage','CRM','Loyalty settings and point adjustments'),
  ('crm.form.manage','CRM','Manage web lead forms');

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r cross join public.permissions p
where r.tenant_id is null and r.name in ('Owner','Admin','Manager')
  and p.module = 'CRM'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, 'crm.contact.create' from public.roles r
where r.tenant_id is null and r.name = 'Cashier'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, 'crm.contact.view' from public.roles r
where r.tenant_id is null and r.name = 'Accountant'
on conflict do nothing;

-- ===== Contacts: CRM fields =====
create or replace function public.normalize_phone(p_phone text, p_country char(2))
returns text language sql immutable as $$
  select case
    when p_phone is null or regexp_replace(p_phone, '\D', '', 'g') = '' then null
    when p_phone ~ '^\s*\+' then regexp_replace(p_phone, '\D', '', 'g')
    when regexp_replace(p_phone, '\D', '', 'g') ~ '^0' then
      case p_country when 'MY' then '60' when 'SG' then '65' when 'ID' then '62' when 'TH' then '66'
                     when 'PH' then '63' when 'VN' then '84' when 'IN' then '91' when 'GB' then '44'
                     when 'AU' then '61' when 'NZ' then '64' else '' end
      || substr(regexp_replace(p_phone, '\D', '', 'g'), 2)
    else regexp_replace(p_phone, '\D', '', 'g')
  end;
$$;

alter table public.contacts
  add column lifecycle text not null default 'customer' check (lifecycle in ('lead','prospect','customer','inactive')),
  add column source text,                        -- walk_in, web_form, referral, whatsapp, facebook, event, import…
  add column owner_id uuid references auth.users(id) on delete set null,
  add column tags text[] not null default '{}',
  add column score int not null default 0,
  add column phone_norm text,                    -- digits with country code, for WhatsApp and de-duplication
  add column whatsapp_opt_in boolean not null default false,
  add column email_opt_in boolean not null default false,
  add column consent_at timestamptz,
  add column consent_source text,
  add column birthday date,
  add column notes text,
  add column last_contacted_at timestamptz;

create unique index contacts_phone_unique on public.contacts (tenant_id, phone_norm) where phone_norm is not null;
create index contacts_tags on public.contacts using gin (tags);

-- ===== Lead scoring =====
create table public.lead_score_rules (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  kind text not null check (kind in ('source','tag','lifecycle','activity','spend_over','purchased_within_days','open_deal')),
  match text,                                    -- e.g. 'referral', 'vip', 'meeting', '1000', '30'
  points int not null,
  unique (tenant_id, kind, match)
);

create or replace function public.ensure_crm_defaults(p_tenant uuid)
returns void language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  insert into lead_score_rules (tenant_id, kind, match, points) values
    (p_tenant,'source','referral',20), (p_tenant,'source','web_form',10), (p_tenant,'source','whatsapp',10),
    (p_tenant,'activity','meeting',15), (p_tenant,'activity','call',5), (p_tenant,'activity','whatsapp',5),
    (p_tenant,'activity','email',3), (p_tenant,'tag','vip',25), (p_tenant,'lifecycle','prospect',10),
    (p_tenant,'spend_over','1000',20), (p_tenant,'purchased_within_days','30',10), (p_tenant,'open_deal',null,15)
  on conflict do nothing;

  if not exists (select 1 from pipelines where tenant_id = p_tenant) then
    insert into pipelines (tenant_id, name, is_default) values (p_tenant, 'Sales', true) returning id into pid;
    insert into pipeline_stages (tenant_id, pipeline_id, name, sort_order, probability, kind) values
      (p_tenant, pid, 'New lead', 1, 10, 'open'), (p_tenant, pid, 'Contacted', 2, 20, 'open'),
      (p_tenant, pid, 'Qualified', 3, 40, 'open'), (p_tenant, pid, 'Proposal sent', 4, 60, 'open'),
      (p_tenant, pid, 'Negotiation', 5, 80, 'open'), (p_tenant, pid, 'Won', 6, 100, 'won'),
      (p_tenant, pid, 'Lost', 7, 0, 'lost');
  end if;

  insert into loyalty_settings (tenant_id) values (p_tenant) on conflict do nothing;
end $$;

-- ===== Pipeline & deals =====
create table public.pipelines (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  is_default boolean not null default false
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

create table public.deals (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  pipeline_id uuid not null references public.pipelines(id),
  stage_id uuid not null references public.pipeline_stages(id),
  contact_id uuid references public.contacts(id) on delete set null,
  title text not null,
  value numeric(14,2) not null default 0 check (value >= 0),
  currency char(3),
  owner_id uuid references auth.users(id) on delete set null default auth.uid(),
  expected_close date,
  status text not null default 'open' check (status in ('open','won','lost')),
  closed_at timestamptz,
  lost_reason text,
  source text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index on public.deals (tenant_id, status, stage_id);

create or replace function public.deals_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare st pipeline_stages;
begin
  select * into st from pipeline_stages where id = new.stage_id;
  if st.pipeline_id <> new.pipeline_id or st.tenant_id <> new.tenant_id then raise exception 'Stage does not belong to this pipeline'; end if;
  new.status := st.kind;
  new.closed_at := case when st.kind = 'open' then null else coalesce(case when tg_op = 'UPDATE' and old.status = st.kind then old.closed_at end, now()) end;
  if st.kind <> 'lost' then new.lost_reason := null; end if;
  new.updated_at := now();
  if new.currency is null then new.currency := (select base_currency from tenants where id = new.tenant_id); end if;
  return new;
end $$;
create trigger trg_deals_before before insert or update on public.deals
  for each row execute function public.deals_before();

-- Moving a deal logs an activity; winning makes the contact a customer; scores refresh
create or replace function public.deals_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.contact_id is not null then
    if tg_op = 'INSERT' or old.stage_id <> new.stage_id then
      insert into activities (tenant_id, contact_id, deal_id, kind, subject, created_by)
      values (new.tenant_id, new.contact_id, new.id, 'system',
              'Deal "' || new.title || '" → ' || (select name from pipeline_stages where id = new.stage_id), auth.uid());
    end if;
    if new.status = 'won' then
      update contacts set lifecycle = 'customer' where id = new.contact_id and lifecycle in ('lead','prospect');
    elsif new.status = 'open' then
      update contacts set lifecycle = 'prospect' where id = new.contact_id and lifecycle = 'lead';
    end if;
    update contacts set score = score where id = new.contact_id;   -- recompute
  end if;
  return null;
end $$;
create trigger trg_deals_after after insert or update on public.deals
  for each row execute function public.deals_after();

-- ===== Activities & tasks =====
create table public.activities (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  contact_id uuid references public.contacts(id) on delete cascade,
  deal_id uuid references public.deals(id) on delete cascade,
  kind text not null check (kind in ('note','call','whatsapp','email','sms','meeting','visit','task','system')),
  subject text not null,
  body text,
  due_at timestamptz,                            -- tasks
  done_at timestamptz,
  assigned_to uuid references auth.users(id) on delete set null,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.activities (tenant_id, contact_id, created_at desc);
create index on public.activities (tenant_id, assigned_to, done_at, due_at) where kind = 'task';

create or replace function public.activities_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.contact_id is not null and new.kind not in ('task','system','note') then
    update contacts set last_contacted_at = greatest(coalesce(last_contacted_at, new.created_at), new.created_at)
    where id = new.contact_id;
  elsif new.contact_id is not null and new.kind <> 'system' then
    update contacts set score = score where id = new.contact_id;
  end if;
  return null;
end $$;
create trigger trg_activities_after after insert on public.activities
  for each row execute function public.activities_after();

-- ===== Lead score calculation (needs deals + activities) =====
create or replace function public.compute_lead_score(p_contact uuid, p_tenant uuid, p_source text, p_tags text[], p_lifecycle text)
returns int language sql stable security definer set search_path = public as $$
  with spend as (
    select coalesce(sum(total),0) as amt, max(sold_at) as last_at
    from sales where customer_id = p_contact and status = 'completed'
  ), acts as (
    select distinct kind from activities where contact_id = p_contact and kind <> 'task' and created_at > now() - interval '90 days'
  )
  select coalesce(sum(r.points),0)::int from lead_score_rules r
  where r.tenant_id = p_tenant and (
       (r.kind = 'source' and r.match = p_source)
    or (r.kind = 'tag' and r.match = any(p_tags))
    or (r.kind = 'lifecycle' and r.match = p_lifecycle)
    or (r.kind = 'activity' and r.match in (select kind from acts))
    or (r.kind = 'spend_over' and (select amt from spend) >= r.match::numeric)
    or (r.kind = 'purchased_within_days' and (select last_at from spend) > now() - (r.match || ' days')::interval)
    or (r.kind = 'open_deal' and exists (select 1 from deals d where d.contact_id = p_contact and d.status = 'open'))
  );
$$;

create or replace function public.contacts_before()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.phone_norm := normalize_phone(new.phone, (select country_code from tenants where id = new.tenant_id));
  if new.tags is null then new.tags := '{}'; end if;
  new.tags := array(select distinct lower(trim(t)) from unnest(new.tags) t where trim(t) <> '');
  if (new.whatsapp_opt_in or new.email_opt_in) and new.consent_at is null then new.consent_at := now(); end if;
  if tg_op = 'INSERT' then
    perform ensure_crm_defaults(new.tenant_id);
    new.score := coalesce((select sum(points) from lead_score_rules r where r.tenant_id = new.tenant_id and (
                   (r.kind = 'source' and r.match = new.source) or (r.kind = 'tag' and r.match = any(new.tags))
                   or (r.kind = 'lifecycle' and r.match = new.lifecycle))), 0);
  else
    new.score := compute_lead_score(new.id, new.tenant_id, new.source, new.tags, new.lifecycle);
  end if;
  return new;
end $$;
create trigger trg_contacts_before before insert or update on public.contacts
  for each row execute function public.contacts_before();

-- ===== Loyalty =====
create table public.loyalty_settings (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  enabled boolean not null default false,
  points_per_unit numeric(10,4) not null default 1,    -- points earned per 1.00 of currency spent
  redeem_value numeric(10,4) not null default 0.01,    -- currency value of 1 point
  min_redeem int not null default 100
);

create table public.loyalty_ledger (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete cascade,
  kind text not null check (kind in ('earn','redeem','adjust','reverse')),
  points int not null,
  sale_id uuid references public.sales(id) on delete set null,
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.loyalty_ledger (contact_id);

create or replace function public.points_balance(p_contact uuid)
returns int language sql stable security definer set search_path = public as $$
  select coalesce(sum(points),0)::int from loyalty_ledger where contact_id = p_contact;
$$;

-- Chart gets a loyalty expense account
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

-- Redeeming at the POS: a payment {method:'voucher', reference:'points:<n>'}.
-- The server sets the amount from the points, checks the balance and books the reward cost.
create or replace function public.payments_redeem_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare s sales; ls loyalty_settings; v_pts int; v_bal int;
begin
  if new.method <> 'voucher' or coalesce(new.reference,'') not like 'points:%' then return new; end if;
  select * into s from sales where id = new.sale_id;
  if s.customer_id is null then raise exception 'Choose a customer to redeem points'; end if;
  select * into ls from loyalty_settings where tenant_id = s.tenant_id;
  if not found or not ls.enabled then raise exception 'Loyalty points are not turned on'; end if;
  v_pts := substr(new.reference, 8)::int;
  if v_pts <= 0 then raise exception 'Enter how many points to redeem'; end if;
  if v_pts < ls.min_redeem then raise exception 'Minimum redemption is % points', ls.min_redeem; end if;
  v_bal := points_balance(s.customer_id);
  if v_pts > v_bal then raise exception 'Customer has only % points', v_bal; end if;
  new.amount := round(v_pts * ls.redeem_value, 2);
  insert into loyalty_ledger (tenant_id, contact_id, kind, points, sale_id, note)
  values (s.tenant_id, s.customer_id, 'redeem', -v_pts, s.id, 'Redeemed on ' || s.receipt_no);
  -- the voucher payment is debited to clearing by post_sale; move it to reward expense
  perform post_entry(s.tenant_id, (s.sold_at at time zone 'UTC')::date, 'Points redeemed ' || s.receipt_no,
    'loyalty_redeem', s.id, jsonb_build_array(
      jsonb_build_object('code','6200','debit', new.amount),
      jsonb_build_object('code','1010','credit', new.amount)));
  return new;
end $$;
create trigger trg_payments_redeem before insert on public.payments
  for each row execute function public.payments_redeem_before();

-- Earn when a sale is finalised; take back earned and return redeemed points on void
create or replace function public.sales_loyalty_after()
returns trigger language plpgsql security definer set search_path = public as $$
declare ls loyalty_settings; v_base numeric; v_pts int;
begin
  if new.customer_id is null then return null; end if;
  if old.status = 'completed' and new.status = 'voided' then
    insert into loyalty_ledger (tenant_id, contact_id, kind, points, sale_id, note)
    select tenant_id, contact_id, 'reverse', -sum(points), sale_id, 'Sale ' || new.receipt_no || ' voided'
    from loyalty_ledger where sale_id = new.id and kind in ('earn','redeem')
    group by tenant_id, contact_id, sale_id having sum(points) <> 0;
    perform reverse_source(new.tenant_id, 'loyalty_redeem', new.id, 'loyalty_redeem_void', 'Void ' || new.receipt_no);
    return null;
  end if;
  if new.status = 'completed' and old.total = 0 and new.total > 0 then
    select * into ls from loyalty_settings where tenant_id = new.tenant_id;
    if not found or not ls.enabled then return null; end if;
    select new.total - coalesce(sum(amount),0) into v_base
      from payments where sale_id = new.id and method = 'voucher' and reference like 'points:%';
    v_pts := floor(greatest(v_base,0) * ls.points_per_unit);
    if v_pts > 0 then
      insert into loyalty_ledger (tenant_id, contact_id, kind, points, sale_id, note)
      values (new.tenant_id, new.customer_id, 'earn', v_pts, new.id, 'Sale ' || new.receipt_no);
    end if;
    update contacts set lifecycle = 'customer' where id = new.customer_id and lifecycle in ('lead','prospect');
    update contacts set score = score where id = new.customer_id;
  end if;
  return null;
end $$;
create trigger trg_sales_loyalty after update on public.sales
  for each row execute function public.sales_loyalty_after();

create or replace function public.adjust_points(p_contact uuid, p_points int, p_note text)
returns int language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  select tenant_id into t from contacts where id = p_contact;
  if not has_perm(t, 'crm.loyalty.manage') then raise exception 'Not allowed'; end if;
  if p_points = 0 then raise exception 'Enter a number of points'; end if;
  if points_balance(p_contact) + p_points < 0 then raise exception 'Balance cannot go below zero'; end if;
  insert into loyalty_ledger (tenant_id, contact_id, kind, points, note) values (t, p_contact, 'adjust', p_points, p_note);
  return points_balance(p_contact);
end $$;

-- ===== Customer 360 =====
create or replace view public.contact_stats with (security_invoker = true) as
select c.id as contact_id, c.tenant_id,
  (select count(*) from sales s where s.customer_id = c.id and s.status = 'completed') as orders,
  (select coalesce(sum(s.total),0) from sales s where s.customer_id = c.id and s.status = 'completed')
    + (select coalesce(sum(i.total),0) from invoices i where i.contact_id = c.id and i.status in ('issued','partial','paid')) as total_spend,
  greatest((select max(s.sold_at) from sales s where s.customer_id = c.id and s.status = 'completed'),
           (select max(i.issue_date)::timestamptz from invoices i where i.contact_id = c.id and i.status in ('issued','partial','paid'))) as last_purchase_at,
  (select coalesce(sum(i.total - i.amount_paid),0) from invoices i where i.contact_id = c.id and i.status in ('issued','partial')) as owed,
  (select coalesce(sum(points),0) from loyalty_ledger l where l.contact_id = c.id)::int as points,
  (select count(*) from deals d where d.contact_id = c.id and d.status = 'open') as open_deals,
  (select coalesce(sum(d.value),0) from deals d where d.contact_id = c.id and d.status = 'open') as open_deal_value
from contacts c;

-- ===== Segments =====
-- filter: {"lifecycle":["customer"],"tags_any":["vip"],"min_score":20,"min_spend":500,
--          "purchased_within_days":30,"not_purchased_days":60,"has_points":true,"birthday_this_month":true,
--          "channel":"whatsapp"|"email"}  (channel = only people who opted in on it)
create table public.segments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  filter jsonb not null default '{}',
  created_at timestamptz not null default now()
);

create or replace function public.segment_contacts(p_tenant uuid, p_filter jsonb)
returns setof uuid language sql stable security definer set search_path = public as $$
  select c.id from contacts c
  left join lateral (
    select coalesce(sum(s.total),0) spend, max(s.sold_at) last_at
    from sales s where s.customer_id = c.id and s.status = 'completed'
  ) st on true
  where c.tenant_id = p_tenant and is_member(p_tenant)
    and c.kind in ('customer','both')
    and (not (p_filter ? 'lifecycle') or c.lifecycle in (select jsonb_array_elements_text(p_filter->'lifecycle')))
    and (not (p_filter ? 'tags_any') or c.tags && array(select jsonb_array_elements_text(p_filter->'tags_any')))
    and (not (p_filter ? 'min_score') or c.score >= (p_filter->>'min_score')::int)
    and (not (p_filter ? 'min_spend') or st.spend >= (p_filter->>'min_spend')::numeric)
    and (not (p_filter ? 'purchased_within_days') or st.last_at > now() - ((p_filter->>'purchased_within_days') || ' days')::interval)
    and (not (p_filter ? 'not_purchased_days') or st.last_at is null or st.last_at < now() - ((p_filter->>'not_purchased_days') || ' days')::interval)
    and (not coalesce((p_filter->>'has_points')::boolean, false) or exists (select 1 from loyalty_ledger l where l.contact_id = c.id group by l.contact_id having sum(points) > 0))
    and (not coalesce((p_filter->>'birthday_this_month')::boolean, false) or extract(month from c.birthday) = extract(month from current_date))
    and (case p_filter->>'channel'
           when 'whatsapp' then c.whatsapp_opt_in and c.phone_norm is not null
           when 'email' then c.email_opt_in and c.email is not null
           else true end);
$$;

create or replace function public.segment_count(p_tenant uuid, p_filter jsonb)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from segment_contacts(p_tenant, p_filter);
$$;

-- ===== Campaigns =====
create table public.campaigns (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  channel text not null check (channel in ('whatsapp','email')),
  segment_filter jsonb not null default '{}',
  subject text,                                  -- email
  message text not null,                         -- supports {{name}} {{first_name}} {{points}} {{business}}
  wa_template_name text,                         -- WhatsApp approved template (required outside the 24h window)
  wa_template_lang text default 'en',
  status text not null default 'draft' check (status in ('draft','queued','sending','sent','cancelled')),
  queued_count int not null default 0,
  sent_count int not null default 0,
  failed_count int not null default 0,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  sent_at timestamptz
);

create table public.campaign_recipients (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  campaign_id uuid not null references public.campaigns(id) on delete cascade,
  contact_id uuid not null references public.contacts(id) on delete cascade,
  to_address text not null,
  status text not null default 'queued' check (status in ('queued','sent','failed','skipped')),
  error text,
  provider_id text,
  sent_at timestamptz,
  unique (campaign_id, contact_id)
);
create index on public.campaign_recipients (campaign_id, status);

-- Builds the audience (opted-in only) and queues it for the send-messages function
create or replace function public.queue_campaign(p_campaign uuid)
returns int language plpgsql security definer set search_path = public as $$
declare c campaigns; n int;
begin
  select * into c from campaigns where id = p_campaign for update;
  if not found then raise exception 'Unknown campaign'; end if;
  if not has_perm(c.tenant_id, 'crm.campaign.manage') then raise exception 'Not allowed'; end if;
  if c.status <> 'draft' then raise exception 'Campaign is already %', c.status; end if;
  insert into campaign_recipients (tenant_id, campaign_id, contact_id, to_address)
  select c.tenant_id, c.id, ct.id, case c.channel when 'whatsapp' then ct.phone_norm else ct.email end
  from contacts ct
  where ct.id in (select segment_contacts(c.tenant_id, c.segment_filter || jsonb_build_object('channel', c.channel)));
  get diagnostics n = row_count;
  if n = 0 then raise exception 'Nobody in this audience has opted in to %', c.channel; end if;
  update campaigns set status = 'queued', queued_count = n where id = c.id;
  return n;
end $$;

-- Called by the send-messages function (service role) after each send
create or replace function public.campaign_mark(p_recipient bigint, p_ok boolean, p_provider_id text, p_error text)
returns void language plpgsql security definer set search_path = public as $$
declare r campaign_recipients;
begin
  update campaign_recipients set status = case when p_ok then 'sent' else 'failed' end,
    provider_id = p_provider_id, error = p_error, sent_at = case when p_ok then now() end
  where id = p_recipient and status = 'queued' returning * into r;
  if not found then return; end if;
  update campaigns set
    sent_count = sent_count + case when p_ok then 1 else 0 end,
    failed_count = failed_count + case when p_ok then 0 else 1 end,
    status = case when not exists (select 1 from campaign_recipients where campaign_id = r.campaign_id and status = 'queued')
                  then 'sent' else 'sending' end,
    sent_at = case when not exists (select 1 from campaign_recipients where campaign_id = r.campaign_id and status = 'queued')
                   then now() else sent_at end
  where id = r.campaign_id;
  if p_ok then
    insert into activities (tenant_id, contact_id, kind, subject, created_by)
    select r.tenant_id, r.contact_id, c.channel, 'Campaign: ' || c.name, c.created_by
    from campaigns c where c.id = r.campaign_id;
  end if;
end $$;
-- only the send-messages function (service role) may mark sends
revoke execute on function public.campaign_mark(bigint, boolean, text, text) from public;
do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke execute on function public.campaign_mark(bigint, boolean, text, text) from anon, authenticated;
  end if;
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.campaign_mark(bigint, boolean, text, text) to service_role;
  end if;
end $$;

-- ===== Web lead forms =====
create table public.lead_forms (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  public_key text not null unique default encode(gen_random_bytes(12), 'hex'),
  create_deal boolean not null default true,
  deal_title text default 'Web enquiry',
  owner_id uuid references auth.users(id) on delete set null,
  tags text[] not null default '{}',
  consent_text text default 'I agree to be contacted about my enquiry and offers.',
  active boolean not null default true,
  submissions int not null default 0,
  created_at timestamptz not null default now()
);

create table public.lead_form_hits (
  form_id uuid not null references public.lead_forms(id) on delete cascade,
  at timestamptz not null default now()
);
create index on public.lead_form_hits (form_id, at);

-- Public endpoint (anon key): POST /rest/v1/rpc/submit_lead
-- p: {"name","phone","email","message","consent":true,"website":""}  — "website" is a honeypot
create or replace function public.submit_lead(p_key text, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare f lead_forms; cid uuid; v_phone text; v_country char(2); pid uuid; sid uuid; v_consent boolean;
begin
  select * into f from lead_forms where public_key = p_key and active;
  if not found then raise exception 'Form not found'; end if;
  if coalesce(p->>'website','') <> '' then return jsonb_build_object('ok', true); end if;   -- bot
  if (select count(*) from lead_form_hits where form_id = f.id and at > now() - interval '1 minute') >= 20 then
    raise exception 'Too many submissions, try again shortly';
  end if;
  insert into lead_form_hits (form_id) values (f.id);
  if coalesce(trim(p->>'name'),'') = '' or (coalesce(trim(p->>'phone'),'') = '' and coalesce(trim(p->>'email'),'') = '') then
    raise exception 'Please give your name and a phone number or email';
  end if;
  if length(coalesce(p->>'message','')) > 2000 or length(p->>'name') > 120 then raise exception 'Too long'; end if;

  select country_code into v_country from tenants where id = f.tenant_id;
  v_phone := normalize_phone(p->>'phone', v_country);
  v_consent := coalesce((p->>'consent')::boolean, false);

  select id into cid from contacts where tenant_id = f.tenant_id
    and ((v_phone is not null and phone_norm = v_phone) or (p->>'email' <> '' and lower(email) = lower(p->>'email')))
  limit 1;
  if cid is null then
    insert into contacts (tenant_id, kind, name, phone, email, lifecycle, source, owner_id, tags,
                          whatsapp_opt_in, email_opt_in, consent_source)
    values (f.tenant_id, 'customer', trim(p->>'name'), nullif(trim(p->>'phone'),''), nullif(trim(p->>'email'),''),
            'lead', 'web_form', f.owner_id, f.tags, v_consent and v_phone is not null,
            v_consent and coalesce(p->>'email','') <> '', case when v_consent then 'Web form: ' || f.name end)
    returning id into cid;
  elsif v_consent then
    update contacts set whatsapp_opt_in = whatsapp_opt_in or v_phone is not null,
                        email_opt_in = email_opt_in or coalesce(p->>'email','') <> '',
                        consent_source = coalesce(consent_source, 'Web form: ' || f.name)
    where id = cid;
  end if;

  insert into activities (tenant_id, contact_id, kind, subject, body, assigned_to)
  values (f.tenant_id, cid, 'note', 'Web form: ' || f.name, nullif(p->>'message',''), f.owner_id);
  insert into activities (tenant_id, contact_id, kind, subject, due_at, assigned_to)
  values (f.tenant_id, cid, 'task', 'Follow up web enquiry from ' || trim(p->>'name'), now() + interval '1 day', f.owner_id);

  if f.create_deal then
    perform ensure_crm_defaults(f.tenant_id);
    select id into pid from pipelines where tenant_id = f.tenant_id order by is_default desc limit 1;
    select id into sid from pipeline_stages where pipeline_id = pid order by sort_order limit 1;
    insert into deals (tenant_id, pipeline_id, stage_id, contact_id, title, owner_id, source)
    values (f.tenant_id, pid, sid, cid, coalesce(f.deal_title, 'Web enquiry') || ' — ' || trim(p->>'name'), f.owner_id, 'web_form');
  end if;

  update lead_forms set submissions = submissions + 1 where id = f.id;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.submit_lead(text, jsonb) to anon;

-- ===== RLS =====
alter table public.lead_score_rules enable row level security;
alter table public.pipelines enable row level security;
alter table public.pipeline_stages enable row level security;
alter table public.deals enable row level security;
alter table public.activities enable row level security;
alter table public.loyalty_settings enable row level security;
alter table public.loyalty_ledger enable row level security;
alter table public.segments enable row level security;
alter table public.campaigns enable row level security;
alter table public.campaign_recipients enable row level security;
alter table public.lead_forms enable row level security;
alter table public.lead_form_hits enable row level security;

-- contacts: cashiers may add (not edit) customers
drop policy contacts_write on public.contacts;
create policy contacts_insert on public.contacts for insert
  with check (has_perm(tenant_id, 'crm.contact.manage') or has_perm(tenant_id, 'crm.contact.create'));
create policy contacts_update on public.contacts for update
  using (has_perm(tenant_id, 'crm.contact.manage')) with check (has_perm(tenant_id, 'crm.contact.manage'));
create policy contacts_delete on public.contacts for delete using (has_perm(tenant_id, 'crm.contact.manage'));

create policy lsr_read on public.lead_score_rules for select using (has_perm(tenant_id, 'crm.contact.view'));
create policy lsr_write on public.lead_score_rules for all
  using (has_perm(tenant_id, 'crm.deal.manage')) with check (has_perm(tenant_id, 'crm.deal.manage'));

create policy pipelines_read on public.pipelines for select using (has_perm(tenant_id, 'crm.contact.view'));
create policy pipelines_write on public.pipelines for all
  using (has_perm(tenant_id, 'crm.deal.manage')) with check (has_perm(tenant_id, 'crm.deal.manage'));
create policy stages_read on public.pipeline_stages for select using (has_perm(tenant_id, 'crm.contact.view'));
create policy stages_write on public.pipeline_stages for all
  using (has_perm(tenant_id, 'crm.deal.manage')) with check (has_perm(tenant_id, 'crm.deal.manage'));
create policy deals_read on public.deals for select using (has_perm(tenant_id, 'crm.contact.view'));
create policy deals_write on public.deals for all
  using (has_perm(tenant_id, 'crm.deal.manage')) with check (has_perm(tenant_id, 'crm.deal.manage'));

create policy act_read on public.activities for select using (has_perm(tenant_id, 'crm.contact.view'));
create policy act_insert on public.activities for insert
  with check (has_perm(tenant_id, 'crm.contact.manage') and kind <> 'system');
create policy act_update on public.activities for update
  using (has_perm(tenant_id, 'crm.contact.manage') and kind <> 'system')
  with check (has_perm(tenant_id, 'crm.contact.manage') and kind <> 'system');
create policy act_delete on public.activities for delete
  using (kind <> 'system' and (created_by = auth.uid() or has_perm(tenant_id, 'crm.deal.manage')));

create policy loy_set_read on public.loyalty_settings for select using (is_member(tenant_id));
create policy loy_set_write on public.loyalty_settings for all
  using (has_perm(tenant_id, 'crm.loyalty.manage')) with check (has_perm(tenant_id, 'crm.loyalty.manage'));
create policy loy_ledger_read on public.loyalty_ledger for select using (has_perm(tenant_id, 'crm.contact.view'));

create policy seg_read on public.segments for select using (has_perm(tenant_id, 'crm.contact.view'));
create policy seg_write on public.segments for all
  using (has_perm(tenant_id, 'crm.campaign.manage')) with check (has_perm(tenant_id, 'crm.campaign.manage'));
create policy camp_read on public.campaigns for select using (has_perm(tenant_id, 'crm.campaign.manage'));
create policy camp_write on public.campaigns for all
  using (has_perm(tenant_id, 'crm.campaign.manage') and status = 'draft')
  with check (has_perm(tenant_id, 'crm.campaign.manage') and status = 'draft');
create policy campr_read on public.campaign_recipients for select using (has_perm(tenant_id, 'crm.campaign.manage'));

create policy forms_read on public.lead_forms for select using (has_perm(tenant_id, 'crm.form.manage'));
create policy forms_write on public.lead_forms for all
  using (has_perm(tenant_id, 'crm.form.manage')) with check (has_perm(tenant_id, 'crm.form.manage'));

do $$ declare t text; begin
  foreach t in array array['deals','loyalty_settings','campaigns','lead_forms','segments'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- Defaults for businesses created before this batch
select public.ensure_crm_defaults(id) from public.tenants;

-- New businesses get their chart of accounts, pipeline, scoring rules and loyalty settings straight away
create or replace function public.create_tenant(p_name text, p_template text default null, p_country char(2) default 'MY')
returns uuid language plpgsql security definer set search_path = public as $$
declare tid uuid; owner_role uuid;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  insert into tenants (name, industry_template, country_code) values (p_name, p_template, p_country) returning id into tid;
  insert into outlets (tenant_id, name, country_code) values (tid, 'Main', p_country);
  select id into owner_role from roles where tenant_id is null and name = 'Owner';
  insert into memberships (tenant_id, user_id, role_id) values (tid, auth.uid(), owner_role);
  insert into tenant_modules (tenant_id, module)
  select tid, m from unnest(coalesce(
    (select array(select jsonb_array_elements_text(bundle->'modules')) from templates where code = p_template),
    array['POS','INV'])) m
  on conflict do nothing;
  perform ensure_chart(tid);
  perform ensure_crm_defaults(tid);
  return tid;
end $$;

