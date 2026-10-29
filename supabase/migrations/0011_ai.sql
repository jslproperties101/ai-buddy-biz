-- Ai buddy Biz — Batch J: AI agents across modules (module AI)
-- A business assistant that reads your own numbers (only what the user's role may see), a daily briefing,
-- and agents that PROPOSE actions — draft purchase orders, follow-up messages, tasks, price changes.
-- Nothing is done until a person with the right permission approves it.
-- Depends on 0001–0010.

insert into public.permissions (code, module, description) values
  ('ai.use','AI','Ask the AI business assistant and see its suggestions'),
  ('ai.settings','AI','AI briefing and agent settings');

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r, unnest(array['ai.use','ai.settings']) c
where r.tenant_id is null and r.name in ('Owner','Admin') on conflict do nothing;
insert into public.role_permissions (role_id, permission_code)
select r.id, 'ai.use' from public.roles r
where r.tenant_id is null and r.name in ('Manager','Accountant','HR','Sales','Legal','Operations') on conflict do nothing;

-- ===== Settings & records =====
create table public.ai_settings (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  daily_briefing boolean not null default false,
  briefing_hour int not null default 8 check (briefing_hour between 0 and 23),
  email_briefing boolean not null default true,        -- email it to owners & admins
  agents jsonb not null default '{"reorder":true,"collections":true,"leads":true,"customers":true,"compliance":true,"pricing":false}',
  max_price_change_pct numeric(5,2) not null default 20,
  updated_at timestamptz not null default now()
);

create table public.ai_conversations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  title text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.ai_messages (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  conversation_id uuid not null references public.ai_conversations(id) on delete cascade,
  role text not null check (role in ('user','assistant')),
  content text not null,
  tools_used text[] not null default '{}',
  created_at timestamptz not null default now()
);
create index on public.ai_messages (conversation_id, id);

create table public.ai_suggestions (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  agent text not null check (agent in ('assistant','reorder','collections','leads','customers','compliance','pricing','briefing')),
  kind text not null check (kind in ('purchase_order','send_message','create_task','price_change','note')),
  title text not null,
  reason text,
  payload jsonb not null default '{}',
  status text not null default 'pending' check (status in ('pending','approved','rejected','failed','expired')),
  conversation_id uuid references public.ai_conversations(id) on delete set null,
  created_for uuid,                      -- the user who asked (assistant), null = for the business
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '7 days',
  decided_by uuid,
  decided_at timestamptz,
  result jsonb,
  error text
);
create index on public.ai_suggestions (tenant_id, status, created_at desc);

create table public.ai_briefings (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  for_date date not null,
  content jsonb not null,               -- {headline, sections:[{title, points[]}], watch[]}
  model text,
  created_at timestamptz not null default now(),
  unique (tenant_id, for_date)
);

-- ===== Access helper: signed-in users need the permission; the server (service key / cron) may read all =====
create or replace function public.ai_can(p_tenant uuid, p_perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is null or has_perm(p_tenant, p_perm);
$$;

create or replace function public.ai_local_today(p_tenant uuid)
returns date language sql stable as $$ select (now() at time zone tenant_tz(p_tenant))::date $$;

-- ===== Read tools (each returns JSON the assistant can read) =====
create or replace function public.ai_tool_sales(p_tenant uuid, p_from date default null, p_to date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare f date; t date; tz text := tenant_tz(p_tenant); days int; cur jsonb; prev jsonb;
begin
  if not (ai_can(p_tenant, 'pos.report.view') or ai_can(p_tenant, 'fin.report.view')) then return jsonb_build_object('error', 'not allowed'); end if;
  t := coalesce(p_to, ai_local_today(p_tenant));
  f := coalesce(p_from, t - 6);
  if t - f > 366 then f := t - 366; end if;
  days := t - f + 1;
  select jsonb_build_object('sales', count(*), 'revenue', coalesce(sum(total), 0), 'tax', coalesce(sum(tax_total), 0),
                            'avg_sale', round(coalesce(avg(total), 0), 2))
    into cur from sales where tenant_id = p_tenant and status = 'completed' and (sold_at at time zone tz)::date between f and t;
  select jsonb_build_object('sales', count(*), 'revenue', coalesce(sum(total), 0))
    into prev from sales where tenant_id = p_tenant and status = 'completed' and (sold_at at time zone tz)::date between f - days and f - 1;
  return jsonb_build_object(
    'period', jsonb_build_object('from', f, 'to', t, 'days', days), 'currency', (select base_currency from tenants where id = p_tenant),
    'totals', cur, 'previous_period', prev,
    'by_day', (select coalesce(jsonb_agg(x order by x->>'day'), '[]') from (
                 select jsonb_build_object('day', (sold_at at time zone tz)::date, 'revenue', sum(total), 'sales', count(*)) x
                 from sales where tenant_id = p_tenant and status = 'completed' and (sold_at at time zone tz)::date between f and t
                 group by (sold_at at time zone tz)::date) d),
    'top_products', (select coalesce(jsonb_agg(x), '[]') from (
                 select jsonb_build_object('name', sl.name, 'qty', sum(sl.qty), 'revenue', sum(sl.line_total)) x
                 from sale_lines sl join sales s on s.id = sl.sale_id
                 where s.tenant_id = p_tenant and s.status = 'completed' and (s.sold_at at time zone tz)::date between f and t
                 group by sl.name order by sum(sl.line_total) desc limit 10) d),
    'by_outlet', (select coalesce(jsonb_agg(x), '[]') from (
                 select jsonb_build_object('outlet', o.name, 'revenue', sum(s.total)) x
                 from sales s join outlets o on o.id = s.outlet_id
                 where s.tenant_id = p_tenant and s.status = 'completed' and (s.sold_at at time zone tz)::date between f and t
                 group by o.name order by sum(s.total) desc) d),
    'by_payment', (select coalesce(jsonb_agg(x), '[]') from (
                 select jsonb_build_object('method', p.method, 'amount', sum(p.amount)) x
                 from payments p join sales s on s.id = p.sale_id
                 where s.tenant_id = p_tenant and s.status = 'completed' and (s.sold_at at time zone tz)::date between f and t
                 group by p.method order by sum(p.amount) desc) d),
    'by_hour', (select coalesce(jsonb_agg(x order by (x->>'hour')::int), '[]') from (
                 select jsonb_build_object('hour', extract(hour from s.sold_at at time zone tz)::int, 'revenue', sum(s.total)) x
                 from sales s where s.tenant_id = p_tenant and s.status = 'completed' and (s.sold_at at time zone tz)::date between f and t
                 group by extract(hour from s.sold_at at time zone tz)::int) d));
end $$;

-- Low stock with sales speed and a suggested order (cover p_days days of sales at the recent rate)
create or replace function public.ai_tool_stock(p_tenant uuid, p_days int default 14)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not ai_can(p_tenant, 'inv.product.view') then return jsonb_build_object('error', 'not allowed'); end if;
  return jsonb_build_object('cover_days', p_days, 'items', (select coalesce(jsonb_agg(x order by (x->>'days_left')::numeric nulls last), '[]') from (
    select jsonb_build_object(
      'variant_id', v.id, 'sku', v.sku, 'name', p.name || coalesce(' — ' || v.name, ''), 'outlet_id', sl.outlet_id, 'outlet', o.name,
      'on_hand', sl.qty, 'reorder_point', sl.reorder_point,
      'sold_per_day', round(coalesce(r.sold, 0) / 28.0, 2),
      'days_left', case when coalesce(r.sold, 0) > 0 then round(sl.qty / (r.sold / 28.0), 1) end,
      'suggested_qty', greatest(0, ceil(coalesce(r.sold, 0) / 28.0 * p_days + coalesce(sl.reorder_point, 0) - sl.qty)),
      'last_supplier_id', lp.supplier_id, 'last_supplier', lp.supplier, 'last_cost', coalesce(lp.unit_cost, v.cost),
      'lead_time_days', lp.lead_time_days) x
    from stock_levels sl
    join product_variants v on v.id = sl.variant_id and v.active and v.track_stock
    join products p on p.id = v.product_id and p.active
    join outlets o on o.id = sl.outlet_id
    left join lateral (select -sum(m.qty_change) sold from stock_movements m
                       where m.variant_id = v.id and m.outlet_id = sl.outlet_id and m.reason = 'sale' and m.at > now() - interval '28 days') r on true
    left join lateral (select po.supplier_id, su.name supplier, l.unit_cost, su.lead_time_days from purchase_order_lines l
                       join purchase_orders po on po.id = l.po_id join suppliers su on su.id = po.supplier_id
                       where l.variant_id = v.id and po.status <> 'cancelled' order by po.created_at desc limit 1) lp on true
    where sl.tenant_id = p_tenant
      and ((sl.reorder_point is not null and sl.qty <= sl.reorder_point)
           or (coalesce(r.sold, 0) > 0 and sl.qty / (r.sold / 28.0) < greatest(p_days, coalesce(lp.lead_time_days, 0) + 3)))
    limit 60) d));
end $$;

create or replace function public.ai_tool_receivables(p_tenant uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := ai_local_today(p_tenant);
begin
  if not ai_can(p_tenant, 'fin.invoice.view') then return jsonb_build_object('error', 'not allowed'); end if;
  return jsonb_build_object(
    'total_outstanding', (select coalesce(sum(total - amount_paid), 0) from invoices where tenant_id = p_tenant and status in ('issued','partial')),
    'total_overdue', (select coalesce(sum(total - amount_paid), 0) from invoices where tenant_id = p_tenant and status in ('issued','partial') and due_date < today),
    'overdue', (select coalesce(jsonb_agg(x order by (x->>'days_overdue')::int desc), '[]') from (
      select jsonb_build_object('invoice_id', i.id, 'number', i.number, 'contact_id', i.contact_id, 'customer', c.name,
        'has_email', c.email is not null, 'has_phone', c.phone is not null,
        'balance', i.total - i.amount_paid, 'due_date', i.due_date, 'days_overdue', today - i.due_date,
        'last_reminder', (select max(m.created_at) from outbound_messages m where m.tenant_id = p_tenant and m.contact_id = i.contact_id
                          and m.subject ilike '%' || i.number || '%')) x
      from invoices i left join contacts c on c.id = i.contact_id
      where i.tenant_id = p_tenant and i.status in ('issued','partial') and i.due_date < today
      order by today - i.due_date desc limit 40) d));
end $$;

create or replace function public.ai_tool_pipeline(p_tenant uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not ai_can(p_tenant, 'crm.deal.view') then return jsonb_build_object('error', 'not allowed'); end if;
  return jsonb_build_object(
    'by_stage', (select coalesce(jsonb_agg(x), '[]') from (
      select jsonb_build_object('stage', st.name, 'deals', count(d.id), 'value', coalesce(sum(d.value), 0)) x
      from pipeline_stages st join pipelines p on p.id = st.pipeline_id
      left join deals d on d.stage_id = st.id and d.status = 'open'
      where p.tenant_id = p_tenant group by st.name, st.sort_order order by st.sort_order) s),
    'won_last_30_days', (select jsonb_build_object('deals', count(*), 'value', coalesce(sum(value), 0)) from deals
                         where tenant_id = p_tenant and status = 'won' and closed_at > now() - interval '30 days'),
    'stale_deals', (select coalesce(jsonb_agg(x), '[]') from (
      select jsonb_build_object('deal_id', d.id, 'title', d.title, 'contact_id', d.contact_id, 'contact', c.name, 'value', d.value,
        'score', d.score, 'stage', st.name,
        'days_since_activity', extract(day from now() - coalesce((select max(a.created_at) from activities a where a.deal_id = d.id), d.created_at))::int) x
      from deals d join pipeline_stages st on st.id = d.stage_id left join contacts c on c.id = d.contact_id
      where d.tenant_id = p_tenant and d.status = 'open'
        and coalesce((select max(a.created_at) from activities a where a.deal_id = d.id), d.created_at) < now() - interval '7 days'
      order by d.score desc, d.value desc limit 25) s),
    'overdue_tasks', (select count(*) from activities where tenant_id = p_tenant and kind in ('task','meeting') and done_at is null and due_at < now()));
end $$;

create or replace function public.ai_tool_customers(p_tenant uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not ai_can(p_tenant, 'crm.contact.view') then return jsonb_build_object('error', 'not allowed'); end if;
  return jsonb_build_object(
    'customers', (select count(*) from contacts where tenant_id = p_tenant and lifecycle = 'customer'),
    'new_last_30_days', (select count(*) from contacts where tenant_id = p_tenant and created_at > now() - interval '30 days'),
    'top_customers_90_days', (select coalesce(jsonb_agg(x), '[]') from (
      select jsonb_build_object('contact_id', c.id, 'name', c.name, 'spent', sum(s.total), 'visits', count(*)) x
      from sales s join contacts c on c.id = s.customer_id
      where s.tenant_id = p_tenant and s.status = 'completed' and s.sold_at > now() - interval '90 days'
      group by c.id, c.name order by sum(s.total) desc limit 10) d),
    'lapsed_regulars', (select coalesce(jsonb_agg(x), '[]') from (
      select jsonb_build_object('contact_id', c.id, 'name', c.name, 'visits', c.visits, 'total_spent', c.total_spent,
        'last_purchase', (c.last_purchase_at at time zone tenant_tz(p_tenant))::date, 'marketing_consent', c.marketing_consent) x
      from contacts c where c.tenant_id = p_tenant and c.visits >= 3 and c.last_purchase_at < now() - interval '45 days'
      order by c.total_spent desc limit 20) d),
    'birthdays_next_14_days', (select coalesce(jsonb_agg(jsonb_build_object('contact_id', c.id, 'name', c.name, 'birthday', to_char(c.birthday, 'DD Mon'),
        'marketing_consent', c.marketing_consent)), '[]')
      from contacts c where c.tenant_id = p_tenant and c.birthday is not null
        and to_char(c.birthday, 'MMDD') in (select to_char(d, 'MMDD') from generate_series(current_date, current_date + 14, interval '1 day') d)));
end $$;

create or replace function public.ai_tool_staff(p_tenant uuid, p_day date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_day, ai_local_today(p_tenant));
begin
  if not ai_can(p_tenant, 'hr.employee.view') then return jsonb_build_object('error', 'not allowed'); end if;
  return jsonb_build_object('day', d,
    'active_staff', (select count(*) from employees where tenant_id = p_tenant and status = 'active'),
    'clocked_in', (select count(*) from attendance where tenant_id = p_tenant and work_date = d and clock_in is not null),
    'late', (select coalesce(jsonb_agg(jsonb_build_object('name', e.full_name, 'minutes_late', a.late_minutes)), '[]')
             from attendance a join employees e on e.id = a.employee_id where a.tenant_id = p_tenant and a.work_date = d and a.late_minutes > 0),
    'on_leave', (select coalesce(jsonb_agg(jsonb_build_object('name', e.full_name, 'type', lt.name)), '[]')
                 from leave_requests lr join employees e on e.id = lr.employee_id join leave_types lt on lt.id = lr.leave_type_id
                 where lr.tenant_id = p_tenant and lr.status = 'approved' and d between lr.start_date and lr.end_date),
    'pending_leave', (select count(*) from leave_requests where tenant_id = p_tenant and status = 'pending'),
    'pending_claims', (select count(*) from claims where tenant_id = p_tenant and status = 'pending'));
end $$;

create or replace function public.ai_tool_operations(p_tenant uuid, p_day date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d date := coalesce(p_day, ai_local_today(p_tenant)); tz text := tenant_tz(p_tenant); out jsonb := '{}';
begin
  if ai_can(p_tenant, 'ord.view') then
    out := out || jsonb_build_object('orders', jsonb_build_object(
      'by_channel', (select coalesce(jsonb_object_agg(channel, n), '{}') from (select channel, count(*) n from orders
                     where tenant_id = p_tenant and (created_at at time zone tz)::date = d and status <> 'cancelled' group by channel) x),
      'cancelled', (select count(*) from orders where tenant_id = p_tenant and (created_at at time zone tz)::date = d and status = 'cancelled'),
      'open_now', (select count(*) from orders where tenant_id = p_tenant and status in ('pending','open','ready','out_for_delivery')),
      'avg_kitchen_minutes', (select round(avg(extract(epoch from ready_at - sent_at) / 60)::numeric, 1) from order_items
                              where tenant_id = p_tenant and ready_at is not null and (sent_at at time zone tz)::date = d),
      'sold_out_items', (select coalesce(jsonb_agg(name), '[]') from products where tenant_id = p_tenant and sold_out)));
  end if;
  if ai_can(p_tenant, 'book.view') then
    out := out || jsonb_build_object('bookings', jsonb_build_object(
      'today', (select count(*) from bookings where tenant_id = p_tenant and (start_at at time zone tz)::date = d and status <> 'cancelled'),
      'no_shows_last_30_days', (select count(*) from bookings where tenant_id = p_tenant and status = 'no_show' and start_at > now() - interval '30 days')));
  end if;
  if ai_can(p_tenant, 'log.shipment.view') then
    out := out || jsonb_build_object('shipments', (select coalesce(jsonb_object_agg(status, n), '{}') from (
      select status, count(*) n from shipments where tenant_id = p_tenant and status not in ('delivered','cancelled','closed') group by status) x));
  end if;
  if ai_can(p_tenant, 'kids.view') then
    out := out || jsonb_build_object('kids', jsonb_build_object(
      'enrolled', (select count(*) from children where tenant_id = p_tenant and status = 'enrolled'),
      'attended_today', (select count(*) from kids_attendance where tenant_id = p_tenant and day = d and check_in_at is not null),
      'incidents_unacknowledged', (select count(*) from kids_incidents where tenant_id = p_tenant and kind <> 'safeguarding'
                                   and parent_notified_at is not null and guardian_ack_at is null),
      'late_pickups_last_30_days', (select count(*) from kids_attendance where tenant_id = p_tenant and late_minutes > 0 and day > d - 30)));
  end if;
  return out;
end $$;

create or replace function public.ai_tool_compliance(p_tenant uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := ai_local_today(p_tenant);
begin
  if not ai_can(p_tenant, 'law.view') then return jsonb_build_object('error', 'not allowed'); end if;
  return jsonb_build_object(
    'overdue', (select coalesce(jsonb_agg(jsonb_build_object('title', title, 'due', due_date, 'kind', source) order by due_date), '[]')
                from legal_calendar where tenant_id = p_tenant and status = 'open' and due_date < today),
    'next_30_days', (select coalesce(jsonb_agg(jsonb_build_object('title', title, 'due', due_date, 'kind', source) order by due_date), '[]')
                     from legal_calendar where tenant_id = p_tenant and status = 'open' and due_date between today and today + 30),
    'needs_a_date', (select count(*) from compliance_items where tenant_id = p_tenant and status = 'open' and due_date is null),
    'contracts_awaiting_signature', (select count(*) from contracts where tenant_id = p_tenant and status in ('out_for_signature','partially_signed')));
end $$;

-- Search the catalog / contacts / suppliers by name (so the assistant can find ids for proposals)
create or replace function public.ai_tool_find(p_tenant uuid, p_kind text, p_query text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q text := '%' || replace(replace(coalesce(p_query, ''), '%', ''), '_', '') || '%';
begin
  if p_kind = 'product' and ai_can(p_tenant, 'inv.product.view') then
    return (select coalesce(jsonb_agg(jsonb_build_object('variant_id', v.id, 'sku', v.sku, 'name', p.name || coalesce(' — ' || v.name, ''),
              'price', v.price, 'cost', v.cost)), '[]')
            from product_variants v join products p on p.id = v.product_id
            where v.tenant_id = p_tenant and v.active and (p.name ilike q or v.sku ilike q or v.name ilike q) limit 15);
  elsif p_kind = 'contact' and ai_can(p_tenant, 'crm.contact.view') then
    return (select coalesce(jsonb_agg(jsonb_build_object('contact_id', id, 'name', name, 'company', company, 'lifecycle', lifecycle,
              'has_email', email is not null, 'has_phone', phone is not null, 'marketing_consent', marketing_consent)), '[]')
            from contacts where tenant_id = p_tenant and (name ilike q or company ilike q) limit 15);
  elsif p_kind = 'supplier' and ai_can(p_tenant, 'inv.supplier.manage') then
    return (select coalesce(jsonb_agg(jsonb_build_object('supplier_id', id, 'name', name, 'lead_time_days', lead_time_days)), '[]')
            from suppliers where tenant_id = p_tenant and name ilike q limit 15);
  end if;
  return jsonb_build_object('error', 'not allowed or unknown kind');
end $$;

-- Everything the user may see, for the briefing
create or replace function public.ai_overview(p_tenant uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare o jsonb; t tenants;
begin
  if not (auth.uid() is null or is_member(p_tenant)) then raise exception 'Not allowed'; end if;
  select * into t from tenants where id = p_tenant;
  o := jsonb_build_object('business', t.name, 'country', t.country_code, 'currency', t.base_currency, 'today', ai_local_today(p_tenant),
                          'modules', (select coalesce(jsonb_agg(module), '[]') from tenant_modules where tenant_id = p_tenant and enabled));
  if ai_can(p_tenant, 'pos.report.view') or ai_can(p_tenant, 'fin.report.view') then
    o := o || jsonb_build_object('sales_yesterday', ai_tool_sales(p_tenant, ai_local_today(p_tenant) - 1, ai_local_today(p_tenant) - 1) - 'by_hour' - 'by_day',
                                 'sales_last_7_days', ai_tool_sales(p_tenant, ai_local_today(p_tenant) - 7, ai_local_today(p_tenant) - 1) - 'by_hour');
  end if;
  if ai_can(p_tenant, 'inv.product.view') then o := o || jsonb_build_object('stock', ai_tool_stock(p_tenant)); end if;
  if ai_can(p_tenant, 'fin.invoice.view') then o := o || jsonb_build_object('receivables', ai_tool_receivables(p_tenant)); end if;
  if ai_can(p_tenant, 'crm.deal.view') then o := o || jsonb_build_object('pipeline', ai_tool_pipeline(p_tenant)); end if;
  if ai_can(p_tenant, 'crm.contact.view') then o := o || jsonb_build_object('customers', ai_tool_customers(p_tenant)); end if;
  if ai_can(p_tenant, 'hr.employee.view') then o := o || jsonb_build_object('staff', ai_tool_staff(p_tenant)); end if;
  if ai_can(p_tenant, 'law.view') then o := o || jsonb_build_object('compliance', ai_tool_compliance(p_tenant)); end if;
  o := o || jsonb_build_object('operations', ai_tool_operations(p_tenant));
  return o;
end $$;

-- ===== Proposals and approvals =====
create or replace function public.ai_propose(p_tenant uuid, p_agent text, p_kind text, p_title text, p_reason text, p_payload jsonb,
                                             p_conversation uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare sid uuid; n int;
begin
  if not ai_can(p_tenant, 'ai.use') then raise exception 'Not allowed'; end if;
  if p_kind not in ('purchase_order','send_message','create_task','price_change','note') then raise exception 'Unknown action'; end if;
  select count(*) into n from ai_suggestions where tenant_id = p_tenant and status = 'pending';
  if n >= 200 then raise exception 'Too many suggestions waiting — review some first'; end if;
  -- avoid duplicates of the same pending idea
  select id into sid from ai_suggestions where tenant_id = p_tenant and status = 'pending' and kind = p_kind and payload = p_payload;
  if sid is not null then return sid; end if;
  insert into ai_suggestions (tenant_id, agent, kind, title, reason, payload, conversation_id, created_for)
  values (p_tenant, p_agent, p_kind, left(p_title, 200), left(p_reason, 2000), coalesce(p_payload, '{}'), p_conversation, auth.uid())
  returning id into sid;
  return sid;
end $$;

-- A person approves (optionally with edits) or rejects. Approval runs with THEIR permissions.
create or replace function public.ai_decide(p_suggestion uuid, p_approve boolean, p_edits jsonb default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare sg ai_suggestions; p jsonb; res jsonb; po_id uuid; l jsonb; c contacts; v product_variants; ch text; addr text;
        st ai_settings; pct numeric; n int := 0; due timestamptz;
begin
  select * into sg from ai_suggestions where id = p_suggestion for update;
  if not found or not has_perm(sg.tenant_id, 'ai.use') then raise exception 'Not allowed'; end if;
  if sg.status <> 'pending' then raise exception 'Already %', sg.status; end if;
  if sg.expires_at < now() then
    update ai_suggestions set status = 'expired' where id = sg.id;
    raise exception 'This suggestion has expired';
  end if;
  if not p_approve then
    update ai_suggestions set status = 'rejected', decided_by = auth.uid(), decided_at = now() where id = sg.id;
    return jsonb_build_object('status', 'rejected');
  end if;
  p := sg.payload || coalesce(p_edits, '{}');

  if sg.kind = 'purchase_order' then
    if not has_perm(sg.tenant_id, 'inv.supplier.manage') then raise exception 'You need purchasing rights to approve this'; end if;
    if not exists (select 1 from suppliers where id = (p->>'supplier_id')::uuid and tenant_id = sg.tenant_id) then raise exception 'Choose a supplier'; end if;
    if not exists (select 1 from outlets where id = (p->>'outlet_id')::uuid and tenant_id = sg.tenant_id) then raise exception 'Choose an outlet'; end if;
    insert into purchase_orders (tenant_id, supplier_id, outlet_id, notes, currency)
    values (sg.tenant_id, (p->>'supplier_id')::uuid, (p->>'outlet_id')::uuid, 'Suggested by AI: ' || sg.title,
            (select base_currency from tenants where id = sg.tenant_id))
    returning id into po_id;
    for l in select * from jsonb_array_elements(coalesce(p->'lines', '[]')) loop
      select * into v from product_variants where id = (l->>'variant_id')::uuid and tenant_id = sg.tenant_id;
      if not found or coalesce((l->>'qty')::numeric, 0) <= 0 then continue; end if;
      insert into purchase_order_lines (tenant_id, po_id, variant_id, qty_ordered, unit_cost)
      values (sg.tenant_id, po_id, v.id, (l->>'qty')::numeric, coalesce((l->>'unit_cost')::numeric, v.cost));
      n := n + 1;
    end loop;
    if n = 0 then raise exception 'No valid lines to order'; end if;
    res := jsonb_build_object('purchase_order_id', po_id, 'number', (select number from purchase_orders where id = po_id), 'lines', n);

  elsif sg.kind = 'send_message' then
    if not (has_perm(sg.tenant_id, 'crm.contact.manage') or has_perm(sg.tenant_id, 'fin.invoice.manage')) then
      raise exception 'You need customer or invoicing rights to approve this';
    end if;
    -- the address always comes from the contact record, never from the AI
    select * into c from contacts where id = (p->>'contact_id')::uuid and tenant_id = sg.tenant_id;
    if not found then raise exception 'Unknown customer'; end if;
    if coalesce(p->>'purpose', 'service') = 'marketing' and not c.marketing_consent then
      raise exception '% has not agreed to marketing messages', c.name;
    end if;
    ch := case when p->>'channel' in ('email','whatsapp','sms') then p->>'channel' when c.email is not null then 'email' else 'whatsapp' end;
    addr := case ch when 'email' then lower(c.email) else norm_phone(c.phone) end;
    if addr is null then raise exception '% has no % on file', c.name, case ch when 'email' then 'email' else 'phone' end; end if;
    if coalesce(length(trim(p->>'body')), 0) < 5 then raise exception 'The message is empty'; end if;
    insert into outbound_messages (tenant_id, contact_id, channel, to_address, subject, body)
    values (sg.tenant_id, c.id, ch, addr, left(p->>'subject', 200), left(p->>'body', 2000));
    insert into activities (tenant_id, contact_id, kind, body, created_by)
    values (sg.tenant_id, c.id, case ch when 'email' then 'email' else 'whatsapp' end, 'Sent (AI draft approved): ' || left(p->>'body', 500), auth.uid());
    res := jsonb_build_object('queued_to', c.name, 'channel', ch);

  elsif sg.kind = 'create_task' then
    if not (has_perm(sg.tenant_id, 'crm.deal.manage') or has_perm(sg.tenant_id, 'crm.contact.manage')) then raise exception 'Not allowed'; end if;
    if p->>'contact_id' is null and p->>'deal_id' is null then raise exception 'A task needs a customer or deal'; end if;
    if p->>'contact_id' is not null and not exists (select 1 from contacts where id = (p->>'contact_id')::uuid and tenant_id = sg.tenant_id) then
      raise exception 'Unknown customer';
    end if;
    if p->>'deal_id' is not null and not exists (select 1 from deals where id = (p->>'deal_id')::uuid and tenant_id = sg.tenant_id) then
      raise exception 'Unknown deal';
    end if;
    due := coalesce((p->>'due_at')::timestamptz, now() + interval '1 day');
    insert into activities (tenant_id, contact_id, deal_id, kind, body, due_at, owner_id, created_by)
    values (sg.tenant_id, (p->>'contact_id')::uuid, (p->>'deal_id')::uuid, 'task', left(coalesce(p->>'body', sg.title), 1000), due, auth.uid(), auth.uid());
    res := jsonb_build_object('task_due', due);

  elsif sg.kind = 'price_change' then
    if not has_perm(sg.tenant_id, 'inv.product.manage') then raise exception 'You need product rights to approve this'; end if;
    select * into v from product_variants where id = (p->>'variant_id')::uuid and tenant_id = sg.tenant_id;
    if not found then raise exception 'Unknown product'; end if;
    select * into st from ai_settings where tenant_id = sg.tenant_id;
    if (p->>'new_price')::numeric is null or (p->>'new_price')::numeric < 0 then raise exception 'Invalid price'; end if;
    pct := case when v.price > 0 then abs((p->>'new_price')::numeric - v.price) / v.price * 100 else 100 end;
    if pct > coalesce(st.max_price_change_pct, 20) then
      raise exception 'Change of % %% is above your limit of % %% — edit the price or change it in Catalog', round(pct, 1), coalesce(st.max_price_change_pct, 20);
    end if;
    update product_variants set price = (p->>'new_price')::numeric where id = v.id;
    res := jsonb_build_object('variant_id', v.id, 'old_price', v.price, 'new_price', (p->>'new_price')::numeric);

  else
    res := jsonb_build_object('noted', true);
  end if;

  update ai_suggestions set status = 'approved', decided_by = auth.uid(), decided_at = now(), result = res,
    payload = p where id = sg.id;
  update ai_usage set confirmed = true where tenant_id = sg.tenant_id and proposed_action->>'suggestion_id' = sg.id::text;
  return jsonb_build_object('status', 'approved', 'result', res);
end $$;

-- Called by the ai-agent function to record a conversation turn and usage
create or replace function public.ai_record(p_tenant uuid, p_conversation uuid, p_user_text text, p_reply text, p_tools text[],
                                            p_feature text, p_model text, p_in int, p_out int, p_cost numeric)
returns uuid language plpgsql security definer set search_path = public as $$
declare cid uuid := p_conversation;
begin
  if not ai_can(p_tenant, 'ai.use') then raise exception 'Not allowed'; end if;
  if p_user_text is not null then
    if cid is null or not exists (select 1 from ai_conversations where id = cid and tenant_id = p_tenant and user_id = auth.uid()) then
      insert into ai_conversations (tenant_id, user_id, title) values (p_tenant, auth.uid(), left(p_user_text, 80)) returning id into cid;
    end if;
    insert into ai_messages (tenant_id, conversation_id, role, content) values (p_tenant, cid, 'user', left(p_user_text, 8000));
    insert into ai_messages (tenant_id, conversation_id, role, content, tools_used) values (p_tenant, cid, 'assistant', left(p_reply, 20000), coalesce(p_tools, '{}'));
    update ai_conversations set updated_at = now() where id = cid;
  end if;
  insert into ai_usage (tenant_id, user_id, feature, input_tokens, output_tokens, cost_usd)
  values (p_tenant, auth.uid(), p_feature, p_in, p_out, p_cost);
  return cid;
end $$;

create or replace function public.ai_check_quota(p_tenant uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare q jsonb;
begin
  if not ai_can(p_tenant, 'ai.use') then raise exception 'Not allowed to use the AI assistant'; end if;
  q := (select jsonb_build_object(
          'used', (select count(*) from ai_usage where tenant_id = p_tenant and at >= date_trunc('month', now())),
          'limit', (select monthly_requests from ai_plan_limits where plan = t.plan), 'plan', t.plan,
          'business', t.name, 'country', t.country_code, 'currency', t.base_currency,
          'today', ai_local_today(p_tenant), 'timezone', tenant_tz(p_tenant),
          'role', (select r.name from memberships m join roles r on r.id = m.role_id where m.tenant_id = p_tenant and m.user_id = auth.uid()),
          'modules', (select coalesce(jsonb_agg(module), '[]') from tenant_modules where tenant_id = p_tenant and enabled))
        from tenants t where t.id = p_tenant);
  if (q->>'used')::int >= coalesce((q->>'limit')::int, 0) then
    raise exception 'Monthly AI limit reached (% of %). Upgrade your plan for more.', q->>'used', q->>'limit';
  end if;
  return q;
end $$;

create or replace function public.ai_save_briefing(p_tenant uuid, p_date date, p_content jsonb, p_model text)
returns uuid language plpgsql security definer set search_path = public as $$
declare bid uuid; st ai_settings; u record; biz text; txt text;
begin
  if not ai_can(p_tenant, 'ai.use') then raise exception 'Not allowed'; end if;
  insert into ai_briefings (tenant_id, for_date, content, model) values (p_tenant, p_date, p_content, p_model)
  on conflict (tenant_id, for_date) do update set content = excluded.content, model = excluded.model, created_at = now()
  returning id into bid;
  select * into st from ai_settings where tenant_id = p_tenant;
  if auth.uid() is null and coalesce(st.email_briefing, false) then        -- scheduled run: email owners & admins
    select name into biz from tenants where id = p_tenant;
    txt := coalesce(p_content->>'headline', '') || E'\n\n' || coalesce((select string_agg((s->>'title') || E':\n' ||
             (select string_agg('• ' || pt, E'\n') from jsonb_array_elements_text(s->'points') pt), E'\n\n')
             from jsonb_array_elements(coalesce(p_content->'sections', '[]')) s), '')
           || E'\n\nOpen the app to review the AI suggestions.';
    for u in select distinct lower(au.email) email from memberships m join roles r on r.id = m.role_id join auth.users au on au.id = m.user_id
             where m.tenant_id = p_tenant and m.active and r.name in ('Owner','Admin') and au.email is not null loop
      insert into outbound_messages (tenant_id, channel, to_address, subject, body)
      values (p_tenant, 'email', u.email, biz || ' — daily briefing ' || to_char(p_date, 'DD Mon'), left(txt, 8000));
    end loop;
  end if;
  return bid;
end $$;

-- Businesses whose daily briefing is due now (for the cron run)
create or replace function public.ai_briefings_due()
returns table (tenant_id uuid) language sql stable security definer set search_path = public as $$
  select s.tenant_id from ai_settings s join tenant_modules m on m.tenant_id = s.tenant_id and m.module = 'AI' and m.enabled
  where s.daily_briefing and auth.uid() is null
    and extract(hour from now() at time zone tenant_tz(s.tenant_id)) >= s.briefing_hour
    and not exists (select 1 from ai_briefings b where b.tenant_id = s.tenant_id and b.for_date = ai_local_today(s.tenant_id));
$$;

-- ===== RLS =====
alter table public.ai_settings enable row level security;
create policy ais_read on public.ai_settings for select using (has_perm(tenant_id, 'ai.use'));
create policy ais_write on public.ai_settings for all using (has_perm(tenant_id, 'ai.settings')) with check (has_perm(tenant_id, 'ai.settings'));

alter table public.ai_conversations enable row level security;
create policy aic_own on public.ai_conversations for select using (user_id = auth.uid() and has_perm(tenant_id, 'ai.use'));
create policy aic_del on public.ai_conversations for delete using (user_id = auth.uid());

alter table public.ai_messages enable row level security;
create policy aim_own on public.ai_messages for select using (exists (select 1 from ai_conversations c where c.id = conversation_id and c.user_id = auth.uid()));

alter table public.ai_suggestions enable row level security;
create policy aisg_read on public.ai_suggestions for select using (has_perm(tenant_id, 'ai.use') and (created_for is null or created_for = auth.uid()
  or has_perm(tenant_id, 'ai.settings')));

alter table public.ai_briefings enable row level security;
create policy aib_read on public.ai_briefings for select using (has_perm(tenant_id, 'ai.use'));

do $$ declare t text; begin
  foreach t in array array['ai_settings','ai_suggestions'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- New businesses with the AI module get settings
create or replace function public.ai_module_on()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.module = 'AI' and new.enabled then insert into ai_settings (tenant_id) values (new.tenant_id) on conflict do nothing; end if;
  return null;
end $$;
create trigger trg_ai_module_on after insert or update on public.tenant_modules for each row execute function public.ai_module_on();
insert into public.ai_settings (tenant_id) select tenant_id from public.tenant_modules where module = 'AI' and enabled on conflict do nothing;

-- The read tools work without a login for the server only: never for anonymous web visitors
do $$ declare f text; begin
  foreach f in array array['ai_can(uuid, text)','ai_tool_sales(uuid, date, date)','ai_tool_stock(uuid, integer)','ai_tool_receivables(uuid)',
    'ai_tool_pipeline(uuid)','ai_tool_customers(uuid)','ai_tool_staff(uuid, date)','ai_tool_operations(uuid, date)','ai_tool_compliance(uuid)',
    'ai_tool_find(uuid, text, text)','ai_overview(uuid)','ai_propose(uuid, text, text, text, text, jsonb, uuid)','ai_record(uuid, uuid, text, text, text[], text, text, integer, integer, numeric)',
    'ai_check_quota(uuid)','ai_save_briefing(uuid, date, jsonb, text)','ai_briefings_due()','ai_decide(uuid, boolean, jsonb)'] loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated, service_role', f);
  end loop;
end $$;
