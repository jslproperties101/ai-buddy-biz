-- GENERATED from supabase/migrations/0012_chatwoot.sql (schema biz). Paste in the SQL editor of the project where biz is installed.
-- Safe to run twice. Touches only the chatwoot_* tables and functions.
-- 0012: Chatwoot bridge, Phase 2 (customer inbox).
-- Used only by the chatwoot-bridge Edge Function, which connects with the service role. Nobody else can call these
-- functions or read these tables (row security on, no policies; execute granted to service_role only).
--  * chatwoot_accounts      which Chatwoot account belongs to which Biz business (tenant)
--  * chatwoot_events        one row per webhook delivery: stops double replies and lets a failed one be retried
--  * chatwoot_conversations remembers that a conversation already became a lead (one lead per conversation)
--  * chatwoot_claim_event / chatwoot_finish_event   the duplicate guard
--  * chatwoot_save_lead     saves the customer as a lead through the existing capture_lead rules
--  * chatwoot_find_products read-only product, price and "in stock" lookup for the AI draft (never cost, never counts)

create table if not exists biz.chatwoot_accounts (
  account_id bigint primary key,
  tenant_id uuid not null references biz.tenants(id) on delete cascade,
  created_at timestamptz not null default now()
);

create table if not exists biz.chatwoot_events (
  key text primary key,
  status text not null default 'processing' check (status in ('processing','done','failed')),
  attempts int not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists chatwoot_events_created on biz.chatwoot_events (created_at);

create table if not exists biz.chatwoot_conversations (
  account_id bigint not null,
  conversation_id bigint not null,
  lead_saved_at timestamptz,
  primary key (account_id, conversation_id)
);

alter table biz.chatwoot_accounts enable row level security;
alter table biz.chatwoot_events enable row level security;
alter table biz.chatwoot_conversations enable row level security;
revoke all on biz.chatwoot_accounts, biz.chatwoot_events, biz.chatwoot_conversations from anon, authenticated;

-- 'new' = first time, go ahead. 'retry' = an earlier try failed (or died half way), go ahead. 'duplicate' = skip.
create or replace function biz.chatwoot_claim_event(p_key text)
returns text language plpgsql security definer set search_path = biz, public as $$
declare n int;
begin
  if coalesce(p_key, '') = '' or length(p_key) > 200 then raise exception 'bad key'; end if;
  delete from chatwoot_events where created_at < now() - interval '14 days';
  insert into chatwoot_events (key) values (p_key) on conflict (key) do nothing;
  get diagnostics n = row_count;
  if n = 1 then return 'new'; end if;
  -- failed, or "processing" for over 2 minutes (the function died): take it over, at most 5 tries in all
  update chatwoot_events
     set status = 'processing', attempts = attempts + 1, updated_at = now()
   where key = p_key and attempts < 5
     and (status = 'failed' or (status = 'processing' and updated_at < now() - interval '2 minutes'));
  get diagnostics n = row_count;
  return case when n = 1 then 'retry' else 'duplicate' end;
end $$;

create or replace function biz.chatwoot_finish_event(p_key text, p_ok boolean)
returns void language sql security definer set search_path = biz, public as $$
  update chatwoot_events set status = case when p_ok then 'done' else 'failed' end, updated_at = now() where key = p_key;
$$;

-- p: { name, phone, email, message, interest }. Needs a name plus a phone or email; WhatsApp gives the phone.
create or replace function biz.chatwoot_save_lead(p_account bigint, p_conversation bigint, p jsonb)
returns jsonb language plpgsql security definer set search_path = biz, public as $$
declare t uuid; k text; done timestamptz;
begin
  select tenant_id into t from chatwoot_accounts where account_id = p_account;
  if t is null then return jsonb_build_object('saved', false, 'reason', 'account_not_linked'); end if;
  select lead_saved_at into done from chatwoot_conversations where account_id = p_account and conversation_id = p_conversation;
  if done is not null then return jsonb_build_object('saved', false, 'reason', 'already_saved'); end if;
  if coalesce(trim(p->>'name'), '') = '' or (coalesce(trim(p->>'phone'), '') = '' and coalesce(trim(p->>'email'), '') = '') then
    return jsonb_build_object('saved', false, 'reason', 'no_contact_details');
  end if;
  select settings->>'lead_form_key' into k from tenant_modules where tenant_id = t and module = 'CRM';
  if k is null or length(k) < 16 then return jsonb_build_object('saved', false, 'reason', 'no_lead_form_key'); end if;
  perform capture_lead(k, jsonb_build_object(
    'name', p->>'name', 'phone', p->>'phone', 'email', p->>'email',
    'message', p->>'message', 'interest', p->>'interest', 'source', 'chatwoot'));
  insert into chatwoot_conversations (account_id, conversation_id, lead_saved_at) values (p_account, p_conversation, now())
  on conflict (account_id, conversation_id) do update set lead_saved_at = excluded.lead_saved_at;
  return jsonb_build_object('saved', true);
end $$;

-- Up to 5 active products matching any word of the customer's message. Price and in-stock yes/no only.
create or replace function biz.chatwoot_find_products(p_account bigint, p_query text)
returns jsonb language plpgsql security definer set search_path = biz, public as $$
declare t uuid; words text[]; res jsonb; cur text;
begin
  select tenant_id into t from chatwoot_accounts where account_id = p_account;
  if t is null then return '[]'::jsonb; end if;
  select coalesce(array_agg(w), '{}') into words from (
    select distinct lower(regexp_replace(x, '[%_\\]', '', 'g')) w
    from regexp_split_to_table(left(coalesce(p_query, ''), 200), '[^[:alnum:]]+') x
    where length(x) >= 3 limit 6) q where w <> '';
  if cardinality(words) = 0 then return '[]'::jsonb; end if;
  select base_currency into cur from tenants where id = t;
  select coalesce(jsonb_agg(row_to_json(r)::jsonb), '[]'::jsonb) into res from (
    select p.name, left(coalesce(p.description, ''), 300) as description, cur as currency,
      (select coalesce(jsonb_agg(jsonb_build_object(
          'name', v.name, 'sku', v.sku, 'price', v.price,
          'in_stock', case when v.track_stock then coalesce((select sum(s.qty) from stock_levels s where s.variant_id = v.id), 0) > 0 else true end)
          order by v.sku), '[]'::jsonb)
        from product_variants v where v.product_id = p.id and v.active and v.tenant_id = t) as variants
    from products p
    where p.tenant_id = t and p.active
      and exists (select 1 from unnest(words) w where lower(p.name) like '%' || w || '%' or lower(coalesce(p.description, '')) like '%' || w || '%')
    order by (select count(*) from unnest(words) w where lower(p.name) like '%' || w || '%') desc, p.name
    limit 5) r;
  return res;
end $$;

revoke execute on function biz.chatwoot_claim_event(text), biz.chatwoot_finish_event(text, boolean),
  biz.chatwoot_save_lead(bigint, bigint, jsonb), biz.chatwoot_find_products(bigint, text) from public, anon, authenticated;
grant execute on function biz.chatwoot_claim_event(text), biz.chatwoot_finish_event(text, boolean),
  biz.chatwoot_save_lead(bigint, bigint, jsonb), biz.chatwoot_find_products(bigint, text) to service_role;
