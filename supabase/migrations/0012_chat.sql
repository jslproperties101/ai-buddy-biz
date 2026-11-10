-- Ai buddy Biz — Chatwoot customer inbox bridge, Phase 2: Claude auto-reply and lead capture
-- Tables and functions used by the chatwoot-bridge Edge Function. Depends on 0001–0011.
-- All functions here are for the service role (the bridge) only; app users never call them.
-- NOT applied anywhere yet. Review first; on the EAB-QA-Test project use the generated incremental file in
-- supabase/eab-qa-test/ (schema biz).

-- ===== Which Chatwoot account belongs to which business =====
create table public.chat_accounts (
  chatwoot_account_id int primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  bot_enabled boolean not null default true,        -- master switch for automatic replies
  max_bot_replies int not null default 6 check (max_bot_replies between 0 and 50),  -- per conversation, then a person takes over
  created_at timestamptz not null default now()
);
create index on public.chat_accounts (tenant_id);

-- ===== One row per Chatwoot conversation the bridge has seen =====
create table public.chat_conversations (
  chatwoot_account_id int not null references public.chat_accounts(chatwoot_account_id) on delete cascade,
  chatwoot_conversation_id int not null,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  contact_id uuid references public.contacts(id) on delete set null,
  deal_id uuid references public.deals(id) on delete set null,
  bot_replies int not null default 0,
  handed_over boolean not null default false,       -- once true the bot never replies in this conversation again
  handover_reason text,
  language text,
  last_summary text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (chatwoot_account_id, chatwoot_conversation_id)
);
create index on public.chat_conversations (tenant_id, updated_at desc);
create index on public.chat_conversations (deal_id);

-- ===== Webhook de-duplication (survives restarts and several running copies of the function) =====
create table public.chat_events (
  dedupe_key text primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  at timestamptz not null default now()
);
create index on public.chat_events (at);

alter table public.chat_accounts enable row level security;
alter table public.chat_conversations enable row level security;
alter table public.chat_events enable row level security;      -- no policies: only the service role touches it

create policy chat_accounts_read on public.chat_accounts for select using (has_perm(tenant_id, 'crm.settings.manage'));
create policy chat_accounts_write on public.chat_accounts for all
  using (has_perm(tenant_id, 'crm.settings.manage')) with check (has_perm(tenant_id, 'crm.settings.manage'));
create policy chat_conversations_read on public.chat_conversations for select using (has_perm(tenant_id, 'crm.deal.view'));

-- ===== Bridge functions (service role only) =====

-- First call for every webhook: find the business, and claim the event so the same delivery is handled only once.
create or replace function public.chat_claim_event(p_account int, p_key text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare a chat_accounts;
begin
  select * into a from chat_accounts where chatwoot_account_id = p_account;
  if not found then return jsonb_build_object('ok', false, 'reason', 'unknown_account'); end if;
  insert into chat_events (dedupe_key, tenant_id) values (left(p_key, 200), a.tenant_id) on conflict do nothing;
  if not found then return jsonb_build_object('ok', false, 'reason', 'duplicate'); end if;
  delete from chat_events where at < now() - interval '7 days';
  return jsonb_build_object('ok', true, 'tenant_id', a.tenant_id, 'bot_enabled', a.bot_enabled, 'max_bot_replies', a.max_bot_replies);
end $$;

-- A failed reply must not block Chatwoot's retry.
create or replace function public.chat_release_event(p_key text)
returns void language sql security definer set search_path = public as $$
  delete from chat_events where dedupe_key = left(p_key, 200);
$$;

-- Business facts for the prompt, plus this month's AI use against the plan limit (same counter as the in-app assistant).
create or replace function public.chat_context(p_tenant uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'business', t.name, 'country', t.country_code, 'currency', t.base_currency, 'plan', t.plan,
    'used', (select count(*) from ai_usage where tenant_id = t.id and at >= date_trunc('month', now())),
    'limit', coalesce((select monthly_requests from ai_plan_limits where plan = t.plan), 0))
  from tenants t where t.id = p_tenant;
$$;

create or replace function public.chat_get_conversation(p_account int, p_conversation int)
returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select to_jsonb(c) from chat_conversations c
                   where c.chatwoot_account_id = p_account and c.chatwoot_conversation_id = p_conversation), '{}'::jsonb);
$$;

-- Create or update the contact and ONE lead (deal) per conversation from what the customer told the bot.
-- Never sets marketing consent: a customer messaging us is not consent to marketing.
create or replace function public.chat_upsert_lead(p_tenant uuid, p_account int, p_conversation int, p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  conv chat_conversations; cid uuid; did uuid; pid uuid; sid uuid; created boolean := false;
  v_name text := left(trim(coalesce(p->>'name','')), 120);
  v_phone text := left(trim(coalesce(p->>'phone','')), 40);
  v_email text := lower(left(trim(coalesce(p->>'email','')), 160));
  v_source text := left(coalesce(nullif(p->>'source',''), 'whatsapp'), 60);
  v_summary text := left(coalesce(p->>'summary',''), 1000);
  v_title text := left(coalesce(nullif(trim(p->>'interest'),''), 'Chat enquiry'), 160);
  v_values jsonb := coalesce(p->'values', '{}'::jsonb);
begin
  if not exists (select 1 from chat_accounts where chatwoot_account_id = p_account and tenant_id = p_tenant) then
    raise exception 'Unknown chat account';
  end if;
  if v_email <> '' and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then v_email := ''; end if;

  insert into chat_conversations (chatwoot_account_id, chatwoot_conversation_id, tenant_id)
  values (p_account, p_conversation, p_tenant) on conflict do nothing;
  select * into conv from chat_conversations
   where chatwoot_account_id = p_account and chatwoot_conversation_id = p_conversation for update;

  cid := conv.contact_id;
  if cid is null then
    select id into cid from contacts
     where tenant_id = p_tenant
       and ((v_phone <> '' and norm_phone(phone) = norm_phone(v_phone)) or (v_email <> '' and lower(email) = v_email))
     order by created_at limit 1;
  end if;
  if cid is null then
    insert into contacts (tenant_id, kind, name, phone, email, source, lifecycle)
    values (p_tenant, 'customer', coalesce(nullif(v_name,''), nullif(v_phone,''), 'Chat lead'), nullif(v_phone,''), nullif(v_email,''), v_source, 'lead')
    returning id into cid;
    created := true;
  else
    -- fill gaps only; never overwrite what staff or the customer already have on file
    update contacts set
      name  = case when v_name <> '' and name in ('Chat lead', coalesce(phone,'')) then v_name else name end,
      phone = coalesce(phone, nullif(v_phone,'')),
      email = coalesce(email, nullif(v_email,''))
    where id = cid;
  end if;

  did := conv.deal_id;
  if did is null then
    pid := ensure_pipeline(p_tenant);
    select id into sid from pipeline_stages where pipeline_id = pid and kind = 'open' order by sort_order limit 1;
    insert into deals (tenant_id, pipeline_id, stage_id, contact_id, title, value, currency, source, owner_id, custom_values)
    values (p_tenant, pid, sid, cid, v_title, 0, (select base_currency from tenants where id = p_tenant), v_source, null, v_values)
    returning id into did;
    created := true;
  else
    update deals set
      title = case when coalesce(p->>'interest','') <> '' then v_title else title end,
      custom_values = custom_values || v_values
    where id = did and tenant_id = p_tenant;
  end if;

  if v_summary <> '' and v_summary is distinct from conv.last_summary then
    insert into activities (tenant_id, contact_id, deal_id, kind, body, owner_id, created_by)
    values (p_tenant, cid, did, 'whatsapp', 'Chat summary (AI): ' || v_summary, null, null);
  end if;

  update chat_conversations set contact_id = cid, deal_id = did,
         language = coalesce(nullif(left(p->>'language', 10), ''), language),
         last_summary = coalesce(nullif(v_summary, ''), last_summary), updated_at = now()
   where chatwoot_account_id = p_account and chatwoot_conversation_id = p_conversation;

  return jsonb_build_object('contact_id', cid, 'deal_id', did, 'created', created);
end $$;

-- After every turn: count the AI use against the plan, count the reply, and remember a handover.
create or replace function public.chat_record_turn(p_tenant uuid, p_account int, p_conversation int, p_replied boolean,
                                                   p_handover boolean, p_reason text, p_model text, p_in int, p_out int, p_cost numeric)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into chat_conversations (chatwoot_account_id, chatwoot_conversation_id, tenant_id)
  values (p_account, p_conversation, p_tenant) on conflict do nothing;
  if coalesce(p_in, 0) + coalesce(p_out, 0) > 0 then
    insert into ai_usage (tenant_id, user_id, feature, input_tokens, output_tokens, cost_usd)
    values (p_tenant, null, 'chat_bot', p_in, p_out, p_cost);
  end if;
  update chat_conversations set
    bot_replies = bot_replies + case when p_replied then 1 else 0 end,
    handed_over = handed_over or coalesce(p_handover, false),
    handover_reason = case when coalesce(p_handover, false) and not handed_over then left(p_reason, 200) else handover_reason end,
    updated_at = now()
  where chatwoot_account_id = p_account and chatwoot_conversation_id = p_conversation and tenant_id = p_tenant;
end $$;

-- Service role only
do $$ declare f text; begin
  foreach f in array array[
    'chat_claim_event(int, text)', 'chat_release_event(text)', 'chat_context(uuid)', 'chat_get_conversation(int, int)',
    'chat_upsert_lead(uuid, int, int, jsonb)', 'chat_record_turn(uuid, int, int, boolean, boolean, text, text, int, int, numeric)'
  ] loop
    execute format('revoke execute on function public.%s from public, anon, authenticated', f);
    execute format('grant execute on function public.%s to service_role', f);
  end loop;
end $$;
