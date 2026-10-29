-- Ai buddy Biz — Batch G: Legal
-- Contract templates, contracts with versions, electronic signing (tamper-evident),
-- key dates & obligations, compliance calendar (Malaysia), AI lawyer results & quota.
-- Depends on 0001–0006.
--
-- Electronic signatures: Malaysia's Electronic Commerce Act 2006 accepts an electronic signature that
-- identifies the signer, shows their approval, and is as reliable as appropriate (method under the signer's
-- sole control; later changes detectable). The Act does NOT cover powers of attorney, wills/codicils, trusts
-- or negotiable instruments — those templates are blocked from e-signing here.

-- ===== Permissions & roles =====
insert into public.permissions (code, module, description) values
  ('law.view','LAW','View contracts and the compliance calendar'),
  ('law.manage','LAW','Create and edit contracts and templates'),
  ('law.send','LAW','Send contracts for signature and cancel signing'),
  ('law.compliance','LAW','Manage compliance calendar items'),
  ('law.ai','LAW','Use the AI legal assistant');

insert into public.roles (tenant_id, name, is_builtin) values (null, 'Legal', true);

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r join public.permissions p on p.module = 'LAW'
where r.tenant_id is null and r.name in ('Owner','Admin','Legal')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r, unnest(array['law.view','law.manage','law.send','law.ai']) c
where r.tenant_id is null and r.name in ('Manager','HR')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r, unnest(array['law.view','law.compliance']) c
where r.tenant_id is null and r.name = 'Accountant'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r, unnest(array['law.view','law.manage','law.send']) c
where r.tenant_id is null and r.name = 'Sales'
on conflict do nothing;

-- Company details used to fill templates
alter table public.tenants
  add column if not exists legal_name text,
  add column if not exists company_reg_no text,
  add column if not exists address text,
  add column if not exists phone text,
  add column if not exists email text;

-- ===== Templates =====
create table public.legal_templates (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references public.tenants(id) on delete cascade,   -- null = starter template for everyone
  code text not null,
  name text not null,
  category text not null check (category in ('nda','employment','service','sales_terms','supplier','tenancy','privacy','letter','other')),
  jurisdiction char(2) not null default 'MY',
  language text not null default 'en',
  description text,
  body text not null,                              -- uses {{variable}} placeholders
  variables jsonb not null default '[]',           -- [{"key":"…","label":"…","type":"text|date|money|number|longtext","required":true}]
  e_signable boolean not null default true,
  version int not null default 1,
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  unique nulls not distinct (tenant_id, code)
);

-- ===== Contracts =====
create table public.contract_counters (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  next_no bigint not null default 1
);
alter table public.contract_counters enable row level security;

create table public.contracts (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  number text,
  title text not null,
  category text not null default 'other' check (category in ('nda','employment','service','sales_terms','supplier','tenancy','privacy','letter','other')),
  template_id uuid references public.legal_templates(id) on delete set null,
  contact_id uuid references public.contacts(id) on delete set null,
  supplier_id uuid references public.suppliers(id) on delete set null,
  employee_id uuid references public.employees(id) on delete set null,
  variables jsonb not null default '{}',
  body text not null default '',
  status text not null default 'draft' check (status in
    ('draft','in_review','out_for_signature','partially_signed','signed','expired','terminated','cancelled')),
  value numeric(14,2),
  currency char(3),
  start_date date,
  end_date date,
  auto_renew boolean not null default false,
  notice_days int,                                  -- notice needed to end / not renew
  governing_law text not null default 'Malaysia',
  e_signable boolean not null default true,
  content_hash text,                                -- SHA-256 of title + body, fixed when sent for signing
  sent_at timestamptz,
  signed_at timestamptz,
  terminated_at timestamptz,
  owner_id uuid references auth.users(id) default auth.uid(),
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (tenant_id, number),
  check (end_date is null or start_date is null or end_date >= start_date)
);
create index on public.contracts (tenant_id, status);
create index on public.contracts (content_hash);

create table public.contract_versions (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  contract_id uuid not null references public.contracts(id) on delete cascade,
  version int not null,
  title text not null,
  body text not null,
  note text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  unique (contract_id, version)
);

create table public.contract_signers (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  contract_id uuid not null references public.contracts(id) on delete cascade,
  name text not null,
  email text,
  phone text,
  role text not null default 'counterparty' check (role in ('company','counterparty','witness','other')),
  sign_order int not null default 1,
  token text,                                       -- secret link; issued when sent
  require_code boolean not null default false,      -- one-time code by email/WhatsApp before signing
  code_hash text,
  code_expires timestamptz,
  code_attempts int not null default 0,
  status text not null default 'pending' check (status in ('pending','viewed','signed','declined')),
  viewed_at timestamptz,
  signed_at timestamptz,
  signed_name text,
  signature_image text,                             -- PNG as data URL, drawn by the signer
  signed_hash text,                                 -- content hash the signer saw
  ip text,
  user_agent text,
  decline_reason text,
  unique (token)
);

create table public.contract_events (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  contract_id uuid not null references public.contracts(id) on delete cascade,
  signer_id uuid references public.contract_signers(id) on delete set null,
  event text not null,                              -- created, saved_version, sent, viewed, code_sent, signed, declined, completed, cancelled, terminated, expired
  detail text,
  ip text,
  user_agent text,
  at timestamptz not null default now(),
  by_user uuid default auth.uid()
);
create index on public.contract_events (contract_id, at);

create or replace function public.content_hash(p_title text, p_body text)
returns text language sql immutable as $$
  select encode(sha256(convert_to(coalesce(p_title,'') || E'\n' || coalesce(p_body,''), 'UTF8')), 'hex');
$$;

create or replace function public.req_header(p text)
returns text language sql stable as $$
  select nullif(split_part(coalesce((nullif(current_setting('request.headers', true), '')::json ->> p), ''), ',', 1), '');
$$;

create or replace function public.contract_before()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    if new.number is null then
      insert into contract_counters (tenant_id) values (new.tenant_id) on conflict do nothing;
      update contract_counters set next_no = next_no + 1 where tenant_id = new.tenant_id
        returning 'LAW-' || lpad((next_no - 1)::text, 5, '0') into new.number;
    end if;
    new.currency := coalesce(new.currency, (select base_currency from tenants where id = new.tenant_id));
    if new.template_id is not null then
      new.e_signable := coalesce((select e_signable from legal_templates where id = new.template_id), true);
    end if;
  else
    if old.status not in ('draft','in_review') and current_setting('abb.contract_fn', true) is distinct from 'on'
       and (new.body is distinct from old.body or new.title is distinct from old.title or new.variables is distinct from old.variables) then
      raise exception 'This contract is % — cancel signing or make a new version to change the wording', old.status;
    end if;
    if new.status is distinct from old.status and current_setting('abb.contract_fn', true) is distinct from 'on'
       and not (old.status in ('draft','in_review') and new.status in ('draft','in_review'))
       and not (old.status = 'signed' and new.status in ('expired','terminated')) then
      raise exception 'Use the send / cancel / terminate actions to change status';
    end if;
  end if;
  new.updated_at := now();
  return new;
end $$;
create trigger trg_contract_before before insert or update on public.contracts for each row execute function public.contract_before();

create or replace function public.contract_log(p_contract uuid, p_event text, p_detail text default null, p_signer uuid default null)
returns void language sql security definer set search_path = public as $$
  insert into contract_events (tenant_id, contract_id, signer_id, event, detail, ip, user_agent)
  select tenant_id, id, p_signer, p_event, p_detail, req_header('x-forwarded-for'), left(req_header('user-agent'), 300)
  from contracts where id = p_contract;
$$;

create or replace function public.contract_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform contract_log(new.id, 'created', new.title);
  return null;
end $$;
create trigger trg_contract_after_insert after insert on public.contracts for each row execute function public.contract_after_insert();

create or replace function public.save_contract_version(p_contract uuid, p_note text default null)
returns int language plpgsql security definer set search_path = public as $$
declare c contracts; v int;
begin
  select * into c from contracts where id = p_contract;
  if not has_perm(c.tenant_id, 'law.manage') then raise exception 'Not allowed'; end if;
  select coalesce(max(version),0) + 1 into v from contract_versions where contract_id = c.id;
  insert into contract_versions (tenant_id, contract_id, version, title, body, note) values (c.tenant_id, c.id, v, c.title, c.body, p_note);
  perform contract_log(c.id, 'saved_version', 'v' || v || coalesce(': ' || p_note, ''));
  return v;
end $$;

-- Send: fixes the wording (hash), issues secret links, optionally messages each signer
create or replace function public.send_for_signature(p_contract uuid, p_sign_base_url text default null, p_notify boolean default false)
returns setof public.contract_signers language plpgsql security definer set search_path = public as $$
declare c contracts; s contract_signers; biz text; link text;
begin
  select * into c from contracts where id = p_contract for update;
  if not found then raise exception 'Unknown contract'; end if;
  if not has_perm(c.tenant_id, 'law.send') then raise exception 'Not allowed'; end if;
  if c.status not in ('draft','in_review') then raise exception 'Contract is already %', c.status; end if;
  if not c.e_signable then
    raise exception 'This kind of document (e.g. power of attorney, will, trust, negotiable instrument) cannot be signed electronically under the Electronic Commerce Act 2006 — print and sign it';
  end if;
  if length(trim(c.body)) < 50 then raise exception 'The contract text is too short'; end if;
  if c.body ~ '\{\{[a-z_]+\}\}' then raise exception 'Fill in all {{blanks}} before sending'; end if;
  if not exists (select 1 from contract_signers where contract_id = c.id) then raise exception 'Add at least one signer'; end if;
  if exists (select 1 from contract_signers where contract_id = c.id and require_code and email is null and phone is null) then
    raise exception 'A signer who must confirm a code needs an email or phone';
  end if;
  select name into biz from tenants where id = c.tenant_id;

  perform save_contract_version(c.id, 'Sent for signature');
  perform set_config('abb.contract_fn', 'on', true);
  update contracts set status = 'out_for_signature', content_hash = content_hash(title, body), sent_at = now() where id = c.id;
  perform set_config('abb.contract_fn', 'off', true);
  update contract_signers set token = encode(sha256(convert_to(gen_random_uuid()::text || clock_timestamp()::text || id::text, 'UTF8')), 'hex'),
    status = 'pending', viewed_at = null, signed_at = null, signed_name = null, signature_image = null, signed_hash = null,
    code_hash = null, code_attempts = 0, decline_reason = null
  where contract_id = c.id;
  perform contract_log(c.id, 'sent', (select string_agg(name, ', ' order by sign_order) from contract_signers where contract_id = c.id));

  if p_notify and p_sign_base_url is not null then
    for s in select * from contract_signers where contract_id = c.id and (email is not null or phone is not null) loop
      link := p_sign_base_url || '?t=' || s.token;
      insert into outbound_messages (tenant_id, channel, to_address, subject, body)
      values (c.tenant_id, case when s.email is not null then 'email' else 'whatsapp' end,
              coalesce(lower(s.email), norm_phone(s.phone)),
              'Please sign: ' || c.title,
              'Hi ' || split_part(s.name, ' ', 1) || ', ' || biz || ' has sent you "' || c.title || '" (' || c.number || ') to sign: ' || link);
    end loop;
  end if;
  return query select * from contract_signers where contract_id = c.id order by sign_order, name;
end $$;

create or replace function public.cancel_signing(p_contract uuid, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare c contracts;
begin
  select * into c from contracts where id = p_contract for update;
  if not has_perm(c.tenant_id, 'law.send') then raise exception 'Not allowed'; end if;
  if c.status not in ('out_for_signature','partially_signed') then raise exception 'Contract is %', c.status; end if;
  if coalesce(trim(p_reason),'') = '' then raise exception 'A reason is required'; end if;
  perform set_config('abb.contract_fn', 'on', true);
  update contracts set status = 'draft', content_hash = null, sent_at = null where id = c.id;
  perform set_config('abb.contract_fn', 'off', true);
  update contract_signers set token = null where contract_id = c.id;      -- old links stop working
  perform contract_log(c.id, 'cancelled', p_reason);
end $$;

create or replace function public.terminate_contract(p_contract uuid, p_reason text, p_on date default current_date)
returns void language plpgsql security definer set search_path = public as $$
declare c contracts;
begin
  select * into c from contracts where id = p_contract;
  if not has_perm(c.tenant_id, 'law.manage') then raise exception 'Not allowed'; end if;
  if c.status <> 'signed' then raise exception 'Only signed contracts can be terminated'; end if;
  perform set_config('abb.contract_fn', 'on', true);
  update contracts set status = 'terminated', terminated_at = p_on::timestamptz,
    end_date = greatest(coalesce(start_date, p_on), least(coalesce(end_date, p_on), p_on)) where id = c.id;
  perform set_config('abb.contract_fn', 'off', true);
  perform contract_log(c.id, 'terminated', p_reason);
end $$;

-- ===== Public signing (no login; the secret link is the key) =====
create or replace function public.signer_by_token(p_token text)
returns public.contract_signers language plpgsql stable security definer set search_path = public as $$
declare s contract_signers;
begin
  if length(coalesce(p_token,'')) < 32 then raise exception 'Invalid link'; end if;
  select * into s from contract_signers where token = p_token;
  if not found then raise exception 'This signing link is no longer valid'; end if;
  return s;
end $$;

create or replace function public.get_signing_doc(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s contract_signers; c contracts; biz text; blocked text;
begin
  s := signer_by_token(p_token);
  select * into c from contracts where id = s.contract_id;
  if c.status not in ('out_for_signature','partially_signed','signed') then raise exception 'This document is no longer open for signing'; end if;
  select name into biz from tenants where id = c.tenant_id;
  if s.status = 'pending' then
    update contract_signers set status = 'viewed', viewed_at = now() where id = s.id;
    perform contract_log(c.id, 'viewed', s.name, s.id);
  end if;
  if exists (select 1 from contract_signers o where o.contract_id = c.id and o.sign_order < s.sign_order and o.status <> 'signed') then
    blocked := 'Waiting for earlier signers';
  end if;
  return jsonb_build_object(
    'business', biz, 'number', c.number, 'title', c.title, 'body', c.body, 'hash', c.content_hash,
    'signer', jsonb_build_object('name', s.name, 'role', s.role, 'status', case when s.status = 'pending' then 'viewed' else s.status end,
                                 'require_code', s.require_code, 'signed_at', s.signed_at),
    'blocked', blocked,
    'signers', (select jsonb_agg(jsonb_build_object('name', o.name, 'role', o.role, 'status', o.status, 'signed_at', o.signed_at) order by o.sign_order, o.name)
                from contract_signers o where o.contract_id = c.id));
end $$;

create or replace function public.request_sign_code(p_token text)
returns text language plpgsql security definer set search_path = public as $$
declare s contract_signers; c contracts; code text; biz text;
begin
  s := signer_by_token(p_token);
  if not s.require_code then return 'not_required'; end if;
  if s.status in ('signed','declined') then raise exception 'Already %', s.status; end if;
  if s.code_expires is not null and s.code_expires > now() + interval '9 minutes' then raise exception 'Please wait a minute before asking for another code'; end if;
  select * into c from contracts where id = s.contract_id;
  select name into biz from tenants where id = c.tenant_id;
  code := lpad((floor(random() * 1000000))::int::text, 6, '0');
  update contract_signers set code_hash = encode(sha256(convert_to(code || p_token, 'UTF8')), 'hex'),
    code_expires = now() + interval '10 minutes', code_attempts = 0 where id = s.id;
  insert into outbound_messages (tenant_id, channel, to_address, subject, body)
  values (c.tenant_id, case when s.email is not null then 'email' else 'whatsapp' end, coalesce(lower(s.email), norm_phone(s.phone)),
          'Your signing code', 'Your code to sign "' || c.title || '" from ' || biz || ' is ' || code || '. It expires in 10 minutes.');
  perform contract_log(c.id, 'code_sent', case when s.email is not null then 'email' else 'phone' end, s.id);
  return case when s.email is not null then 'email' else 'phone' end;
end $$;

create or replace function public.sign_document(p_token text, p_signed_name text, p_signature text, p_consent boolean, p_code text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s contract_signers; c contracts; remaining int;
begin
  s := signer_by_token(p_token);
  select * into c from contracts where id = s.contract_id for update;
  if c.status not in ('out_for_signature','partially_signed') then raise exception 'This document is no longer open for signing'; end if;
  if s.status in ('signed','declined') then raise exception 'You have already %', case s.status when 'signed' then 'signed' else 'declined' end; end if;
  if exists (select 1 from contract_signers o where o.contract_id = c.id and o.sign_order < s.sign_order and o.status <> 'signed') then
    raise exception 'Waiting for earlier signers';
  end if;
  if not coalesce(p_consent, false) then raise exception 'Please tick the box to agree to sign electronically'; end if;
  if length(trim(coalesce(p_signed_name,''))) < 2 then raise exception 'Type your full name'; end if;
  if coalesce(p_signature,'') !~ '^data:image/png;base64,' or length(p_signature) > 300000 then raise exception 'Please draw your signature'; end if;
  if content_hash(c.title, c.body) <> c.content_hash then raise exception 'The document changed after it was sent — ask the sender for a new link'; end if;
  if s.require_code then
    if s.code_attempts >= 5 then raise exception 'Too many wrong codes — request a new one'; end if;
    if s.code_hash is null or s.code_expires < now()
       or encode(sha256(convert_to(coalesce(p_code,'') || p_token, 'UTF8')), 'hex') <> s.code_hash then
      update contract_signers set code_attempts = code_attempts + 1 where id = s.id;
      perform contract_log(c.id, 'code_failed', null, s.id);
      return jsonb_build_object('ok', false, 'error', 'Wrong or expired code');
    end if;
  end if;

  update contract_signers set status = 'signed', signed_at = now(), signed_name = trim(p_signed_name), signature_image = p_signature,
    signed_hash = c.content_hash, ip = req_header('x-forwarded-for'), user_agent = left(req_header('user-agent'), 300), code_hash = null
  where id = s.id;
  perform contract_log(c.id, 'signed', trim(p_signed_name), s.id);

  select count(*) into remaining from contract_signers where contract_id = c.id and status <> 'signed';
  perform set_config('abb.contract_fn', 'on', true);
  if remaining = 0 then
    update contracts set status = 'signed', signed_at = now() where id = c.id;
    perform contract_log(c.id, 'completed', 'All parties signed');
  else
    update contracts set status = 'partially_signed' where id = c.id;
  end if;
  perform set_config('abb.contract_fn', 'off', true);
  return jsonb_build_object('ok', true, 'completed', remaining = 0);
end $$;

create or replace function public.decline_document(p_token text, p_reason text)
returns void language plpgsql security definer set search_path = public as $$
declare s contract_signers;
begin
  s := signer_by_token(p_token);
  if s.status in ('signed','declined') then raise exception 'Already %', s.status; end if;
  update contract_signers set status = 'declined', decline_reason = left(coalesce(p_reason,''), 500) where id = s.id;
  perform contract_log(s.contract_id, 'declined', left(p_reason, 200), s.id);
end $$;

-- Anyone holding a signed PDF can check it against our record by its fingerprint
create or replace function public.verify_document(p_hash text)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('found', true, 'number', c.number, 'title', c.title, 'business', t.name, 'status', c.status,
    'signed_at', c.signed_at,
    'signers', (select jsonb_agg(jsonb_build_object('name', s.signed_name, 'role', s.role, 'signed_at', s.signed_at) order by s.signed_at)
                from contract_signers s where s.contract_id = c.id and s.status = 'signed'))
  from contracts c join tenants t on t.id = c.tenant_id
  where length(coalesce(p_hash,'')) = 64 and c.content_hash = lower(p_hash)
  union all
  select jsonb_build_object('found', false)
  where not exists (select 1 from contracts where length(coalesce(p_hash,'')) = 64 and content_hash = lower(p_hash))
  limit 1;
$$;

revoke execute on function public.get_signing_doc(text), public.request_sign_code(text), public.sign_document(text,text,text,boolean,text),
                           public.decline_document(text,text), public.verify_document(text) from public;
grant execute on function public.get_signing_doc(text), public.request_sign_code(text), public.sign_document(text,text,text,boolean,text),
                          public.decline_document(text,text), public.verify_document(text) to anon, authenticated;

-- ===== Key dates & obligations =====
create table public.legal_obligations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  contract_id uuid references public.contracts(id) on delete cascade,
  title text not null,
  kind text not null default 'deadline' check (kind in ('renewal_notice','expiry','payment','deliverable','deadline','review','other')),
  due_date date not null,
  remind_days int not null default 14,
  status text not null default 'open' check (status in ('open','done','dismissed')),
  source text not null default 'manual' check (source in ('manual','ai','system')),
  note text,
  done_at timestamptz,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.legal_obligations (tenant_id, status, due_date);

-- Contract dates create their own reminders
create or replace function public.contract_dates_after()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status in ('terminated','cancelled','expired') then
    update legal_obligations set status = 'dismissed' where contract_id = new.id and status = 'open';
    return null;
  end if;
  if new.status not in ('signed','out_for_signature','partially_signed') then return null; end if;
  delete from legal_obligations where contract_id = new.id and source = 'system' and status = 'open';
  if new.end_date is not null and new.status = 'signed' then
    insert into legal_obligations (tenant_id, contract_id, title, kind, due_date, remind_days, source)
    values (new.tenant_id, new.id, new.title || ' — ' || case when new.auto_renew then 'renews' else 'expires' end, 'expiry', new.end_date, 30, 'system');
    if new.notice_days is not null then
      insert into legal_obligations (tenant_id, contract_id, title, kind, due_date, remind_days, source)
      values (new.tenant_id, new.id, 'Last day to give notice: ' || new.title, 'renewal_notice', new.end_date - new.notice_days, 14, 'system');
    end if;
  end if;
  return null;
end $$;
create trigger trg_contract_dates after insert or update of status, end_date, notice_days, auto_renew on public.contracts
  for each row execute function public.contract_dates_after();

-- ===== Compliance calendar =====
create table public.compliance_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  code text,                                        -- for the built-in items
  title text not null,
  authority text,
  category text not null default 'other' check (category in ('tax','company','payroll','licence','data_protection','contract','other')),
  due_date date,                                    -- null = needs a date from you
  recurrence text not null default 'none' check (recurrence in ('none','monthly','bimonthly','quarterly','annual')),
  remind_days int not null default 7,
  status text not null default 'open' check (status in ('open','done','not_applicable')),
  note text,
  done_at timestamptz,
  done_by uuid,
  created_at timestamptz not null default now()
);
create index on public.compliance_items (tenant_id, status, due_date);

create or replace function public.next_due(p_date date, p_rec text)
returns date language sql immutable as $$
  select case p_rec
    when 'monthly' then (p_date + interval '1 month')::date
    when 'bimonthly' then (p_date + interval '2 months')::date
    when 'quarterly' then (p_date + interval '3 months')::date
    when 'annual' then (p_date + interval '1 year')::date
  end;
$$;

-- Starter Malaysian deadlines. Dates are general rules — check them against your own registrations.
create or replace function public.ensure_compliance_defaults(p_tenant uuid)
returns void language plpgsql security definer set search_path = public as $$
declare d date := current_date; m15 date; feb_end date; mar31 date;
begin
  if exists (select 1 from compliance_items where tenant_id = p_tenant and code is not null) then return; end if;
  m15 := case when extract(day from d) <= 15 then make_date(extract(year from d)::int, extract(month from d)::int, 15)
              else (make_date(extract(year from d)::int, extract(month from d)::int, 15) + interval '1 month')::date end;
  feb_end := (make_date(extract(year from d)::int + case when d > (make_date(extract(year from d)::int, 3, 1) - 1) then 1 else 0 end, 3, 1) - 1);
  mar31 := make_date(extract(year from d)::int + case when d > make_date(extract(year from d)::int, 3, 31) then 1 else 0 end, 3, 31);
  insert into compliance_items (tenant_id, code, title, authority, category, due_date, recurrence, remind_days, note) values
    (p_tenant,'epf_monthly','Pay EPF contributions','KWSP','payroll',m15,'monthly',5,'By the 15th of the following month.'),
    (p_tenant,'socso_monthly','Pay SOCSO & EIS contributions','PERKESO','payroll',m15,'monthly',5,'By the 15th of the following month.'),
    (p_tenant,'pcb_monthly','Pay PCB (monthly tax deductions)','LHDN','payroll',m15,'monthly',5,'By the 15th of the following month, via e-PCB Plus.'),
    (p_tenant,'ea_forms','Give EA forms to employees','LHDN','payroll',feb_end,'annual',21,'By the last day of February.'),
    (p_tenant,'form_e','File Form E (employer return)','LHDN','payroll',mar31,'annual',21,'By 31 March (e-Filing grace period usually to 30 April).'),
    (p_tenant,'sst_return','File SST-02 return','RMCD (Customs)','tax',(date_trunc('month', d) + interval '2 months - 1 day')::date,'bimonthly',10,
       'If SST-registered: due by the last day of the month after each taxable period. Set this to your own period.'),
    (p_tenant,'cp204','Pay CP204 tax instalment','LHDN','tax',m15,'monthly',5,'Companies only: monthly instalment of estimated tax. Mark not applicable if you are a sole proprietor.'),
    (p_tenant,'form_c','File Form C (company tax return)','LHDN','tax',null,'annual',30,'Within 7 months after your financial year end. Enter the date.'),
    (p_tenant,'ssm_annual_return','File SSM annual return','SSM','company',null,'annual',30,'Within 30 days after each incorporation anniversary (Sdn Bhd). Enter the date.'),
    (p_tenant,'ssm_accounts','Lodge financial statements with SSM','SSM','company',null,'annual',30,'Within 30 days after circulating them to members (circulate within 6 months of year end).'),
    (p_tenant,'premise_licence','Renew business premise / signboard licence','Local council (PBT)','licence',null,'annual',30,'Enter your licence expiry date.'),
    (p_tenant,'pdpa_review','Review personal data protection (PDPA)','PDP Commissioner','data_protection',(d + 30),'annual',14,
       'Check your privacy notice (Malay & English), whether you must appoint a DPO (>20,000 people, or >10,000 with sensitive data), and your breach plan: notify the Commissioner within 72 hours and affected people within 7 days.');
end $$;

create or replace function public.complete_compliance(p_item uuid, p_not_applicable boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare it compliance_items; nid uuid;
begin
  select * into it from compliance_items where id = p_item for update;
  if not has_perm(it.tenant_id, 'law.compliance') and not has_perm(it.tenant_id, 'law.manage') then raise exception 'Not allowed'; end if;
  if it.status <> 'open' then raise exception 'Already %', it.status; end if;
  update compliance_items set status = case when p_not_applicable then 'not_applicable' else 'done' end, done_at = now(), done_by = auth.uid() where id = it.id;
  if not p_not_applicable and it.recurrence <> 'none' and it.due_date is not null then
    insert into compliance_items (tenant_id, code, title, authority, category, due_date, recurrence, remind_days, note)
    values (it.tenant_id, it.code, it.title, it.authority, it.category, next_due(it.due_date, it.recurrence), it.recurrence, it.remind_days, it.note)
    returning id into nid;
  end if;
  return nid;
end $$;

-- One list for the calendar screen
create or replace view public.legal_calendar with (security_invoker = true) as
select 'compliance'::text as source, ci.id, ci.tenant_id, ci.title, ci.category as kind, ci.authority as detail, ci.due_date,
       ci.remind_days, ci.status, null::uuid as contract_id, ci.note, ci.recurrence
from compliance_items ci
union all
select 'obligation', o.id, o.tenant_id, o.title, o.kind, c.number, o.due_date, o.remind_days, o.status, o.contract_id, o.note, 'none'
from legal_obligations o left join contracts c on c.id = o.contract_id;

-- ===== AI legal assistant =====
create table public.ai_legal_results (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  contract_id uuid references public.contracts(id) on delete cascade,
  kind text not null check (kind in ('review','draft','ask','extract_dates')),
  prompt text,
  result jsonb not null,
  model text,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);
create index on public.ai_legal_results (tenant_id, created_at desc);

-- Monthly AI requests by plan (all AI features share this)
create table public.ai_plan_limits (
  plan text primary key,
  monthly_requests int not null
);
insert into public.ai_plan_limits values ('free',10),('starter',50),('growth',300),('pro',1500),('enterprise',20000);

create or replace function public.ai_quota(p_tenant uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'used', (select count(*) from ai_usage where tenant_id = p_tenant and at >= date_trunc('month', now())),
    'limit', (select monthly_requests from ai_plan_limits where plan = t.plan),
    'plan', t.plan)
  from tenants t where t.id = p_tenant and is_member(p_tenant);
$$;

-- Called by the ai-legal function with the user's own login: checks rights and quota, returns what the AI may read
create or replace function public.ai_legal_prepare(p_tenant uuid, p_kind text, p_contract uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare q jsonb; c contracts; t tenants;
begin
  if not has_perm(p_tenant, 'law.ai') then raise exception 'Not allowed to use the AI legal assistant'; end if;
  q := ai_quota(p_tenant);
  if (q->>'used')::int >= (q->>'limit')::int then
    raise exception 'Monthly AI limit reached (% of %). Upgrade your plan for more.', q->>'used', q->>'limit';
  end if;
  select * into t from tenants where id = p_tenant;
  if p_contract is not null then
    select * into c from contracts where id = p_contract and tenant_id = p_tenant;
    if not found or not has_perm(p_tenant, 'law.view') then raise exception 'Unknown contract'; end if;
  end if;
  return jsonb_build_object('business', t.name, 'country', t.country_code, 'currency', t.base_currency,
    'contract', case when c.id is null then null else jsonb_build_object('number', c.number, 'title', c.title, 'category', c.category,
      'body', c.body, 'start_date', c.start_date, 'end_date', c.end_date, 'governing_law', c.governing_law, 'value', c.value, 'currency', c.currency) end);
end $$;

create or replace function public.ai_legal_save(p_tenant uuid, p_kind text, p_contract uuid, p_prompt text, p_result jsonb,
                                                p_model text, p_in int, p_out int, p_cost numeric)
returns uuid language plpgsql security definer set search_path = public as $$
declare rid uuid;
begin
  if not has_perm(p_tenant, 'law.ai') then raise exception 'Not allowed'; end if;
  insert into ai_legal_results (tenant_id, contract_id, kind, prompt, result, model)
  values (p_tenant, p_contract, p_kind, left(p_prompt, 4000), p_result, p_model) returning id into rid;
  insert into ai_usage (tenant_id, user_id, feature, input_tokens, output_tokens, cost_usd)
  values (p_tenant, auth.uid(), 'legal.' || p_kind, p_in, p_out, p_cost);
  if p_contract is not null then perform contract_log(p_contract, 'ai_' || p_kind, p_model); end if;
  return rid;
end $$;

-- Confirmed AI date suggestions become obligations (a person approves each one)
create or replace function public.accept_ai_dates(p_contract uuid, p_items jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare c contracts; it jsonb; n int := 0;
begin
  select * into c from contracts where id = p_contract;
  if not has_perm(c.tenant_id, 'law.manage') then raise exception 'Not allowed'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    if (it->>'date') is null or (it->>'title') is null then continue; end if;
    insert into legal_obligations (tenant_id, contract_id, title, kind, due_date, source, note)
    values (c.tenant_id, c.id, left(it->>'title', 200),
            case when it->>'kind' in ('renewal_notice','expiry','payment','deliverable','deadline','review') then it->>'kind' else 'other' end,
            (it->>'date')::date, 'ai', left(it->>'note', 500));
    n := n + 1;
  end loop;
  return n;
end $$;

-- ===== RLS =====
alter table public.legal_templates enable row level security;
create policy tpl_read on public.legal_templates for select to authenticated using (tenant_id is null or has_perm(tenant_id, 'law.view'));
create policy tpl_write on public.legal_templates for all
  using (tenant_id is not null and has_perm(tenant_id, 'law.manage')) with check (tenant_id is not null and has_perm(tenant_id, 'law.manage'));

alter table public.contracts enable row level security;
create policy contracts_read on public.contracts for select using (has_perm(tenant_id, 'law.view'));
create policy contracts_write on public.contracts for insert with check (has_perm(tenant_id, 'law.manage'));
create policy contracts_update on public.contracts for update using (has_perm(tenant_id, 'law.manage')) with check (has_perm(tenant_id, 'law.manage'));
create policy contracts_delete on public.contracts for delete using (has_perm(tenant_id, 'law.manage') and status = 'draft');

alter table public.contract_versions enable row level security;
create policy versions_read on public.contract_versions for select using (has_perm(tenant_id, 'law.view'));

alter table public.contract_signers enable row level security;
create policy signers_read on public.contract_signers for select using (has_perm(tenant_id, 'law.view'));
create policy signers_write on public.contract_signers for all
  using (has_perm(tenant_id, 'law.manage') and exists (select 1 from contracts c where c.id = contract_id and c.status in ('draft','in_review')))
  with check (has_perm(tenant_id, 'law.manage') and exists (select 1 from contracts c where c.id = contract_id and c.status in ('draft','in_review')));

alter table public.contract_events enable row level security;
create policy events_read_law on public.contract_events for select using (has_perm(tenant_id, 'law.view'));

alter table public.legal_obligations enable row level security;
create policy obl_read on public.legal_obligations for select using (has_perm(tenant_id, 'law.view'));
create policy obl_write on public.legal_obligations for all
  using (has_perm(tenant_id, 'law.manage') or has_perm(tenant_id, 'law.compliance'))
  with check (has_perm(tenant_id, 'law.manage') or has_perm(tenant_id, 'law.compliance'));

alter table public.compliance_items enable row level security;
create policy comp_read on public.compliance_items for select using (has_perm(tenant_id, 'law.view'));
create policy comp_write on public.compliance_items for all
  using (has_perm(tenant_id, 'law.compliance') or has_perm(tenant_id, 'law.manage'))
  with check (has_perm(tenant_id, 'law.compliance') or has_perm(tenant_id, 'law.manage'));

alter table public.ai_legal_results enable row level security;
create policy ai_res_read on public.ai_legal_results for select using (has_perm(tenant_id, 'law.ai') or has_perm(tenant_id, 'law.view'));

alter table public.ai_plan_limits enable row level security;
create policy ai_limits_read on public.ai_plan_limits for select to authenticated using (true);

do $$ declare t text; begin
  foreach t in array array['contracts','legal_templates','compliance_items','legal_obligations'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- New and existing businesses get the starter compliance calendar
create or replace function public.tenant_law_init()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform ensure_compliance_defaults(new.id);
  return null;
end $$;
create trigger trg_tenant_law_init after insert on public.tenants for each row execute function public.tenant_law_init();
do $$ declare t record; begin
  for t in select id from public.tenants loop perform public.ensure_compliance_defaults(t.id); end loop;
end $$;
