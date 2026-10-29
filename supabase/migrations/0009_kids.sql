-- Ai buddy Biz — Batch H: Kids care monitor (TASKA / TADIKA / after-school care)
-- Rooms with carer ratios, children & guardians, safe check-in / check-out with authorised pick-up,
-- daily logs & photos for parents, medicine authorisation & doses, incidents with parent acknowledgement,
-- parent ↔ centre messages, absence notices, monthly fee invoices, and app access by invitation.
-- Depends on 0001–0008.
--
-- Ratios seeded from the Child Care Centre Regulations 2012 as commonly published (under 1 yr 1:3,
-- 1–3 yrs 1:5, 3–4 yrs 1:10) and KPM pre-school practice (4 yrs 1:10, 5–6 yrs 1:15). They are data per
-- room — check them against your licence conditions.

-- ===== App access by invitation (all modules) =====
create table public.invites (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  email text not null,
  role_id uuid not null references public.roles(id),
  outlet_ids uuid[],
  invited_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  accepted_by uuid,
  unique (tenant_id, email)
);
alter table public.invites enable row level security;
create policy invites_read on public.invites for select using (has_perm(tenant_id, 'core.user.manage'));
create policy invites_write on public.invites for all
  using (has_perm(tenant_id, 'core.user.manage')) with check (has_perm(tenant_id, 'core.user.manage'));

create or replace function public.invite_user(p_tenant uuid, p_email text, p_role uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare em text := lower(trim(p_email)); rid uuid; r roles;
begin
  if not has_perm(p_tenant, 'core.user.manage') then raise exception 'Not allowed to invite people'; end if;
  if em !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email doesn''t look right'; end if;
  select * into r from roles where id = p_role and (tenant_id is null or tenant_id = p_tenant);
  if not found then raise exception 'Unknown role'; end if;
  if r.name = 'Owner' and not exists (select 1 from memberships m join roles o on o.id = m.role_id
       where m.tenant_id = p_tenant and m.user_id = auth.uid() and o.name = 'Owner') then
    raise exception 'Only an owner can invite another owner';
  end if;
  insert into invites (tenant_id, email, role_id) values (p_tenant, em, p_role)
  on conflict (tenant_id, email) do update set role_id = excluded.role_id, accepted_at = null, accepted_by = null, created_at = now()
  returning id into rid;
  return rid;
end $$;

-- Called by the app after sign-in: turns invitations for this verified email into memberships
create or replace function public.claim_invites()
returns int language plpgsql security definer set search_path = public as $$
declare em text; i invites; n int := 0;
begin
  if auth.uid() is null then return 0; end if;
  select lower(email) into em from auth.users where id = auth.uid() and email_confirmed_at is not null;
  if em is null then return 0; end if;
  for i in select * from invites where email = em and accepted_at is null loop
    insert into memberships (tenant_id, user_id, role_id, outlet_ids) values (i.tenant_id, auth.uid(), i.role_id, i.outlet_ids)
    on conflict (tenant_id, user_id) do update set active = true,
      -- never downgrade an existing staff member to Parent by a guardian invite
      role_id = case when (select name from roles where id = i.role_id) = 'Parent' then memberships.role_id else excluded.role_id end;
    update invites set accepted_at = now(), accepted_by = auth.uid() where id = i.id;
    n := n + 1;
  end loop;
  -- link guardian records with the same email
  update guardians g set user_id = auth.uid() where g.email = em and g.user_id is null and g.active;
  return n;
end $$;

-- Team list for owners/admins (emails live in auth.users)
create or replace function public.team_members(p_tenant uuid)
returns table (membership_id uuid, user_id uuid, email text, role_id uuid, role_name text, active boolean, created_at timestamptz)
language sql stable security definer set search_path = public as $$
  select m.id, m.user_id, u.email, m.role_id, r.name, m.active, m.created_at
  from memberships m join roles r on r.id = m.role_id left join auth.users u on u.id = m.user_id
  where m.tenant_id = p_tenant and has_perm(p_tenant, 'core.user.manage')
  order by m.active desc, r.name, u.email;
$$;

create or replace function public.set_member(p_membership uuid, p_role uuid, p_active boolean)
returns void language plpgsql security definer set search_path = public as $$
declare m memberships; owners int; new_role text;
begin
  select * into m from memberships where id = p_membership;
  if not found or not has_perm(m.tenant_id, 'core.user.manage') then raise exception 'Not allowed'; end if;
  if m.user_id = auth.uid() then raise exception 'You can''t change your own access'; end if;
  select name into new_role from roles where id = p_role and (tenant_id is null or tenant_id = m.tenant_id);
  if new_role is null then raise exception 'Unknown role'; end if;
  if (select name from roles where id = m.role_id) = 'Owner' or new_role = 'Owner' then
    if not exists (select 1 from memberships x join roles o on o.id = x.role_id
                   where x.tenant_id = m.tenant_id and x.user_id = auth.uid() and o.name = 'Owner') then
      raise exception 'Only an owner can change an owner';
    end if;
  end if;
  update memberships set role_id = p_role, active = p_active where id = m.id;
  select count(*) into owners from memberships x join roles o on o.id = x.role_id
    where x.tenant_id = m.tenant_id and o.name = 'Owner' and x.active;
  if owners = 0 then raise exception 'A business needs at least one active owner'; end if;
end $$;

-- ===== Permissions & roles =====
insert into public.permissions (code, module, description) values
  ('kids.view','KIDS','See children, attendance and daily logs'),
  ('kids.manage','KIDS','Enrol children, manage guardians, rooms, fees and settings'),
  ('kids.checkin','KIDS','Check children in and out'),
  ('kids.log','KIDS','Write daily logs, photos and medicine doses'),
  ('kids.incident','KIDS','Report incidents'),
  ('kids.billing','KIDS','Create monthly fee invoices'),
  ('kids.parent','KIDS','Parent access to their own children');

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r join public.permissions p on p.module = 'KIDS' and p.code <> 'kids.parent'
where r.tenant_id is null and r.name in ('Owner','Admin','Manager')
on conflict do nothing;
insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r, unnest(array['kids.view','kids.checkin','kids.log','kids.incident']) c
where r.tenant_id is null and r.name = 'Carer'
on conflict do nothing;
insert into public.role_permissions (role_id, permission_code)
select r.id, 'kids.billing' from public.roles r where r.tenant_id is null and r.name = 'Accountant'
on conflict do nothing;
insert into public.role_permissions (role_id, permission_code)
select r.id, 'kids.parent' from public.roles r where r.tenant_id is null and r.name = 'Parent'
on conflict do nothing;

-- ===== Settings, rooms, fee plans =====
create table public.kids_settings (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  centre_type text not null default 'taska' check (centre_type in ('taska','tadika','after_school','other')),
  opening_time time not null default '07:00',
  closing_time time not null default '18:30',
  late_fee numeric(10,2) not null default 0,          -- per block after closing
  late_block_minutes int not null default 15 check (late_block_minutes > 0),
  late_grace_minutes int not null default 5,
  notify_checkin boolean not null default true,       -- message parents on check-in / check-out
  invoice_day int not null default 1 check (invoice_day between 1 and 28),
  due_days int not null default 7,
  updated_at timestamptz not null default now()
);

create table public.kids_fee_plans (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  monthly_fee numeric(12,2) not null check (monthly_fee >= 0),
  registration_fee numeric(12,2) not null default 0,
  deposit numeric(12,2) not null default 0,
  sibling_discount_pct numeric(5,2) not null default 0 check (sibling_discount_pct between 0 and 100),
  active boolean not null default true,
  unique (tenant_id, name)
);

create table public.kids_rooms (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  outlet_id uuid references public.outlets(id),
  name text not null,
  min_age_months int not null default 0,
  max_age_months int not null default 48,
  ratio_children int not null check (ratio_children > 0),   -- children per carer
  capacity int,
  active boolean not null default true,
  unique (tenant_id, name)
);

-- Ratio by the youngest age group in the room
create or replace function public.default_ratio(p_max_age_months int, p_type text default 'taska')
returns int language sql immutable as $$
  select case
    when p_max_age_months <= 12 then 3
    when p_max_age_months <= 36 then 5
    when p_max_age_months <= 60 then 10
    else 15 end;
$$;

-- ===== Children & guardians =====
create table public.kids_counters (tenant_id uuid primary key references public.tenants(id) on delete cascade, next_no int not null default 1);

create table public.children (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  outlet_id uuid references public.outlets(id),
  room_id uuid references public.kids_rooms(id) on delete set null,
  child_no text,
  full_name text not null,
  preferred_name text,
  dob date not null,
  gender text check (gender in ('male','female')),
  photo_path text,
  status text not null default 'enrolled' check (status in ('enquiry','waitlist','enrolled','withdrawn')),
  start_date date,
  end_date date,
  days int[] not null default '{1,2,3,4,5}',            -- ISO weekdays attended
  allergies text,                                       -- shown to every carer
  dietary text,
  medical_conditions text,
  photo_consent boolean not null default false,
  fee_plan_id uuid references public.kids_fee_plans(id),
  registration_invoice_id uuid references public.invoices(id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  unique (tenant_id, child_no)
);
create index on public.children (tenant_id, status, room_id);

-- Identity and contact details: managers and the child's own guardians only
create table public.child_private (
  child_id uuid primary key references public.children(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  id_no text,                                           -- MyKid / birth certificate / passport
  address text,
  doctor_name text,
  doctor_phone text,
  immunisation_note text
);

create table public.guardians (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  full_name text not null,
  phone text,
  email text,
  id_last4 text check (id_last4 is null or id_last4 ~ '^[0-9A-Za-z]{4}$'),   -- checked at pick-up
  user_id uuid references auth.users(id) on delete set null,
  contact_id uuid references public.contacts(id) on delete set null,      -- for invoices
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index on public.guardians (tenant_id, lower(email)) where email is not null;

create table public.child_guardians (
  child_id uuid not null references public.children(id) on delete cascade,
  guardian_id uuid not null references public.guardians(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  relation text not null default 'parent',
  is_primary boolean not null default false,
  can_pickup boolean not null default true,
  pays_fees boolean not null default false,
  receives_updates boolean not null default true,
  emergency_contact boolean not null default true,
  primary key (child_id, guardian_id)
);
create index on public.child_guardians (guardian_id);

-- Pick-up PINs are never readable, only checked
create table public.guardian_pins (
  guardian_id uuid primary key references public.guardians(id) on delete cascade,
  pin_hash text not null,
  set_at timestamptz not null default now()
);

-- One-off or temporary pick-up people (e.g. grandma on Friday)
create table public.pickup_persons (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  full_name text not null,
  phone text,
  id_last4 text,
  relation text,
  valid_from date not null default current_date,
  valid_to date not null default current_date,
  added_by uuid default auth.uid(),
  added_by_guardian uuid references public.guardians(id),
  created_at timestamptz not null default now(),
  check (valid_to >= valid_from)
);

-- ===== Attendance, absences, staff on duty =====
create table public.kids_attendance (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  day date not null,
  room_id uuid references public.kids_rooms(id) on delete set null,
  check_in_at timestamptz,
  check_in_by uuid,
  dropped_by text,
  temperature numeric(4,1),
  check_in_note text,
  check_out_at timestamptz,
  check_out_by uuid,
  picked_up_by text,
  pickup_guardian_id uuid references public.guardians(id),
  pickup_person_id uuid references public.pickup_persons(id),
  pickup_method text check (pickup_method in ('guardian','authorised','pin','override')),
  override_reason text,
  late_minutes int not null default 0,
  pin_failures int not null default 0,
  late_fee numeric(10,2) not null default 0,
  late_fee_invoice_id uuid references public.invoices(id) on delete set null,
  status text not null default 'present' check (status in ('present','absent','sick','holiday')),
  absence_reason text,
  unique (child_id, day)
);
create index on public.kids_attendance (tenant_id, day);

create table public.kids_absences (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  from_date date not null,
  to_date date not null,
  reason text not null default 'other' check (reason in ('sick','holiday','family','other')),
  note text,
  reported_by uuid default auth.uid(),
  reported_by_guardian uuid references public.guardians(id),
  created_at timestamptz not null default now(),
  check (to_date >= from_date)
);

create table public.kids_staff_duty (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  room_id uuid not null references public.kids_rooms(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  staff_name text,
  start_at timestamptz not null default now(),
  end_at timestamptz
);
create unique index kids_one_duty on public.kids_staff_duty (tenant_id, user_id) where end_at is null;

-- ===== Daily logs, medicine, incidents, messages =====
create table public.kids_logs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  at timestamptz not null default now(),
  kind text not null check (kind in ('meal','drink','nap','nappy','toilet','mood','activity','milestone','health','medication','note','photo')),
  detail jsonb not null default '{}',     -- meal {item, amount}, nap {start, end}, nappy {type}, mood {mood}, health {temperature}
  note text,
  photo_path text,
  visible_to_parents boolean not null default true,
  by_user uuid default auth.uid(),
  by_name text,
  created_at timestamptz not null default now()
);
create index on public.kids_logs (child_id, at desc);

create table public.kids_med_authorisations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  medicine text not null,
  dose text not null,
  route text not null default 'oral',
  times text not null,                       -- e.g. "12:00 and 16:00" or "when temperature ≥ 38°C"
  reason text,
  min_hours_between numeric(4,1) not null default 4,
  max_doses_per_day int not null default 3,
  start_date date not null default current_date,
  end_date date not null,
  guardian_id uuid references public.guardians(id),     -- who authorised
  authorised_via text not null default 'app' check (authorised_via in ('app','paper')),
  status text not null default 'active' check (status in ('active','stopped')),
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  check (end_date >= start_date and end_date <= start_date + 90)
);

create table public.kids_med_given (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  authorisation_id uuid not null references public.kids_med_authorisations(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  given_at timestamptz not null default now(),
  dose text not null,
  given_by uuid default auth.uid(),
  given_by_name text,
  witness_name text,
  note text
);

create table public.kids_incidents (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  occurred_at timestamptz not null,
  kind text not null check (kind in ('injury','illness','allergic_reaction','behaviour','near_miss','safeguarding','other')),
  severity text not null default 'low' check (severity in ('low','medium','high')),
  location text,
  description text not null,
  first_aid text,
  action_taken text,
  witnesses text,
  reported_by uuid default auth.uid(),
  reported_by_name text,
  parent_notified_at timestamptz,
  parent_notified_how text,
  guardian_ack_at timestamptz,
  guardian_ack_by uuid references public.guardians(id),
  guardian_ack_note text,
  status text not null default 'open' check (status in ('open','closed')),
  closed_note text,
  created_at timestamptz not null default now()
);
create index on public.kids_incidents (tenant_id, occurred_at desc);

create table public.kids_messages (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  from_user uuid default auth.uid(),
  from_name text,
  from_parent boolean not null default false,
  body text not null check (length(body) between 1 and 2000),
  at timestamptz not null default now(),
  read_at timestamptz
);
create index on public.kids_messages (child_id, at desc);

create table public.kids_extra_charges (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  child_id uuid not null references public.children(id) on delete cascade,
  description text not null,
  amount numeric(12,2) not null check (amount > 0),
  charge_date date not null default current_date,
  invoice_id uuid references public.invoices(id) on delete set null,
  created_by uuid default auth.uid()
);

create table public.kids_fee_invoices (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  guardian_id uuid not null references public.guardians(id) on delete cascade,
  period date not null,                          -- first day of the month billed
  invoice_id uuid not null references public.invoices(id) on delete cascade,
  primary key (tenant_id, guardian_id, period)
);

-- ===== Helpers =====
create or replace function public.is_guardian_of(p_child uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from child_guardians cg join guardians g on g.id = cg.guardian_id
                 where cg.child_id = p_child and g.user_id = auth.uid() and g.active);
$$;

create or replace function public.my_guardian_id(p_child uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select g.id from child_guardians cg join guardians g on g.id = cg.guardian_id
  where cg.child_id = p_child and g.user_id = auth.uid() and g.active limit 1;
$$;

create or replace function public.my_name(p_tenant uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(
    (select full_name from employees where tenant_id = p_tenant and user_id = auth.uid() limit 1),
    (select full_name from guardians where tenant_id = p_tenant and user_id = auth.uid() limit 1),
    (select split_part(email, '@', 1) from auth.users where id = auth.uid()));
$$;

create or replace function public.tenant_tz(p_tenant uuid, p_outlet uuid default null)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select timezone from outlets where id = p_outlet),
                  (select timezone from outlets where tenant_id = p_tenant order by created_at limit 1),
                  'Asia/Kuala_Lumpur');
$$;

create or replace function public.local_today(p_tenant uuid, p_outlet uuid default null)
returns date language sql stable as $$ select (now() at time zone tenant_tz(p_tenant, p_outlet))::date $$;

-- Queue a message to every guardian of a child who gets updates (email first, else WhatsApp)
create or replace function public.notify_guardians(p_child uuid, p_subject text, p_body text, p_all boolean default false)
returns int language plpgsql security definer set search_path = public as $$
declare c children; g record; n int := 0;
begin
  select * into c from children where id = p_child;
  for g in select gu.* from child_guardians cg join guardians gu on gu.id = cg.guardian_id
           where cg.child_id = p_child and gu.active
             and (cg.receives_updates or (p_all and (cg.is_primary or cg.can_pickup)))
             and (gu.email is not null or gu.phone is not null) loop
    insert into outbound_messages (tenant_id, channel, to_address, subject, body)
    values (c.tenant_id, case when g.email is not null then 'email' else 'whatsapp' end,
            coalesce(lower(g.email), norm_phone(g.phone)), p_subject, p_body);
    n := n + 1;
  end loop;
  return n;
end $$;

create or replace function public.child_before()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.child_no is null then
    insert into kids_counters (tenant_id) values (new.tenant_id) on conflict do nothing;
    update kids_counters set next_no = next_no + 1 where tenant_id = new.tenant_id
      returning 'K' || lpad((next_no - 1)::text, 4, '0') into new.child_no;
  end if;
  if new.dob > current_date then raise exception 'Date of birth is in the future'; end if;
  if new.end_date is not null and new.start_date is not null and new.end_date < new.start_date then
    raise exception 'End date is before start date';
  end if;
  if new.status = 'withdrawn' and new.end_date is null then new.end_date := current_date; end if;
  return new;
end $$;
create trigger trg_child_before before insert or update on public.children for each row execute function public.child_before();

create or replace function public.guardian_before()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.email := lower(nullif(trim(new.email), ''));
  new.phone := nullif(trim(new.phone), '');
  if tg_op = 'UPDATE' and new.email is distinct from old.email then new.user_id := null; end if;
  return new;
end $$;
create trigger trg_guardian_before before insert or update on public.guardians for each row execute function public.guardian_before();

-- Give a guardian the parent app (invitation by email; links on their next sign-in)
create or replace function public.invite_guardian(p_guardian uuid)
returns void language plpgsql security definer set search_path = public as $$
declare g guardians; prole uuid; c text;
begin
  select * into g from guardians where id = p_guardian;
  if not found or not has_perm(g.tenant_id, 'kids.manage') then raise exception 'Not allowed'; end if;
  if g.email is null then raise exception 'Add the guardian''s email first'; end if;
  select id into prole from roles where tenant_id is null and name = 'Parent';
  insert into invites (tenant_id, email, role_id) values (g.tenant_id, g.email, prole)
  on conflict (tenant_id, email) do nothing;
  -- if they already have a login, link it now
  update guardians set user_id = (select id from auth.users where lower(email) = g.email and email_confirmed_at is not null)
  where id = g.id and user_id is null;
  select name into c from tenants where id = g.tenant_id;
  insert into outbound_messages (tenant_id, channel, to_address, subject, body)
  values (g.tenant_id, 'email', g.email, c || ' — parent app',
          'Hi ' || split_part(g.full_name, ' ', 1) || ', ' || c || ' has invited you to the Ai buddy Biz parent app. '
          || 'Install the app and sign up with this email (' || g.email || ') to see check-ins, daily updates and photos.');
end $$;

-- ===== Check-in / check-out =====
create or replace function public.kids_check_in(p_child uuid, p_dropped_by text default null, p_temperature numeric default null, p_note text default null)
returns public.kids_attendance language plpgsql security definer set search_path = public as $$
declare c children; a kids_attendance; d date; st kids_settings;
begin
  select * into c from children where id = p_child;
  if not found or not has_perm(c.tenant_id, 'kids.checkin') then raise exception 'Not allowed'; end if;
  if c.status <> 'enrolled' then raise exception '% is not enrolled', c.full_name; end if;
  d := local_today(c.tenant_id, c.outlet_id);
  select * into a from kids_attendance where child_id = c.id and day = d;
  if a.check_in_at is not null and a.check_out_at is null then raise exception '% is already checked in', c.full_name; end if;
  if a.check_out_at is not null then raise exception '% was already picked up today', c.full_name; end if;
  if p_temperature is not null and (p_temperature < 34 or p_temperature > 43) then raise exception 'Check the temperature reading'; end if;
  insert into kids_attendance (tenant_id, child_id, day, room_id, check_in_at, check_in_by, dropped_by, temperature, check_in_note, status)
  values (c.tenant_id, c.id, d, c.room_id, now(), auth.uid(), nullif(trim(p_dropped_by),''), p_temperature, nullif(trim(p_note),''), 'present')
  on conflict (child_id, day) do update set check_in_at = now(), check_in_by = auth.uid(), dropped_by = excluded.dropped_by,
    temperature = excluded.temperature, check_in_note = excluded.check_in_note, status = 'present', absence_reason = null,
    room_id = excluded.room_id
  returning * into a;
  if p_temperature is not null then
    insert into kids_logs (tenant_id, child_id, kind, detail, note, by_name)
    values (c.tenant_id, c.id, 'health', jsonb_build_object('temperature', p_temperature),
            case when p_temperature >= 37.5 then 'Temperature on arrival is raised' end, my_name(c.tenant_id));
  end if;
  select * into st from kids_settings where tenant_id = c.tenant_id;
  if coalesce(st.notify_checkin, true) then
    perform notify_guardians(c.id, coalesce(c.preferred_name, c.full_name) || ' checked in',
      coalesce(c.preferred_name, c.full_name) || ' arrived at ' || to_char(now() at time zone tenant_tz(c.tenant_id, c.outlet_id), 'HH24:MI')
      || coalesce(' (dropped off by ' || nullif(trim(p_dropped_by),'') || ')', '') || '.');
  end if;
  return a;
end $$;

-- Pick-up must be a guardian allowed to collect, a person authorised for today, or a guardian's PIN.
-- Anyone else needs a manager override with a reason, and every guardian is told.
-- Returns {ok, error?, attendance?}. A wrong PIN is counted (5 wrong PINs lock PIN pick-up for the day).
create or replace function public.kids_check_out(p_child uuid, p_guardian uuid default null, p_person uuid default null,
                                                p_pin text default null, p_override_name text default null, p_override_reason text default null,
                                                p_id_last4 text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare c children; a kids_attendance; g guardians; pp pickup_persons; st kids_settings; d date; who text; method text;
        tz text; local_close timestamptz; mins int := 0; fee numeric := 0; pg uuid; ppid uuid;
begin
  select * into c from children where id = p_child;
  if not found or not has_perm(c.tenant_id, 'kids.checkin') then raise exception 'Not allowed'; end if;
  d := local_today(c.tenant_id, c.outlet_id);
  select * into a from kids_attendance where child_id = c.id and day = d for update;
  if a.check_in_at is null then raise exception '% is not checked in today', c.full_name; end if;
  if a.check_out_at is not null then raise exception '% was already picked up', c.full_name; end if;

  if p_guardian is not null then
    select gu.* into g from guardians gu join child_guardians cg on cg.guardian_id = gu.id
    where gu.id = p_guardian and cg.child_id = c.id and cg.can_pickup and gu.active;
    if not found then raise exception 'This person is not allowed to collect %', c.full_name; end if;
    if p_id_last4 is not null and g.id_last4 is not null and upper(p_id_last4) <> upper(g.id_last4) then
      raise exception 'ID digits don''t match — do not release the child; call the parent';
    end if;
    who := g.full_name; method := 'guardian'; pg := g.id;
  elsif p_person is not null then
    select * into pp from pickup_persons where id = p_person and child_id = c.id and d between valid_from and valid_to;
    if not found then raise exception 'This person is not authorised to collect % today', c.full_name; end if;
    if pp.id_last4 is not null and (p_id_last4 is null or upper(p_id_last4) <> upper(pp.id_last4)) then
      raise exception 'Check their IC/passport: the last 4 characters must match before release';
    end if;
    who := pp.full_name; method := 'authorised'; ppid := pp.id;
  elsif p_pin is not null then
    if a.pin_failures >= 5 then raise exception 'PIN pick-up is locked after 5 wrong tries — check ID or call the parent'; end if;
    select gu.* into g from guardians gu join child_guardians cg on cg.guardian_id = gu.id join guardian_pins gp on gp.guardian_id = gu.id
    where cg.child_id = c.id and cg.can_pickup and gu.active
      and gp.pin_hash = encode(sha256(convert_to(gu.id::text || ':' || p_pin, 'UTF8')), 'hex')
    limit 1;
    if not found then
      update kids_attendance set pin_failures = pin_failures + 1 where id = a.id;
      return jsonb_build_object('ok', false, 'error', 'Wrong PIN (' || (a.pin_failures + 1) || ' of 5 tries)');
    end if;
    who := g.full_name || ' (PIN)'; method := 'pin'; pg := g.id;
  else
    if not has_perm(c.tenant_id, 'kids.manage') then
      raise exception 'Only a manager can release a child to someone not on the list';
    end if;
    if coalesce(trim(p_override_name),'') = '' or coalesce(length(trim(p_override_reason)),0) < 5 then
      raise exception 'Enter who collected the child and why they are not on the list';
    end if;
    who := trim(p_override_name); method := 'override';
  end if;

  select * into st from kids_settings where tenant_id = c.tenant_id;
  tz := tenant_tz(c.tenant_id, c.outlet_id);
  if st.tenant_id is not null then
    local_close := (d + st.closing_time) at time zone tz;
    mins := greatest(0, floor(extract(epoch from now() - local_close) / 60)::int);
    if mins <= st.late_grace_minutes then
      mins := 0;
    elsif st.late_fee > 0 then
      fee := ceil(mins::numeric / st.late_block_minutes) * st.late_fee;
    end if;
  end if;

  update kids_attendance set check_out_at = now(), check_out_by = auth.uid(), picked_up_by = who,
    pickup_guardian_id = pg, pickup_person_id = ppid, pickup_method = method,
    override_reason = case when method = 'override' then trim(p_override_reason) end,
    late_minutes = mins, late_fee = fee
  where id = a.id returning * into a;

  if method = 'override' then
    perform notify_guardians(c.id, 'Pick-up alert: ' || coalesce(c.preferred_name, c.full_name),
      coalesce(c.preferred_name, c.full_name) || ' was collected by ' || who || ', who is not on your pick-up list. Reason recorded: '
      || trim(p_override_reason) || '. Call the centre immediately if you did not agree to this.', true);
  elsif coalesce(st.notify_checkin, true) then
    perform notify_guardians(c.id, coalesce(c.preferred_name, c.full_name) || ' picked up',
      coalesce(c.preferred_name, c.full_name) || ' was collected by ' || who || ' at '
      || to_char(now() at time zone tz, 'HH24:MI') || '.');
  end if;
  return jsonb_build_object('ok', true, 'attendance', to_jsonb(a));
end $$;

-- Parent / staff mark a child absent (one row per day). Not for days already attended.
create or replace function public.report_absence(p_child uuid, p_from date, p_to date, p_reason text, p_note text default null)
returns int language plpgsql security definer set search_path = public as $$
declare c children; gid uuid; d date; n int := 0;
begin
  select * into c from children where id = p_child;
  if not found then raise exception 'Unknown child'; end if;
  gid := my_guardian_id(c.id);
  if gid is null and not has_perm(c.tenant_id, 'kids.checkin') then raise exception 'Not allowed'; end if;
  if p_to < p_from or p_to > p_from + 60 then raise exception 'Choose up to 60 days'; end if;
  if p_reason not in ('sick','holiday','family','other') then raise exception 'Unknown reason'; end if;
  insert into kids_absences (tenant_id, child_id, from_date, to_date, reason, note, reported_by_guardian)
  values (c.tenant_id, c.id, p_from, p_to, p_reason, left(p_note, 500), gid);
  for d in select generate_series(p_from, p_to, interval '1 day')::date loop
    if extract(isodow from d)::int = any(c.days) then
      insert into kids_attendance (tenant_id, child_id, day, room_id, status, absence_reason)
      values (c.tenant_id, c.id, d, c.room_id, case when p_reason = 'sick' then 'sick' when p_reason = 'holiday' then 'holiday' else 'absent' end,
              coalesce(p_note, p_reason))
      on conflict (child_id, day) do nothing;
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ===== Staff on duty & ratios =====
create or replace function public.kids_start_duty(p_room uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare r kids_rooms; did uuid;
begin
  select * into r from kids_rooms where id = p_room;
  if not found or not has_perm(r.tenant_id, 'kids.checkin') then raise exception 'Not allowed'; end if;
  update kids_staff_duty set end_at = now() where tenant_id = r.tenant_id and user_id = auth.uid() and end_at is null;
  insert into kids_staff_duty (tenant_id, room_id, staff_name) values (r.tenant_id, r.id, my_name(r.tenant_id)) returning id into did;
  return did;
end $$;

create or replace function public.kids_end_duty(p_tenant uuid)
returns void language sql security definer set search_path = public as $$
  update kids_staff_duty set end_at = now() where tenant_id = p_tenant and user_id = auth.uid() and end_at is null;
$$;

create or replace function public.kids_ratio(p_tenant uuid)
returns table (room_id uuid, room_name text, ratio_children int, children_present int, carers_on_duty int,
               carers_needed int, ok boolean, capacity int)
language sql stable security definer set search_path = public as $$
  select r.id, r.name, r.ratio_children,
    coalesce(p.n, 0)::int,
    coalesce(s.n, 0)::int,
    ceil(coalesce(p.n, 0)::numeric / r.ratio_children)::int,
    coalesce(s.n, 0) >= ceil(coalesce(p.n, 0)::numeric / r.ratio_children),
    r.capacity
  from kids_rooms r
  left join (select a.room_id, count(*) n from kids_attendance a
             where a.tenant_id = p_tenant and a.day = local_today(p_tenant) and a.check_in_at is not null and a.check_out_at is null
             group by a.room_id) p on p.room_id = r.id
  left join (select d.room_id, count(*) n from kids_staff_duty d where d.tenant_id = p_tenant and d.end_at is null group by d.room_id) s
    on s.room_id = r.id
  where r.tenant_id = p_tenant and r.active and has_perm(p_tenant, 'kids.view')
  order by r.min_age_months, r.name;
$$;

-- ===== Daily logs =====
create or replace function public.kids_log_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare c children;
begin
  select * into c from children where id = new.child_id;
  new.tenant_id := c.tenant_id;
  new.by_name := coalesce(new.by_name, my_name(c.tenant_id));
  if new.photo_path is not null and not c.photo_consent then
    raise exception 'No photo consent for % — ask the parent to agree in the app first', c.full_name;
  end if;
  if new.photo_path is not null and new.photo_path not like c.tenant_id::text || '/' || c.id::text || '/%' then
    raise exception 'Photo is stored in the wrong place';
  end if;
  return new;
end $$;
create trigger trg_kids_log_before before insert or update on public.kids_logs for each row execute function public.kids_log_before();

-- ===== Medicine =====
create or replace function public.authorise_medicine(p_child uuid, p_medicine text, p_dose text, p_times text, p_reason text,
                                                     p_start date, p_end date, p_min_hours numeric default 4, p_max_per_day int default 3,
                                                     p_paper_guardian uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare c children; gid uuid; via text; rid uuid;
begin
  select * into c from children where id = p_child;
  if not found then raise exception 'Unknown child'; end if;
  gid := my_guardian_id(c.id);
  if gid is not null then
    via := 'app';
  elsif has_perm(c.tenant_id, 'kids.manage') and p_paper_guardian is not null
        and exists (select 1 from child_guardians where child_id = c.id and guardian_id = p_paper_guardian) then
    gid := p_paper_guardian; via := 'paper';            -- staff record a signed paper form
  else
    raise exception 'Only a parent/guardian (or a manager recording their signed form) can authorise medicine';
  end if;
  if coalesce(trim(p_medicine),'') = '' or coalesce(trim(p_dose),'') = '' or coalesce(trim(p_times),'') = '' then
    raise exception 'Medicine, dose and times are required';
  end if;
  insert into kids_med_authorisations (tenant_id, child_id, medicine, dose, times, reason, start_date, end_date,
    min_hours_between, max_doses_per_day, guardian_id, authorised_via)
  values (c.tenant_id, c.id, trim(p_medicine), trim(p_dose), trim(p_times), p_reason, p_start, p_end,
    coalesce(p_min_hours, 4), coalesce(p_max_per_day, 3), gid, via)
  returning id into rid;
  return rid;
end $$;

create or replace function public.give_medicine(p_auth uuid, p_dose text default null, p_witness text default null, p_note text default null, p_force boolean default false)
returns uuid language plpgsql security definer set search_path = public as $$
declare m kids_med_authorisations; c children; last_at timestamptz; today_n int; gid uuid; d date; tz text;
begin
  select * into m from kids_med_authorisations where id = p_auth for update;
  if not found or not has_perm(m.tenant_id, 'kids.log') then raise exception 'Not allowed'; end if;
  select * into c from children where id = m.child_id;
  tz := tenant_tz(c.tenant_id, c.outlet_id);
  d := (now() at time zone tz)::date;
  if m.status <> 'active' or d not between m.start_date and m.end_date then
    raise exception 'No valid parent authorisation for today — do not give the medicine';
  end if;
  select max(given_at), count(*) filter (where (given_at at time zone tz)::date = d) into last_at, today_n
  from kids_med_given where authorisation_id = m.id;
  if today_n >= m.max_doses_per_day then raise exception 'Already given % time(s) today — the maximum allowed', today_n; end if;
  if last_at is not null and now() - last_at < make_interval(mins => (m.min_hours_between * 60)::int) and not p_force then
    raise exception 'Last dose was at % — less than % hours ago', to_char(last_at at time zone tz, 'HH24:MI'), m.min_hours_between;
  end if;
  if p_force and not has_perm(m.tenant_id, 'kids.manage') then raise exception 'Only a manager can override the dose interval'; end if;
  insert into kids_med_given (tenant_id, authorisation_id, child_id, dose, given_by_name, witness_name, note)
  values (m.tenant_id, m.id, m.child_id, coalesce(nullif(trim(p_dose),''), m.dose), my_name(m.tenant_id), p_witness, p_note)
  returning id into gid;
  insert into kids_logs (tenant_id, child_id, kind, detail, note)
  values (m.tenant_id, m.child_id, 'medication', jsonb_build_object('medicine', m.medicine, 'dose', coalesce(nullif(trim(p_dose),''), m.dose)),
          coalesce(p_note, 'Given as authorised'));
  return gid;
end $$;

-- ===== Incidents =====
create or replace function public.report_incident(p_child uuid, p_occurred timestamptz, p_kind text, p_severity text, p_description text,
                                                  p_location text default null, p_first_aid text default null, p_action text default null,
                                                  p_witnesses text default null, p_notify boolean default true)
returns uuid language plpgsql security definer set search_path = public as $$
declare c children; iid uuid;
begin
  select * into c from children where id = p_child;
  if not found or not has_perm(c.tenant_id, 'kids.incident') then raise exception 'Not allowed'; end if;
  if coalesce(length(trim(p_description)),0) < 10 then raise exception 'Describe what happened'; end if;
  if p_occurred > now() + interval '5 minutes' then raise exception 'The time is in the future'; end if;
  insert into kids_incidents (tenant_id, child_id, occurred_at, kind, severity, location, description, first_aid, action_taken, witnesses, reported_by_name)
  values (c.tenant_id, c.id, p_occurred, p_kind, p_severity, p_location, trim(p_description), p_first_aid, p_action, p_witnesses, my_name(c.tenant_id))
  returning id into iid;
  -- Safeguarding concerns are never sent to guardians automatically
  if p_notify and p_kind <> 'safeguarding' then
    perform notify_guardians(c.id, 'Incident report: ' || coalesce(c.preferred_name, c.full_name),
      'There was ' || case p_severity when 'high' then 'a serious ' else 'an ' end || replace(p_kind, '_', ' ') || ' incident involving '
      || coalesce(c.preferred_name, c.full_name) || ' at ' || to_char(p_occurred at time zone tenant_tz(c.tenant_id, c.outlet_id), 'HH24:MI')
      || '. Please open the app to read and acknowledge the report.', true);
    update kids_incidents set parent_notified_at = now(), parent_notified_how = 'app + message' where id = iid;
  end if;
  return iid;
end $$;

create or replace function public.ack_incident(p_incident uuid, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare i kids_incidents; gid uuid;
begin
  select * into i from kids_incidents where id = p_incident;
  if not found or i.kind = 'safeguarding' then raise exception 'Unknown incident'; end if;
  gid := my_guardian_id(i.child_id);
  if gid is null then raise exception 'Only the child''s guardian can acknowledge'; end if;
  update kids_incidents set guardian_ack_at = now(), guardian_ack_by = gid, guardian_ack_note = left(p_note, 1000)
  where id = i.id and guardian_ack_at is null;
end $$;

-- ===== Parent actions =====
create or replace function public.parent_add_pickup(p_child uuid, p_name text, p_phone text, p_id_last4 text, p_relation text, p_from date, p_to date)
returns uuid language plpgsql security definer set search_path = public as $$
declare c children; gid uuid; pid uuid;
begin
  select * into c from children where id = p_child;
  gid := my_guardian_id(p_child);
  if gid is null and not has_perm(c.tenant_id, 'kids.manage') then raise exception 'Not allowed'; end if;
  if coalesce(length(trim(p_name)),0) < 3 then raise exception 'Enter the person''s full name'; end if;
  if p_id_last4 is null or p_id_last4 !~ '^[0-9A-Za-z]{4}$' then raise exception 'Enter the last 4 characters of their IC or passport'; end if;
  if p_to < p_from or p_to > p_from + 30 or p_from < current_date then raise exception 'Choose dates from today, up to 30 days'; end if;
  insert into pickup_persons (tenant_id, child_id, full_name, phone, id_last4, relation, valid_from, valid_to, added_by_guardian)
  values (c.tenant_id, c.id, trim(p_name), nullif(trim(p_phone),''), upper(p_id_last4), p_relation, p_from, p_to, gid)
  returning id into pid;
  return pid;
end $$;

create or replace function public.set_pickup_pin(p_tenant uuid, p_pin text)
returns void language plpgsql security definer set search_path = public as $$
declare g guardians;
begin
  if p_pin !~ '^[0-9]{6}$' then raise exception 'Use 6 digits'; end if;
  if p_pin ~ '^(\d)\1{5}$' or p_pin in ('123456','654321','012345') then raise exception 'Choose a less obvious PIN'; end if;
  select * into g from guardians where tenant_id = p_tenant and user_id = auth.uid() and active limit 1;
  if not found then raise exception 'Your login is not linked to a guardian record'; end if;
  insert into guardian_pins (guardian_id, pin_hash) values (g.id, encode(sha256(convert_to(g.id::text || ':' || p_pin, 'UTF8')), 'hex'))
  on conflict (guardian_id) do update set pin_hash = excluded.pin_hash, set_at = now();
end $$;

create or replace function public.set_photo_consent(p_child uuid, p_consent boolean)
returns void language plpgsql security definer set search_path = public as $$
begin
  if my_guardian_id(p_child) is null then raise exception 'Only a guardian can change photo consent'; end if;
  update children set photo_consent = p_consent where id = p_child;
end $$;

create or replace function public.send_kids_message(p_child uuid, p_body text)
returns uuid language plpgsql security definer set search_path = public as $$
declare c children; parent boolean; mid uuid;
begin
  select * into c from children where id = p_child;
  if not found then raise exception 'Unknown child'; end if;
  parent := my_guardian_id(c.id) is not null;
  if not parent and not has_perm(c.tenant_id, 'kids.log') then raise exception 'Not allowed'; end if;
  insert into kids_messages (tenant_id, child_id, from_name, from_parent, body)
  values (c.tenant_id, c.id, my_name(c.tenant_id), parent, trim(p_body)) returning id into mid;
  return mid;
end $$;

create or replace function public.mark_kids_messages_read(p_child uuid)
returns void language plpgsql security definer set search_path = public as $$
declare c children; parent boolean;
begin
  select * into c from children where id = p_child;
  parent := my_guardian_id(c.id) is not null;
  if not parent and not has_perm(c.tenant_id, 'kids.view') then raise exception 'Not allowed'; end if;
  -- each side marks the other side's messages as read
  update kids_messages set read_at = now() where child_id = c.id and read_at is null and from_parent = not parent;
end $$;

-- The parent's view: their children with today's status
create or replace function public.my_children()
returns table (child_id uuid, tenant_id uuid, business text, full_name text, preferred_name text, dob date, room text, photo_path text,
               photo_consent boolean, guardian_id uuid, today_status text, check_in_at timestamptz, check_out_at timestamptz,
               picked_up_by text, unread int)
language sql stable security definer set search_path = public as $$
  select c.id, c.tenant_id, t.name, c.full_name, c.preferred_name, c.dob, r.name, c.photo_path, c.photo_consent, g.id,
         coalesce(case when a.check_out_at is not null then 'picked_up' when a.check_in_at is not null then 'in' else a.status end, 'not_in'),
         a.check_in_at, a.check_out_at, a.picked_up_by,
         (select count(*) from kids_messages m where m.child_id = c.id and not m.from_parent and m.read_at is null)::int
  from guardians g
  join child_guardians cg on cg.guardian_id = g.id
  join children c on c.id = cg.child_id and c.status = 'enrolled'
  join tenants t on t.id = c.tenant_id
  left join kids_rooms r on r.id = c.room_id
  left join kids_attendance a on a.child_id = c.id and a.day = local_today(c.tenant_id, c.outlet_id)
  where g.user_id = auth.uid() and g.active
  order by c.full_name;
$$;

-- ===== Monthly fees → invoices (FIN) =====
create or replace function public.guardian_contact(p_guardian uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare g guardians; cid uuid;
begin
  select * into g from guardians where id = p_guardian;
  if g.contact_id is not null then return g.contact_id; end if;
  insert into contacts (tenant_id, kind, name, email, phone, lifecycle, source)
  values (g.tenant_id, 'customer', g.full_name, g.email, g.phone, 'customer', 'kids care')
  returning id into cid;
  update guardians set contact_id = cid where id = g.id;
  return cid;
end $$;

create or replace function public.generate_kids_invoices(p_tenant uuid, p_month date, p_issue boolean default false)
returns jsonb language plpgsql security definer set search_path = public as $$
declare per date := date_trunc('month', p_month)::date; per_end date; payer record; ch record; inv_id uuid; n_inv int := 0; n_lines int;
        st kids_settings; cur char(3); sib int; amt numeric; skipped int := 0; issued int := 0; v_total numeric := 0; lf record; ex record;
begin
  if not has_perm(p_tenant, 'kids.billing') then raise exception 'Not allowed'; end if;
  per_end := (per + interval '1 month - 1 day')::date;
  select * into st from kids_settings where tenant_id = p_tenant;
  select base_currency into cur from tenants where id = p_tenant;

  -- one invoice per paying guardian (falls back to the primary guardian)
  for payer in
    select distinct on (gid) gid from (
      select coalesce(
        (select cg.guardian_id from child_guardians cg where cg.child_id = c.id and cg.pays_fees order by cg.is_primary desc limit 1),
        (select cg.guardian_id from child_guardians cg where cg.child_id = c.id order by cg.is_primary desc limit 1)) gid
      from children c
      where c.tenant_id = p_tenant and c.status = 'enrolled' and c.fee_plan_id is not null
        and coalesce(c.start_date, per) <= per_end and (c.end_date is null or c.end_date >= per)) x
    where gid is not null
  loop
    if exists (select 1 from kids_fee_invoices where tenant_id = p_tenant and guardian_id = payer.gid and period = per) then
      skipped := skipped + 1; continue;
    end if;
    insert into invoices (tenant_id, contact_id, currency, due_date, notes)
    values (p_tenant, guardian_contact(payer.gid), cur, per + coalesce(st.invoice_day, 1) - 1 + coalesce(st.due_days, 7),
            'Fees for ' || to_char(per, 'FMMonth YYYY'))
    returning id into inv_id;
    n_lines := 0; sib := 0;
    for ch in
      select c.*, fp.name plan_name, fp.monthly_fee, fp.registration_fee, fp.deposit, fp.sibling_discount_pct
      from children c join kids_fee_plans fp on fp.id = c.fee_plan_id
      where c.tenant_id = p_tenant and c.status = 'enrolled'
        and coalesce(c.start_date, per) <= per_end and (c.end_date is null or c.end_date >= per)
        and coalesce(
          (select cg.guardian_id from child_guardians cg where cg.child_id = c.id and cg.pays_fees order by cg.is_primary desc limit 1),
          (select cg.guardian_id from child_guardians cg where cg.child_id = c.id order by cg.is_primary desc limit 1)) = payer.gid
      order by c.dob                                -- eldest first; sibling discount on younger children
    loop
      sib := sib + 1;
      amt := ch.monthly_fee;
      insert into invoice_lines (invoice_id, description, qty, unit_price, discount, tax_code, sort_order)
      values (inv_id, ch.plan_name || ' — ' || ch.full_name || ' (' || to_char(per, 'Mon YYYY') || ')', 1, amt,
              case when sib > 1 then round(amt * ch.sibling_discount_pct / 100, 2) else 0 end, 'exempt', n_lines);
      n_lines := n_lines + 1;
      if ch.registration_invoice_id is null and (ch.registration_fee > 0 or ch.deposit > 0) then
        if ch.registration_fee > 0 then
          insert into invoice_lines (invoice_id, description, qty, unit_price, tax_code, sort_order)
          values (inv_id, 'Registration fee — ' || ch.full_name, 1, ch.registration_fee, 'exempt', n_lines);
          n_lines := n_lines + 1;
        end if;
        if ch.deposit > 0 then
          insert into invoice_lines (invoice_id, description, qty, unit_price, tax_code, sort_order)
          values (inv_id, 'Deposit (refundable) — ' || ch.full_name, 1, ch.deposit, 'exempt', n_lines);
          n_lines := n_lines + 1;
        end if;
        update children set registration_invoice_id = inv_id where id = ch.id;
      end if;
      -- late pick-up fees and extra charges not billed yet, up to the end of the month
      for lf in select id, day, late_minutes, late_fee from kids_attendance
                where child_id = ch.id and late_fee > 0 and late_fee_invoice_id is null and day <= per_end loop
        insert into invoice_lines (invoice_id, description, qty, unit_price, tax_code, sort_order)
        values (inv_id, 'Late pick-up ' || to_char(lf.day, 'DD Mon') || ' (' || lf.late_minutes || ' min) — ' || ch.full_name, 1, lf.late_fee, 'exempt', n_lines);
        update kids_attendance set late_fee_invoice_id = inv_id where id = lf.id;
        n_lines := n_lines + 1;
      end loop;
      for ex in select id, description, amount from kids_extra_charges where child_id = ch.id and invoice_id is null and charge_date <= per_end loop
        insert into invoice_lines (invoice_id, description, qty, unit_price, tax_code, sort_order)
        values (inv_id, ex.description || ' — ' || ch.full_name, 1, ex.amount, 'exempt', n_lines);
        update kids_extra_charges set invoice_id = inv_id where id = ex.id;
        n_lines := n_lines + 1;
      end loop;
    end loop;
    insert into kids_fee_invoices (tenant_id, guardian_id, period, invoice_id) values (p_tenant, payer.gid, per, inv_id);
    n_inv := n_inv + 1;
    if p_issue then
      perform issue_invoice(inv_id, greatest(current_date, per));
      issued := issued + 1;
    end if;
    v_total := v_total + (select i.total from invoices i where i.id = inv_id);
  end loop;
  return jsonb_build_object('created', n_inv, 'issued', issued, 'skipped_existing', skipped, 'total', v_total);
end $$;

-- ===== Compliance items for childcare =====
create or replace function public.kids_compliance_defaults(p_tenant uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into compliance_items (tenant_id, code, title, authority, category, due_date, recurrence, note)
  select p_tenant, x.code, x.title, x.auth, x.cat, null, x.rec, x.note
  from (values
    ('kids_licence', 'Renew childcare licence (TASKA – JKM / TADIKA – KPM)', 'JKM / KPM', 'licence', 'annual',
     'Running a childcare centre without a valid registration is an offence. Set the expiry date from your certificate.'),
    ('kids_bomba', 'Fire safety certificate (Bomba)', 'BOMBA', 'licence', 'annual', 'Needed for your premises approval.'),
    ('kids_fire_drill', 'Fire / evacuation drill with the children', 'Internal', 'other', 'quarterly',
     'Recommended practice: record the drill and the roll call from the Kids → Here now list.'),
    ('kids_first_aid', 'Carers'' first-aid training up to date', 'Internal', 'other', 'annual',
     'Check each carer''s first-aid and childcare course certificates.')
  ) as x(code, title, auth, cat, rec, note)
  where not exists (select 1 from compliance_items ci where ci.tenant_id = p_tenant and ci.code = x.code);
  insert into kids_settings (tenant_id) values (p_tenant) on conflict do nothing;
end $$;

create or replace function public.kids_module_on()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.module = 'KIDS' and new.enabled then perform kids_compliance_defaults(new.tenant_id); end if;
  return null;
end $$;
create trigger trg_kids_module_on after insert or update on public.tenant_modules for each row execute function public.kids_module_on();
do $$ declare t record; begin
  for t in select tenant_id from public.tenant_modules where module = 'KIDS' and enabled loop
    perform public.kids_compliance_defaults(t.tenant_id);
  end loop;
end $$;

-- ===== Row level security =====
alter table public.kids_settings enable row level security;
create policy ks_read on public.kids_settings for select using (has_perm(tenant_id, 'kids.view') or is_member(tenant_id));
create policy ks_write on public.kids_settings for all using (has_perm(tenant_id, 'kids.manage')) with check (has_perm(tenant_id, 'kids.manage'));

alter table public.kids_fee_plans enable row level security;
create policy kfp_read on public.kids_fee_plans for select using (has_perm(tenant_id, 'kids.view') or has_perm(tenant_id, 'kids.billing'));
create policy kfp_write on public.kids_fee_plans for all using (has_perm(tenant_id, 'kids.manage')) with check (has_perm(tenant_id, 'kids.manage'));

alter table public.kids_rooms enable row level security;
create policy kr_read on public.kids_rooms for select using (has_perm(tenant_id, 'kids.view') or has_perm(tenant_id, 'kids.parent'));
create policy kr_write on public.kids_rooms for all using (has_perm(tenant_id, 'kids.manage')) with check (has_perm(tenant_id, 'kids.manage'));

alter table public.children enable row level security;
create policy ch_read on public.children for select using (has_perm(tenant_id, 'kids.view') or has_perm(tenant_id, 'kids.billing') or is_guardian_of(id));
create policy ch_write on public.children for all using (has_perm(tenant_id, 'kids.manage')) with check (has_perm(tenant_id, 'kids.manage'));

alter table public.child_private enable row level security;
create policy cp_read on public.child_private for select using (has_perm(tenant_id, 'kids.manage') or is_guardian_of(child_id));
create policy cp_write on public.child_private for all using (has_perm(tenant_id, 'kids.manage')) with check (has_perm(tenant_id, 'kids.manage'));

alter table public.guardians enable row level security;
create policy g_read on public.guardians for select using (
  has_perm(tenant_id, 'kids.view') or has_perm(tenant_id, 'kids.billing') or user_id = auth.uid()
  or exists (select 1 from child_guardians cg where cg.guardian_id = guardians.id and is_guardian_of(cg.child_id)));
create policy g_write on public.guardians for all using (has_perm(tenant_id, 'kids.manage')) with check (has_perm(tenant_id, 'kids.manage'));

alter table public.child_guardians enable row level security;
create policy cg_read on public.child_guardians for select using (has_perm(tenant_id, 'kids.view') or has_perm(tenant_id, 'kids.billing') or is_guardian_of(child_id));
create policy cg_write on public.child_guardians for all using (has_perm(tenant_id, 'kids.manage')) with check (has_perm(tenant_id, 'kids.manage'));

alter table public.guardian_pins enable row level security;   -- no policies: only the functions above touch it

alter table public.pickup_persons enable row level security;
create policy pp_read on public.pickup_persons for select using (has_perm(tenant_id, 'kids.view') or is_guardian_of(child_id));
create policy pp_delete on public.pickup_persons for delete using (has_perm(tenant_id, 'kids.manage') or is_guardian_of(child_id));

alter table public.kids_attendance enable row level security;
create policy ka_read on public.kids_attendance for select using (has_perm(tenant_id, 'kids.view') or has_perm(tenant_id, 'kids.billing') or is_guardian_of(child_id));
create policy ka_edit on public.kids_attendance for update using (has_perm(tenant_id, 'kids.manage')) with check (has_perm(tenant_id, 'kids.manage'));

alter table public.kids_absences enable row level security;
create policy kab_read on public.kids_absences for select using (has_perm(tenant_id, 'kids.view') or is_guardian_of(child_id));

alter table public.kids_staff_duty enable row level security;
create policy kd_read on public.kids_staff_duty for select using (has_perm(tenant_id, 'kids.view'));

alter table public.kids_logs enable row level security;
create policy kl_read on public.kids_logs for select using (has_perm(tenant_id, 'kids.view') or (visible_to_parents and is_guardian_of(child_id)));
create policy kl_insert on public.kids_logs for insert with check (has_perm(tenant_id, 'kids.log'));
create policy kl_update on public.kids_logs for update using (has_perm(tenant_id, 'kids.manage') or (by_user = auth.uid() and has_perm(tenant_id, 'kids.log')))
  with check (has_perm(tenant_id, 'kids.log'));
create policy kl_delete on public.kids_logs for delete using (has_perm(tenant_id, 'kids.manage') or (by_user = auth.uid() and kind <> 'medication'));

alter table public.kids_med_authorisations enable row level security;
create policy kma_read on public.kids_med_authorisations for select using (has_perm(tenant_id, 'kids.view') or is_guardian_of(child_id));
create policy kma_stop on public.kids_med_authorisations for update using (has_perm(tenant_id, 'kids.manage') or is_guardian_of(child_id))
  with check (has_perm(tenant_id, 'kids.manage') or is_guardian_of(child_id));

alter table public.kids_med_given enable row level security;
create policy kmg_read on public.kids_med_given for select using (has_perm(tenant_id, 'kids.view') or is_guardian_of(child_id));

alter table public.kids_incidents enable row level security;
create policy ki_read on public.kids_incidents for select using (
  case when kind = 'safeguarding' then has_perm(tenant_id, 'kids.manage') or reported_by = auth.uid()
       else has_perm(tenant_id, 'kids.view') or is_guardian_of(child_id) end);
create policy ki_update on public.kids_incidents for update using (has_perm(tenant_id, 'kids.manage')) with check (has_perm(tenant_id, 'kids.manage'));

alter table public.kids_messages enable row level security;
create policy km_read on public.kids_messages for select using (has_perm(tenant_id, 'kids.view') or is_guardian_of(child_id));

alter table public.kids_extra_charges enable row level security;
create policy kx_read on public.kids_extra_charges for select using (has_perm(tenant_id, 'kids.view') or has_perm(tenant_id, 'kids.billing') or is_guardian_of(child_id));
create policy kx_write on public.kids_extra_charges for all using (has_perm(tenant_id, 'kids.manage') and invoice_id is null)
  with check (has_perm(tenant_id, 'kids.manage') and invoice_id is null);

alter table public.kids_fee_invoices enable row level security;
create policy kfi_read on public.kids_fee_invoices for select using (has_perm(tenant_id, 'kids.billing') or has_perm(tenant_id, 'fin.invoice.view'));

alter table public.kids_counters enable row level security;

-- Parents see their own issued fee invoices
create policy inv_guardian_read on public.invoices for select using (
  status <> 'draft' and exists (select 1 from guardians g where g.contact_id = invoices.contact_id and g.user_id = auth.uid() and g.active));
create policy invl_guardian_read on public.invoice_lines for select using (
  exists (select 1 from invoices i join guardians g on g.contact_id = i.contact_id
          where i.id = invoice_lines.invoice_id and i.status <> 'draft' and g.user_id = auth.uid() and g.active));

do $$ declare t text; begin
  foreach t in array array['children','child_private','guardians','child_guardians','pickup_persons','kids_attendance',
                           'kids_med_authorisations','kids_med_given','kids_incidents','kids_rooms','kids_fee_plans','invites'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- ===== Photo storage (Supabase Storage bucket "kids", private) =====
-- Path: <tenant_id>/<child_id>/<file>.jpg
do $$
begin
  if exists (select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets (id, name, public) values ('kids', 'kids', false) on conflict (id) do nothing;
    execute $p$create policy kids_photo_read on storage.objects for select to authenticated using (
      bucket_id = 'kids' and (
        public.has_perm((storage.foldername(name))[1]::uuid, 'kids.view')
        or (public.is_guardian_of((storage.foldername(name))[2]::uuid)
            and exists (select 1 from public.kids_logs l where l.photo_path = storage.objects.name and l.visible_to_parents))
        or exists (select 1 from public.children c where c.photo_path = storage.objects.name and public.is_guardian_of(c.id))))$p$;
    execute $p$create policy kids_photo_write on storage.objects for insert to authenticated with check (
      bucket_id = 'kids' and (public.has_perm((storage.foldername(name))[1]::uuid, 'kids.log')
                              or public.has_perm((storage.foldername(name))[1]::uuid, 'kids.manage')))$p$;
    execute $p$create policy kids_photo_delete on storage.objects for delete to authenticated using (
      bucket_id = 'kids' and public.has_perm((storage.foldername(name))[1]::uuid, 'kids.manage'))$p$;
  end if;
end $$;
