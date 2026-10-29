-- Ai buddy Biz — Batch F: HR & payroll (Malaysia first)
-- Employees, attendance & overtime, public holidays, leave, claims, payroll with
-- EPF / SOCSO / EIS / PCB (MTD), payslips and accounting.
-- Statutory figures are DATA (tables / parameters with dates) so they can be updated
-- without code changes. VERIFY against KWSP, PERKESO and LHDN before go-live.
-- Depends on 0001–0005.

-- ===== Permissions & roles =====
insert into public.permissions (code, module, description) values
  ('hr.self','HR','Clock in/out, own leave, claims and payslips'),
  ('hr.employee.view','HR','See the staff list and attendance'),
  ('hr.employee.manage','HR','Add/edit employees, private details'),
  ('hr.attendance.manage','HR','Fix attendance and approve overtime'),
  ('hr.leave.approve','HR','Approve or reject leave'),
  ('hr.claim.approve','HR','Approve or reject expense claims'),
  ('hr.payroll.run','HR','Prepare, approve and pay payroll'),
  ('hr.payroll.view','HR','View payroll results and reports');

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r join public.permissions p on p.module = 'HR'
where r.tenant_id is null and r.name in ('Owner','Admin','HR')
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r,
  unnest(array['hr.self','hr.employee.view','hr.attendance.manage','hr.leave.approve','hr.claim.approve']) c
where r.tenant_id is null and r.name = 'Manager'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, c from public.roles r, unnest(array['hr.self','hr.payroll.view']) c
where r.tenant_id is null and r.name = 'Accountant'
on conflict do nothing;

insert into public.role_permissions (role_id, permission_code)
select r.id, 'hr.self' from public.roles r
where r.tenant_id is null and r.name in ('Cashier','Warehouse','Driver','Carer','Sales','Operations','Viewer')
on conflict do nothing;

-- ===== Employees =====
create table public.employee_counters (
  tenant_id uuid primary key references public.tenants(id) on delete cascade,
  next_no bigint not null default 1
);
alter table public.employee_counters enable row level security;

-- Basic, non-sensitive details (colleagues and managers can see these)
create table public.employees (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,     -- app login, if any
  employee_no text,
  full_name text not null,
  preferred_name text,
  email text,
  phone text,
  job_title text,
  department text,
  outlet_id uuid references public.outlets(id) on delete set null,
  manager_id uuid references public.employees(id) on delete set null,
  employment_type text not null default 'full_time'
    check (employment_type in ('full_time','part_time','contract','intern','daily','hourly')),
  start_date date not null default current_date,
  probation_end date,
  end_date date,
  status text not null default 'active' check (status in ('active','resigned','terminated','retired')),
  work_days int[] not null default '{1,2,3,4,5}',      -- ISO weekday numbers, 1 = Monday
  rest_day int not null default 7,
  shift_start time not null default '09:00',
  shift_end time not null default '18:00',
  break_minutes int not null default 60,
  photo_path text,
  created_at timestamptz not null default now(),
  unique (tenant_id, employee_no),
  unique (tenant_id, user_id)
);
create index on public.employees (tenant_id, status);

-- Sensitive details: only HR and the employee themselves
create table public.employee_private (
  employee_id uuid primary key references public.employees(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  id_type text not null default 'mykad' check (id_type in ('mykad','passport','mypr','other')),
  id_no text,
  date_of_birth date,
  gender text check (gender in ('male','female')),
  citizenship text not null default 'citizen' check (citizenship in ('citizen','pr','foreign')),
  nationality char(2) not null default 'MY',
  marital_status text not null default 'single' check (marital_status in ('single','married','divorced','widowed')),
  address text,
  emergency_contact text,
  bank_name text,
  bank_account text,
  updated_at timestamptz not null default now()
);

-- Pay set-up: only HR / payroll
create table public.employee_pay (
  employee_id uuid primary key references public.employees(id) on delete cascade,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  pay_basis text not null default 'monthly' check (pay_basis in ('monthly','daily','hourly')),
  basic_salary numeric(12,2) not null default 0 check (basic_salary >= 0),   -- monthly basis
  daily_rate numeric(12,2),
  hourly_rate numeric(12,2),
  ot_eligible boolean not null default true,
  -- statutory
  epf_no text, socso_no text, tax_no text,
  epf_ee_rate numeric(5,4),            -- optional higher voluntary employee rate, e.g. 0.12
  epf_er_rate numeric(5,4),            -- optional higher employer rate
  socso_enabled boolean not null default true,
  eis_enabled boolean not null default true,
  pcb_enabled boolean not null default true,
  tax_category smallint not null default 1 check (tax_category in (1,2,3)),
  qualifying_children numeric(4,1) not null default 0,   -- LHDN child units (e.g. 1 child = 1, tertiary may count more)
  disabled boolean not null default false,
  spouse_disabled boolean not null default false,
  zakat_monthly numeric(10,2) not null default 0,
  other_reliefs_monthly numeric(10,2) not null default 0,  -- LP: approved reliefs claimed via TP1
  -- amounts from a previous employer earlier this year (for PCB)
  prev_year int,
  prev_gross numeric(12,2) not null default 0,
  prev_epf numeric(12,2) not null default 0,
  prev_pcb numeric(12,2) not null default 0,
  prev_zakat numeric(12,2) not null default 0,
  updated_at timestamptz not null default now()
);

-- Recurring allowances / deductions on every payslip
create table public.employee_pay_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  kind text not null check (kind in ('earning','deduction')),
  name text not null,
  amount numeric(12,2) not null check (amount >= 0),
  taxable boolean not null default true,
  epf boolean not null default true,         -- counts as wages for EPF
  socso boolean not null default true,       -- counts as wages for SOCSO/EIS
  active boolean not null default true,
  start_on date, end_on date
);

create or replace function public.employee_before()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.employee_no is null then
    insert into employee_counters (tenant_id) values (new.tenant_id) on conflict do nothing;
    update employee_counters set next_no = next_no + 1 where tenant_id = new.tenant_id
      returning 'E' || lpad((next_no - 1)::text, 4, '0') into new.employee_no;
  end if;
  new.email := lower(nullif(trim(new.email), ''));
  if new.end_date is not null and new.end_date < new.start_date then raise exception 'End date is before start date'; end if;
  return new;
end $$;
create trigger trg_employee_before before insert or update on public.employees for each row execute function public.employee_before();

create or replace function public.employee_after_insert()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into employee_private (employee_id, tenant_id) values (new.id, new.tenant_id) on conflict do nothing;
  insert into employee_pay (employee_id, tenant_id) values (new.id, new.tenant_id) on conflict do nothing;
  return null;
end $$;
create trigger trg_employee_after_insert after insert on public.employees for each row execute function public.employee_after_insert();

-- The signed-in user's employee record; links automatically when HR used the same email
create or replace function public.my_employee_id(p_tenant uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare eid uuid; em text;
begin
  select id into eid from employees where tenant_id = p_tenant and user_id = auth.uid();
  if eid is not null then return eid; end if;
  if not is_member(p_tenant) then return null; end if;
  select lower(email) into em from auth.users where id = auth.uid();
  if em is null then return null; end if;
  update employees set user_id = auth.uid()
  where id = (select id from employees where tenant_id = p_tenant and email = em and user_id is null and status = 'active' limit 1)
  returning id into eid;
  return eid;
end $$;

create or replace function public.is_self_employee(p_employee uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from employees where id = p_employee and user_id = auth.uid());
$$;

-- ===== Public holidays =====
create table public.public_holidays (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  holiday_date date not null,
  name text not null,
  unique (tenant_id, holiday_date)
);

-- Working days between two dates for an employee (work-day pattern, minus public holidays)
create or replace function public.working_days(p_employee uuid, p_from date, p_to date)
returns int language sql stable security definer set search_path = public as $$
  select count(*)::int from generate_series(p_from, p_to, interval '1 day') d, employees e
  where e.id = p_employee and extract(isodow from d)::int = any(e.work_days)
    and not exists (select 1 from public_holidays h where h.tenant_id = e.tenant_id and h.holiday_date = d::date);
$$;

-- ===== Attendance =====
create table public.attendance (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  work_date date not null,
  clock_in timestamptz not null,
  clock_out timestamptz,
  outlet_id uuid references public.outlets(id) on delete set null,
  in_lat numeric(9,6), in_lng numeric(9,6), out_lat numeric(9,6), out_lng numeric(9,6),
  source text not null default 'app' check (source in ('app','kiosk','manual','import')),
  late_minutes int not null default 0,
  worked_minutes int,
  ot_minutes int not null default 0,              -- worked beyond the shift
  ot_approved_minutes int not null default 0,     -- what payroll pays
  day_type text not null default 'normal' check (day_type in ('normal','rest_day','public_holiday')),
  note text,
  edited_by uuid,
  unique (employee_id, work_date, clock_in),
  check (clock_out is null or clock_out > clock_in)
);
create index on public.attendance (tenant_id, work_date);

create or replace function public.attendance_before()
returns trigger language plpgsql security definer set search_path = public as $$
declare e employees; tz text; local_in timestamp; local_out timestamp; sched_minutes int;
begin
  select * into e from employees where id = new.employee_id;
  select coalesce(o.timezone, 'Asia/Kuala_Lumpur') into tz from outlets o where o.id = coalesce(new.outlet_id, e.outlet_id);
  tz := coalesce(tz, 'Asia/Kuala_Lumpur');
  local_in := new.clock_in at time zone tz;
  new.work_date := local_in::date;
  new.day_type := case
    when exists (select 1 from public_holidays h where h.tenant_id = e.tenant_id and h.holiday_date = new.work_date) then 'public_holiday'
    when extract(isodow from new.work_date)::int = e.rest_day then 'rest_day'
    when not (extract(isodow from new.work_date)::int = any(e.work_days)) then 'rest_day'
    else 'normal' end;
  new.late_minutes := case when new.day_type = 'normal'
    then greatest(0, floor(extract(epoch from (local_in - (new.work_date + e.shift_start))) / 60))::int else 0 end;
  if new.clock_out is not null then
    local_out := new.clock_out at time zone tz;
    new.worked_minutes := floor(extract(epoch from (new.clock_out - new.clock_in)) / 60)::int
                          - case when extract(epoch from (new.clock_out - new.clock_in)) > 5 * 3600 then e.break_minutes else 0 end;
    sched_minutes := floor(extract(epoch from (e.shift_end - e.shift_start)) / 60)::int - e.break_minutes;
    new.ot_minutes := case when new.day_type = 'normal' then greatest(0, new.worked_minutes - sched_minutes)
                           else greatest(0, new.worked_minutes) end;
    if new.ot_approved_minutes > new.ot_minutes then new.ot_approved_minutes := new.ot_minutes; end if;
  end if;
  return new;
end $$;
create trigger trg_attendance_before before insert or update on public.attendance for each row execute function public.attendance_before();

create or replace function public.clock_in(p_tenant uuid, p_outlet uuid default null, p_lat numeric default null, p_lng numeric default null)
returns public.attendance language plpgsql security definer set search_path = public as $$
declare eid uuid; a attendance;
begin
  if not has_perm(p_tenant, 'hr.self') then raise exception 'Not allowed'; end if;
  eid := my_employee_id(p_tenant);
  if eid is null then raise exception 'Your login is not linked to an employee record. Ask HR to add your email.'; end if;
  if exists (select 1 from attendance where employee_id = eid and clock_out is null and clock_in > now() - interval '20 hours') then
    raise exception 'You are already clocked in';
  end if;
  insert into attendance (tenant_id, employee_id, work_date, clock_in, outlet_id, in_lat, in_lng)
  values (p_tenant, eid, current_date, now(), p_outlet, p_lat, p_lng) returning * into a;
  return a;
end $$;

create or replace function public.clock_out(p_tenant uuid, p_lat numeric default null, p_lng numeric default null)
returns public.attendance language plpgsql security definer set search_path = public as $$
declare eid uuid; a attendance;
begin
  eid := my_employee_id(p_tenant);
  if eid is null then raise exception 'Your login is not linked to an employee record'; end if;
  update attendance set clock_out = now(), out_lat = p_lat, out_lng = p_lng
  where id = (select id from attendance where employee_id = eid and clock_out is null order by clock_in desc limit 1)
  returning * into a;
  if a.id is null then raise exception 'You are not clocked in'; end if;
  return a;
end $$;

-- ===== Leave =====
create table public.leave_types (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  code text not null,
  name text not null,
  paid boolean not null default true,
  -- entitlement by completed years of service: [{"min_years":0,"days":8},…]
  entitlement jsonb not null default '[{"min_years":0,"days":0}]',
  prorate_first_year boolean not null default true,
  carry_forward_max numeric(5,1) not null default 0,
  requires_document boolean not null default false,
  gender text check (gender in ('male','female')),
  count_calendar_days boolean not null default false,   -- maternity counts consecutive days
  active boolean not null default true,
  unique (tenant_id, code)
);

-- Employment Act 1955 minimums (as amended 2022). Businesses may give more.
create or replace function public.ensure_leave_types(p_tenant uuid)
returns void language sql security definer set search_path = public as $$
  insert into leave_types (tenant_id, code, name, paid, entitlement, prorate_first_year, carry_forward_max, requires_document, gender, count_calendar_days) values
    (p_tenant,'AL','Annual leave',true,'[{"min_years":0,"days":8},{"min_years":2,"days":12},{"min_years":5,"days":16}]',true,0,false,null,false),
    (p_tenant,'SL','Sick leave',true,'[{"min_years":0,"days":14},{"min_years":2,"days":18},{"min_years":5,"days":22}]',false,0,true,null,false),
    (p_tenant,'HL','Hospitalisation leave',true,'[{"min_years":0,"days":60}]',false,0,true,null,false),
    (p_tenant,'ML','Maternity leave',true,'[{"min_years":0,"days":98}]',false,0,true,'female',true),
    (p_tenant,'PL','Paternity leave',true,'[{"min_years":0,"days":7}]',false,0,true,'male',false),
    (p_tenant,'UL','Unpaid leave',false,'[{"min_years":0,"days":365}]',false,0,false,null,false),
    (p_tenant,'CL','Compassionate leave',true,'[{"min_years":0,"days":3}]',false,0,false,null,false)
  on conflict (tenant_id, code) do nothing;
$$;

create table public.leave_adjustments (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  leave_type_id uuid not null references public.leave_types(id) on delete cascade,
  year int not null,
  days numeric(5,1) not null,                -- + carried forward / granted, − forfeited
  reason text not null,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now()
);

create table public.leave_requests (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  leave_type_id uuid not null references public.leave_types(id),
  start_date date not null,
  end_date date not null,
  half_day text check (half_day in ('am','pm')),
  days numeric(5,1) not null default 0,
  reason text,
  document_path text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','cancelled')),
  decided_by uuid, decided_at timestamptz, decision_note text,
  created_at timestamptz not null default now(),
  check (end_date >= start_date),
  check (half_day is null or start_date = end_date)
);
create index on public.leave_requests (tenant_id, status);
create index on public.leave_requests (employee_id, start_date);

create or replace function public.leave_entitlement(p_employee uuid, p_type uuid, p_year int)
returns numeric language plpgsql stable security definer set search_path = public as $$
declare e employees; lt leave_types; yrs numeric; base numeric := 0; band jsonb; adj numeric; months numeric;
begin
  select * into e from employees where id = p_employee;
  select * into lt from leave_types where id = p_type;
  yrs := extract(epoch from age(make_date(p_year, 12, 31), e.start_date)) / (365.25 * 86400);
  -- service at the start of the year decides the band
  yrs := greatest(0, extract(year from age(make_date(p_year, 1, 1), e.start_date)));
  for band in select * from jsonb_array_elements(lt.entitlement) loop
    if yrs >= (band->>'min_years')::numeric then base := greatest(base, (band->>'days')::numeric); end if;
  end loop;
  if lt.prorate_first_year and extract(year from e.start_date) = p_year then
    months := 12 - extract(month from e.start_date) + 1;
    base := floor(base * months / 12 * 2) / 2;   -- to half days
  end if;
  if e.end_date is not null and extract(year from e.end_date) = p_year and lt.prorate_first_year then
    base := floor(base * extract(month from e.end_date) / 12 * 2) / 2;
  end if;
  select coalesce(sum(days),0) into adj from leave_adjustments where employee_id = p_employee and leave_type_id = p_type and year = p_year;
  return base + adj;
end $$;

create or replace function public.leave_balances(p_employee uuid, p_year int default extract(year from current_date)::int)
returns table (leave_type_id uuid, code text, name text, entitled numeric, taken numeric, pending numeric, balance numeric)
language plpgsql stable security definer set search_path = public as $$
declare e employees; g text;
begin
  select * into e from employees where id = p_employee;
  if not (is_self_employee(p_employee) or has_perm(e.tenant_id, 'hr.employee.view')) then raise exception 'Not allowed'; end if;
  perform ensure_leave_types(e.tenant_id);
  select gender into g from employee_private where employee_id = p_employee;
  return query
  select lt.id, lt.code, lt.name, leave_entitlement(p_employee, lt.id, p_year),
    coalesce((select sum(r.days) from leave_requests r where r.employee_id = p_employee and r.leave_type_id = lt.id
              and r.status = 'approved' and extract(year from r.start_date) = p_year), 0),
    coalesce((select sum(r.days) from leave_requests r where r.employee_id = p_employee and r.leave_type_id = lt.id
              and r.status = 'pending' and extract(year from r.start_date) = p_year), 0),
    leave_entitlement(p_employee, lt.id, p_year)
      - coalesce((select sum(r.days) from leave_requests r where r.employee_id = p_employee and r.leave_type_id = lt.id
                  and r.status in ('approved','pending') and extract(year from r.start_date) = p_year), 0)
  from leave_types lt
  where lt.tenant_id = e.tenant_id and lt.active and (lt.gender is null or lt.gender = g)
  order by lt.code;
end $$;

create or replace function public.request_leave(p_type uuid, p_start date, p_end date, p_half text default null,
                                                p_reason text default null, p_employee uuid default null)
returns public.leave_requests language plpgsql security definer set search_path = public as $$
declare lt leave_types; e employees; d numeric; bal numeric; r leave_requests; eid uuid;
begin
  select * into lt from leave_types where id = p_type;
  if not found then raise exception 'Unknown leave type'; end if;
  eid := coalesce(p_employee, my_employee_id(lt.tenant_id));
  if eid is null then raise exception 'Your login is not linked to an employee record'; end if;
  select * into e from employees where id = eid and tenant_id = lt.tenant_id;
  if not found then raise exception 'Unknown employee'; end if;
  if not (is_self_employee(eid) or has_perm(e.tenant_id, 'hr.leave.approve')) then raise exception 'Not allowed'; end if;
  if p_end < p_start then raise exception 'End date is before start date'; end if;
  if p_half is not null and p_start <> p_end then raise exception 'Half days are for a single day'; end if;
  if exists (select 1 from leave_requests x where x.employee_id = eid and x.status in ('pending','approved')
             and daterange(x.start_date, x.end_date, '[]') && daterange(p_start, p_end, '[]')) then
    raise exception 'You already have leave on some of these days';
  end if;
  d := case when lt.count_calendar_days then (p_end - p_start + 1) else working_days(eid, p_start, p_end) end;
  if p_half is not null then d := least(d, 0.5); end if;
  if d <= 0 then raise exception 'No working days in that range'; end if;
  select balance into bal from leave_balances(eid, extract(year from p_start)::int) b where b.leave_type_id = p_type;
  if bal is null then raise exception 'This leave type is not available for you'; end if;
  if d > bal then raise exception 'Not enough % balance: % day(s) left, % requested', lt.name, bal, d; end if;
  insert into leave_requests (tenant_id, employee_id, leave_type_id, start_date, end_date, half_day, days, reason)
  values (e.tenant_id, eid, p_type, p_start, p_end, p_half, d, p_reason) returning * into r;
  return r;
end $$;

create or replace function public.decide_leave(p_request uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare r leave_requests;
begin
  select * into r from leave_requests where id = p_request for update;
  if not found then raise exception 'Unknown request'; end if;
  if not has_perm(r.tenant_id, 'hr.leave.approve') then raise exception 'Not allowed'; end if;
  if is_self_employee(r.employee_id) and not has_perm(r.tenant_id, 'hr.payroll.run') then
    raise exception 'You cannot approve your own leave';
  end if;
  if r.status <> 'pending' then raise exception 'Request is already %', r.status; end if;
  update leave_requests set status = case when p_approve then 'approved' else 'rejected' end,
    decided_by = auth.uid(), decided_at = now(), decision_note = p_note where id = r.id;
end $$;

create or replace function public.cancel_leave(p_request uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r leave_requests;
begin
  select * into r from leave_requests where id = p_request for update;
  if not (is_self_employee(r.employee_id) or has_perm(r.tenant_id, 'hr.leave.approve')) then raise exception 'Not allowed'; end if;
  if r.status not in ('pending','approved') then raise exception 'Request is already %', r.status; end if;
  if r.status = 'approved' and r.start_date <= current_date and not has_perm(r.tenant_id, 'hr.leave.approve') then
    raise exception 'Leave already started — ask your manager to cancel it';
  end if;
  if exists (select 1 from payslips p join payroll_runs pr on pr.id = p.run_id
             where p.employee_id = r.employee_id and pr.status <> 'draft'
               and make_date(pr.year, pr.month, 1) <= r.end_date
               and (make_date(pr.year, pr.month, 1) + interval '1 month - 1 day')::date >= r.start_date) then
    raise exception 'Payroll for that month is already approved';
  end if;
  update leave_requests set status = 'cancelled', decided_at = now() where id = r.id;
end $$;

-- ===== Claims =====
create table public.claims (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  employee_id uuid not null references public.employees(id) on delete cascade,
  claim_date date not null default current_date,
  category text not null check (category in ('travel','mileage','meal','parking','toll','phone','medical','training','supplies','other')),
  description text not null,
  amount numeric(12,2) not null check (amount > 0),
  km numeric(8,1),                         -- mileage claims
  receipt_path text,
  status text not null default 'pending' check (status in ('pending','approved','rejected','paid','cancelled')),
  decided_by uuid, decided_at timestamptz, decision_note text,
  payslip_id uuid,                          -- set when reimbursed through payroll
  created_at timestamptz not null default now()
);
create index on public.claims (tenant_id, status);

create or replace function public.submit_claim(p_tenant uuid, p_category text, p_description text, p_amount numeric,
                                               p_date date default current_date, p_km numeric default null)
returns public.claims language plpgsql security definer set search_path = public as $$
declare eid uuid; c claims;
begin
  if not has_perm(p_tenant, 'hr.self') then raise exception 'Not allowed'; end if;
  eid := my_employee_id(p_tenant);
  if eid is null then raise exception 'Your login is not linked to an employee record'; end if;
  if p_date > current_date then raise exception 'Claim date is in the future'; end if;
  if p_date < current_date - 90 then raise exception 'Claims older than 90 days need HR'; end if;
  insert into claims (tenant_id, employee_id, claim_date, category, description, amount, km)
  values (p_tenant, eid, p_date, p_category, p_description, round(p_amount, 2), p_km) returning * into c;
  return c;
end $$;

create or replace function public.decide_claim(p_claim uuid, p_approve boolean, p_note text default null)
returns void language plpgsql security definer set search_path = public as $$
declare c claims;
begin
  select * into c from claims where id = p_claim for update;
  if not has_perm(c.tenant_id, 'hr.claim.approve') then raise exception 'Not allowed'; end if;
  if is_self_employee(c.employee_id) then raise exception 'You cannot approve your own claim'; end if;
  if c.status <> 'pending' then raise exception 'Claim is already %', c.status; end if;
  update claims set status = case when p_approve then 'approved' else 'rejected' end,
    decided_by = auth.uid(), decided_at = now(), decision_note = p_note where id = c.id;
end $$;

-- ===== Statutory data =====
create table public.statutory_params (
  country char(2) not null,
  key text not null,
  valid_from date not null,
  value numeric not null,
  note text,
  primary key (country, key, valid_from)
);
insert into public.statutory_params (country, key, valid_from, value, note) values
  ('MY','minimum_wage_monthly','2025-08-01',1700,'RM1,700 for all employers from 1 Aug 2025; RM2,000 announced for Jun 2027 (Budget 2027)'),
  ('MY','socso_ceiling','2024-10-01',6000,'SOCSO/EIS wage ceiling RM6,000 from Oct 2024'),
  ('MY','epf_ee_rate','2022-01-01',0.11,'Employee 11% (citizens/PR under 60)'),
  ('MY','epf_er_rate_low','2000-01-01',0.13,'Employer 13% when wages ≤ RM5,000'),
  ('MY','epf_er_rate_high','2000-01-01',0.12,'Employer 12% when wages > RM5,000'),
  ('MY','epf_er_rate_60','2019-01-01',0.04,'Citizens 60+: employer 4%, employee 0% (verify)'),
  ('MY','epf_ee_rate_60_pr','2019-01-01',0.055,'PR / non-citizens elected before 1998, 60+: employee 5.5% (verify)'),
  ('MY','epf_er_rate_60_pr','2019-01-01',0.065,'PR 60+: employer 6.5% (verify)'),
  ('MY','epf_foreign_rate','2025-10-01',0.02,'Foreign workers: 2% employer + 2% employee from Oct 2025 wages'),
  ('MY','epf_relief_cap','2000-01-01',4000,'PCB: EPF counted up to RM4,000 a year'),
  ('MY','pcb_relief_self','2000-01-01',9000,'D'),
  ('MY','pcb_relief_spouse','2000-01-01',4000,'S (category 2)'),
  ('MY','pcb_relief_disabled','2000-01-01',6000,'Du'),
  ('MY','pcb_relief_spouse_disabled','2000-01-01',5000,'Su'),
  ('MY','pcb_relief_child','2000-01-01',2000,'Q per child unit'),
  ('MY','ot_divisor_days','2000-01-01',26,'Employment Act: ordinary rate of pay = monthly / 26'),
  ('MY','ot_rate_normal','2000-01-01',1.5,'Overtime on a normal day'),
  ('MY','ot_rate_rest','2000-01-01',2.0,'Work on a rest day (per hour beyond normal hours)'),
  ('MY','ot_rate_ph','2000-01-01',3.0,'Overtime on a public holiday');

create or replace function public.stat(p_country char(2), p_key text, p_on date default current_date)
returns numeric language sql stable as $$
  select value from public.statutory_params where country = p_country and key = p_key and valid_from <= p_on
  order by valid_from desc limit 1;
$$;

-- PCB schedule (LHDN computerised method, Table 1). B already includes the RM400 / RM800 rebate.
create table public.pcb_brackets (
  valid_from_year int not null,
  p_from numeric not null,
  m numeric not null,
  r numeric not null,
  b_cat13 numeric not null,
  b_cat2 numeric not null,
  primary key (valid_from_year, p_from)
);
insert into public.pcb_brackets (valid_from_year, p_from, m, r, b_cat13, b_cat2) values
  (2023, 5001, 5000, 0.01, -400, -800),
  (2023, 20001, 20000, 0.03, -250, -650),
  (2023, 35001, 35000, 0.06, 600, 600),
  (2023, 50001, 50000, 0.11, 1500, 1500),
  (2023, 70001, 70000, 0.19, 3700, 3700),
  (2023, 100001, 100000, 0.25, 9400, 9400),
  (2023, 400001, 400000, 0.26, 84400, 84400),
  (2023, 600001, 600000, 0.28, 136400, 136400),
  (2023, 2000001, 2000000, 0.30, 528400, 528400);

-- SOCSO / EIS contribution bands. Generated from PERKESO's method (contribution on the band's
-- mid-point wage, rounded to the nearest 5 sen), e.g. top band RM5,900.01–6,000 → RM104.15 / RM29.75.
-- Replace with the official published table if any band differs.
create table public.statutory_bands (
  scheme text not null check (scheme in ('socso_1','socso_2','eis')),
  valid_from date not null,
  wage_from numeric(12,2) not null,
  wage_to numeric(12,2) not null,
  employer numeric(10,2) not null,
  employee numeric(10,2) not null,
  source text not null default 'generated',
  primary key (scheme, valid_from, wage_from)
);

create or replace function public.round5(v numeric) returns numeric language sql immutable as $$
  select floor(v * 20 + 0.5) / 20.0;
$$;

insert into public.statutory_bands (scheme, valid_from, wage_from, wage_to, employer, employee)
select s.scheme, '2024-10-01', b.lo, b.hi,
       round5(b.mid * s.er), round5(b.mid * s.ee)
from (values ('socso_1', 0.0175, 0.005), ('socso_2', 0.0125, 0.0), ('eis', 0.002, 0.002)) s(scheme, er, ee)
cross join lateral (
  select lo, hi, (lo + hi) / 2.0 as mid from (
    values (0.00, 30.00), (30.01, 50.00), (50.01, 70.00), (70.01, 100.00), (100.01, 140.00), (140.01, 200.00), (200.01, 300.00)
  ) x(lo, hi)
  union all
  select g + 0.01, g + 100, g + 50.005 from generate_series(300, 5900, 100) g
) b;
-- mid-point of RM100 bands is the round figure (e.g. 3,050), as in the published table
update public.statutory_bands set
  employer = round5(round((wage_from + wage_to) / 2) * case scheme when 'socso_1' then 0.0175 when 'socso_2' then 0.0125 else 0.002 end),
  employee = round5(round((wage_from + wage_to) / 2) * case scheme when 'socso_1' then 0.005 when 'socso_2' then 0 else 0.002 end)
where wage_from >= 300;

create or replace function public.band_contribution(p_scheme text, p_wage numeric, p_on date)
returns table (employer numeric, employee numeric) language sql stable as $$
  with v as (select max(valid_from) vf from public.statutory_bands where scheme = p_scheme and valid_from <= p_on)
  select b.employer, b.employee from public.statutory_bands b, v
  where b.scheme = p_scheme and b.valid_from = v.vf
    and (p_wage between b.wage_from and b.wage_to
         or (p_wage > (select max(wage_to) from public.statutory_bands where scheme = p_scheme and valid_from = v.vf)
             and b.wage_to = (select max(wage_to) from public.statutory_bands where scheme = p_scheme and valid_from = v.vf)))
  order by b.wage_from desc limit 1;
$$;

-- EPF (Third Schedule method): wages up to RM5,000 in RM20 bands, up to RM20,000 in RM100 bands,
-- contribution on the band's upper limit; above RM20,000 on actual wages; cents rounded up to the next ringgit.
create or replace function public.epf_contribution(p_wage numeric, p_citizenship text, p_age int, p_on date,
                                                  p_ee_override numeric default null, p_er_override numeric default null)
returns table (employee numeric, employer numeric) language plpgsql stable as $$
declare base numeric; ee numeric; er numeric;
begin
  if p_wage <= 10 then return query select 0::numeric, 0::numeric; return; end if;
  base := case when p_wage <= 5000 then ceil(p_wage / 20) * 20
               when p_wage <= 20000 then ceil(p_wage / 100) * 100
               else p_wage end;
  if p_citizenship = 'foreign' then
    ee := stat('MY','epf_foreign_rate',p_on); er := stat('MY','epf_foreign_rate',p_on);
    if ee is null then ee := 0; er := 0; end if;
  elsif p_age >= 60 then
    if p_citizenship = 'pr' then ee := stat('MY','epf_ee_rate_60_pr',p_on); er := stat('MY','epf_er_rate_60_pr',p_on);
    else ee := 0; er := stat('MY','epf_er_rate_60',p_on); end if;
  else
    ee := stat('MY','epf_ee_rate',p_on);
    er := case when p_wage <= 5000 then stat('MY','epf_er_rate_low',p_on) else stat('MY','epf_er_rate_high',p_on) end;
  end if;
  ee := greatest(ee, coalesce(p_ee_override, 0));
  er := greatest(er, coalesce(p_er_override, 0));
  return query select ceil(base * ee), ceil(base * er);
end $$;

-- PCB / MTD for one month (LHDN computerised method).
-- p_ytd_*: amounts already paid this year BEFORE this month (this employer + previous employer).
create or replace function public.pcb_mtd(
  p_year int, p_month int, p_category int, p_children numeric, p_disabled boolean, p_spouse_disabled boolean,
  p_y1 numeric, p_k1 numeric,                   -- this month: normal taxable pay, EPF on it
  p_yt numeric, p_kt numeric,                   -- this month: additional pay (bonus etc.), EPF on it
  p_ytd_gross numeric, p_ytd_epf numeric, p_ytd_pcb numeric, p_ytd_zakat numeric,
  p_lp_ytd numeric, p_lp1 numeric, p_zakat numeric)
returns jsonb language plpgsql stable as $$
declare
  n int := 12 - p_month;
  cap numeric := coalesce(stat('MY','epf_relief_cap', make_date(p_year,p_month,1)), 4000);
  k numeric := least(p_ytd_epf, cap);
  k1 numeric; kt numeric; k2 numeric;
  d numeric := stat('MY','pcb_relief_self', make_date(p_year,p_month,1));
  s numeric := case when p_category = 2 then stat('MY','pcb_relief_spouse', make_date(p_year,p_month,1)) else 0 end;
  du numeric := case when p_disabled then stat('MY','pcb_relief_disabled', make_date(p_year,p_month,1)) else 0 end;
  su numeric := case when p_spouse_disabled and p_category = 2 then stat('MY','pcb_relief_spouse_disabled', make_date(p_year,p_month,1)) else 0 end;
  qc numeric := case when p_category = 1 then 0 else stat('MY','pcb_relief_child', make_date(p_year,p_month,1)) * coalesce(p_children,0) end;
  reliefs numeric; p numeric; p_add numeric; br record; br2 record;
  mtd numeric := 0; mtd_add numeric := 0; yearly numeric; yearly_add numeric; net numeric;
begin
  k1 := least(p_k1, greatest(cap - k, 0));
  kt := least(p_kt, greatest(cap - k - k1, 0));
  k2 := case when n > 0 then least(greatest(cap - (k + k1 + kt), 0) / n, k1) else 0 end;
  k2 := trunc(k2, 2);
  reliefs := d + s + du + su + qc + coalesce(p_lp_ytd,0) + coalesce(p_lp1,0);
  p := (p_ytd_gross - k) + (p_y1 - k1) + (p_y1 - k2) * n - reliefs;

  if p > 5000 then
    select * into br from pcb_brackets where valid_from_year = (select max(valid_from_year) from pcb_brackets where valid_from_year <= p_year)
      and p_from <= p order by p_from desc limit 1;
    yearly := (p - br.m) * br.r + case when p_category = 2 then br.b_cat2 else br.b_cat13 end;
    mtd := trunc((yearly - (coalesce(p_ytd_zakat,0) + p_ytd_pcb)) / (n + 1), 2);
    if mtd < 10 then mtd := 0; end if;
  end if;

  if coalesce(p_yt,0) > 0 then
    -- additional remuneration: tax on the year with it, minus tax without it
    p_add := p + (p_yt - kt);
    select * into br2 from pcb_brackets where valid_from_year = (select max(valid_from_year) from pcb_brackets where valid_from_year <= p_year)
      and p_from <= p_add order by p_from desc limit 1;
    if br2.m is not null then
      yearly_add := (p_add - br2.m) * br2.r + case when p_category = 2 then br2.b_cat2 else br2.b_cat13 end;
      mtd_add := greatest(0, trunc(yearly_add - greatest(coalesce(yearly, 0), 0), 2));
    end if;
  end if;

  mtd := round(ceil(greatest(mtd, 0) * 20) / 20.0, 2);       -- round up to 5 sen
  mtd_add := round(ceil(greatest(mtd_add, 0) * 20) / 20.0, 2);
  net := round(greatest(0, mtd + mtd_add - coalesce(p_zakat, 0)), 2);
  return jsonb_build_object('P', round(p, 2), 'n', n, 'K1', k1, 'K2', k2, 'Kt', kt, 'reliefs', reliefs,
                            'yearly_tax', round(coalesce(yearly,0), 2), 'mtd_normal', mtd, 'mtd_additional', mtd_add,
                            'zakat', coalesce(p_zakat,0), 'pcb', net);
end $$;

-- ===== Payroll =====
create table public.payroll_runs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  year int not null check (year between 2020 and 2100),
  month int not null check (month between 1 and 12),
  status text not null default 'draft' check (status in ('draft','approved','paid')),
  pay_date date,
  approved_by uuid, approved_at timestamptz,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  unique (tenant_id, year, month)
);

create table public.payslips (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  run_id uuid not null references public.payroll_runs(id) on delete cascade,
  employee_id uuid not null references public.employees(id),
  basic numeric(12,2) not null default 0,
  gross numeric(12,2) not null default 0,         -- all earnings incl. OT, excl. claims
  epf_wages numeric(12,2) not null default 0,
  socso_wages numeric(12,2) not null default 0,
  taxable_normal numeric(12,2) not null default 0,
  taxable_additional numeric(12,2) not null default 0,
  epf_ee numeric(10,2) not null default 0, epf_er numeric(10,2) not null default 0,
  socso_ee numeric(10,2) not null default 0, socso_er numeric(10,2) not null default 0,
  eis_ee numeric(10,2) not null default 0, eis_er numeric(10,2) not null default 0,
  pcb numeric(10,2) not null default 0,
  zakat numeric(10,2) not null default 0,
  other_deductions numeric(12,2) not null default 0,
  claims numeric(12,2) not null default 0,
  net_pay numeric(12,2) not null default 0,
  employer_cost numeric(12,2) not null default 0,
  calc jsonb not null default '{}',               -- working shown to HR
  warnings text[] not null default '{}',
  unique (run_id, employee_id)
);

create table public.payslip_items (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  payslip_id uuid not null references public.payslips(id) on delete cascade,
  kind text not null check (kind in ('earning','deduction','claim')),
  code text not null default 'other',            -- basic, allowance, ot, bonus, commission, unpaid_leave, advance, claim…
  name text not null,
  amount numeric(12,2) not null,
  taxable boolean not null default true,
  additional boolean not null default false,     -- bonus/commission/arrears: PCB "additional remuneration"
  epf boolean not null default true,
  socso boolean not null default true,
  system boolean not null default false,         -- generated; rebuilt on recalculation
  sort_order int not null default 0
);

-- Build the system lines (basic, recurring items, OT, unpaid leave, claims) for one payslip
create or replace function public.payslip_build_items(p_payslip uuid)
returns void language plpgsql security definer set search_path = public as $$
declare ps payslips; run payroll_runs; e employees; pay employee_pay; m_start date; m_end date; days_in int;
  emp_from date; emp_to date; v_basic numeric; orp numeric; hrp numeric; ul numeric; it record; c record;
  normal_mins int; ot_n numeric; rest_amt numeric; rest_mins numeric; ph_amt numeric; ph_mins numeric;
  hours numeric; daysw int;
begin
  select * into ps from payslips where id = p_payslip;
  select * into run from payroll_runs where id = ps.run_id;
  select * into e from employees where id = ps.employee_id;
  select * into pay from employee_pay where employee_id = e.id;
  m_start := make_date(run.year, run.month, 1);
  m_end := (m_start + interval '1 month - 1 day')::date;
  days_in := m_end - m_start + 1;
  emp_from := greatest(m_start, e.start_date);
  emp_to := least(m_end, coalesce(e.end_date, m_end));

  delete from payslip_items where payslip_id = ps.id and system;

  if pay.pay_basis = 'monthly' then
    v_basic := round(pay.basic_salary * (emp_to - emp_from + 1) / days_in, 2);
    insert into payslip_items (tenant_id, payslip_id, kind, code, name, amount, system, sort_order)
    values (ps.tenant_id, ps.id, 'earning', 'basic',
            'Basic salary' || case when emp_from > m_start or emp_to < m_end then ' (' || (emp_to - emp_from + 1) || '/' || days_in || ' days)' else '' end,
            v_basic, true, 0);
  elsif pay.pay_basis = 'daily' then
    select count(distinct work_date) into daysw from attendance where employee_id = e.id and work_date between m_start and m_end and clock_out is not null;
    insert into payslip_items (tenant_id, payslip_id, kind, code, name, amount, system, sort_order)
    values (ps.tenant_id, ps.id, 'earning', 'basic', 'Daily pay (' || daysw || ' days)', round(daysw * coalesce(pay.daily_rate,0), 2), true, 0);
  else
    select coalesce(sum(worked_minutes - ot_minutes),0) / 60.0 into hours from attendance
    where employee_id = e.id and work_date between m_start and m_end and clock_out is not null;
    insert into payslip_items (tenant_id, payslip_id, kind, code, name, amount, system, sort_order)
    values (ps.tenant_id, ps.id, 'earning', 'basic', 'Hourly pay (' || round(hours,2) || ' h)', round(hours * coalesce(pay.hourly_rate,0), 2), true, 0);
  end if;

  for it in select * from employee_pay_items where employee_id = e.id and active
              and (start_on is null or start_on <= m_end) and (end_on is null or end_on >= m_start) loop
    insert into payslip_items (tenant_id, payslip_id, kind, code, name, amount, taxable, epf, socso, system, sort_order)
    values (ps.tenant_id, ps.id, it.kind, case when it.kind = 'earning' then 'allowance' else 'deduction' end,
            it.name, it.amount, it.taxable, it.epf, it.socso, true, 10);
  end loop;

  -- overtime & rest-day / public-holiday work (Employment Act 1955, s.60–60D):
  --   ORP = monthly / 26; HRP = ORP / normal daily hours
  --   normal day: hours beyond normal × HRP × 1.5
  --   rest day:   up to half normal hours = ½ ORP; up to normal hours = 1 ORP; beyond normal hours × HRP × 2
  --   public holiday: any work within normal hours = 2 ORP extra; beyond normal hours × HRP × 3
  if pay.ot_eligible then
    orp := case pay.pay_basis when 'monthly' then pay.basic_salary / stat('MY','ot_divisor_days', m_start)
                              when 'daily' then coalesce(pay.daily_rate,0) else coalesce(pay.hourly_rate,0) * 8 end;
    normal_mins := greatest(60, (extract(epoch from (e.shift_end - e.shift_start)) / 60 - e.break_minutes)::int);
    hrp := orp / (normal_mins / 60.0);
    select
      coalesce(sum(case when day_type = 'normal' then ot_approved_minutes end),0),
      coalesce(sum(case when day_type = 'rest_day' then
         (case when least(ot_approved_minutes, normal_mins) = 0 then 0
               when least(ot_approved_minutes, normal_mins) <= normal_mins / 2 then 0.5 * orp else orp end)
         + greatest(ot_approved_minutes - normal_mins, 0) / 60.0 * hrp * stat('MY','ot_rate_rest', m_start) end),0),
      coalesce(sum(case when day_type = 'rest_day' then ot_approved_minutes end),0),
      coalesce(sum(case when day_type = 'public_holiday' then
         (case when least(ot_approved_minutes, normal_mins) > 0 then 2 * orp else 0 end)
         + greatest(ot_approved_minutes - normal_mins, 0) / 60.0 * hrp * stat('MY','ot_rate_ph', m_start) end),0),
      coalesce(sum(case when day_type = 'public_holiday' then ot_approved_minutes end),0)
      into ot_n, rest_amt, rest_mins, ph_amt, ph_mins
    from attendance where employee_id = e.id and work_date between m_start and m_end and ot_approved_minutes > 0;
    if ot_n > 0 then
      insert into payslip_items (tenant_id, payslip_id, kind, code, name, amount, epf, system, sort_order)
      values (ps.tenant_id, ps.id, 'earning', 'ot', 'Overtime ' || round(ot_n / 60.0, 2) || ' h × 1.5',
              round(ot_n / 60.0 * hrp * stat('MY','ot_rate_normal', m_start), 2), false, true, 20);
    end if;
    if rest_amt > 0 then
      insert into payslip_items (tenant_id, payslip_id, kind, code, name, amount, epf, system, sort_order)
      values (ps.tenant_id, ps.id, 'earning', 'ot', 'Rest-day work ' || round(rest_mins / 60.0, 2) || ' h', round(rest_amt, 2), false, true, 21);
    end if;
    if ph_amt > 0 then
      insert into payslip_items (tenant_id, payslip_id, kind, code, name, amount, epf, system, sort_order)
      values (ps.tenant_id, ps.id, 'earning', 'ot', 'Public holiday work ' || round(ph_mins / 60.0, 2) || ' h', round(ph_amt, 2), false, true, 22);
    end if;
  end if;

  -- unpaid leave days in this month
  if pay.pay_basis = 'monthly' then
    select coalesce(sum(case when r.half_day is not null then 0.5
                             else working_days(e.id, greatest(r.start_date, m_start), least(r.end_date, m_end)) end), 0)
      into ul
    from leave_requests r join leave_types lt on lt.id = r.leave_type_id
    where r.employee_id = e.id and r.status = 'approved' and not lt.paid
      and r.start_date <= m_end and r.end_date >= m_start;
    if ul > 0 then
      insert into payslip_items (tenant_id, payslip_id, kind, code, name, amount, system, sort_order)
      values (ps.tenant_id, ps.id, 'deduction', 'unpaid_leave', 'Unpaid leave ' || ul || ' day(s)',
              round(pay.basic_salary / stat('MY','ot_divisor_days', m_start) * ul, 2), true, 30);
    end if;
  end if;

  -- approved claims not yet paid
  for c in select * from claims where employee_id = e.id and status = 'approved' and (payslip_id is null or payslip_id = ps.id) loop
    insert into payslip_items (tenant_id, payslip_id, kind, code, name, amount, taxable, epf, socso, system, sort_order)
    values (ps.tenant_id, ps.id, 'claim', 'claim', 'Claim: ' || c.description, c.amount, false, false, false, true, 40);
    update claims set payslip_id = ps.id where id = c.id;
  end loop;
end $$;

-- Work out statutory amounts and totals from the payslip's lines
create or replace function public.payslip_calc(p_payslip uuid)
returns void language plpgsql security definer set search_path = public as $$
declare ps payslips; run payroll_runs; e employees; pv employee_private; pay employee_pay; v_on date; v_age int;
  v_gross numeric; v_epf_w numeric; v_socso_w numeric; v_tax_n numeric; v_tax_a numeric; v_ded numeric; v_claims numeric;
  v_epf record; so_ee numeric := 0; so_er numeric := 0; ei_ee numeric := 0; ei_er numeric := 0; v_cat text; v_pcb jsonb; v_warn text[] := '{}';
  ytd_gross numeric; ytd_epf numeric; ytd_pcb numeric; ytd_zakat numeric; ytd_lp numeric; v_minw numeric; v_k_normal numeric; v_k_add numeric;
begin
  select * into ps from payslips where id = p_payslip;
  select * into run from payroll_runs where id = ps.run_id;
  select * into e from employees where id = ps.employee_id;
  select * into pv from employee_private where employee_id = e.id;
  select * into pay from employee_pay where employee_id = e.id;
  v_on := (make_date(run.year, run.month, 1) + interval '1 month - 1 day')::date;
  v_age := case when pv.date_of_birth is null then 30 else extract(year from age(v_on, pv.date_of_birth))::int end;
  if pv.date_of_birth is null then v_warn := array_append(v_warn, 'Date of birth missing — assumed under 60'); end if;

  select coalesce(sum(amount) filter (where kind = 'earning'),0),
         coalesce(sum(amount) filter (where kind = 'earning' and epf),0) - coalesce(sum(amount) filter (where kind = 'deduction' and code = 'unpaid_leave'),0),
         coalesce(sum(amount) filter (where kind = 'earning' and socso),0) - coalesce(sum(amount) filter (where kind = 'deduction' and code = 'unpaid_leave'),0),
         coalesce(sum(amount) filter (where kind = 'earning' and taxable and not additional),0) - coalesce(sum(amount) filter (where kind = 'deduction' and code = 'unpaid_leave'),0),
         coalesce(sum(amount) filter (where kind = 'earning' and taxable and additional),0),
         coalesce(sum(amount) filter (where kind = 'deduction'),0),
         coalesce(sum(amount) filter (where kind = 'claim'),0)
    into v_gross, v_epf_w, v_socso_w, v_tax_n, v_tax_a, v_ded, v_claims
  from payslip_items where payslip_id = ps.id;
  v_epf_w := greatest(v_epf_w, 0); v_socso_w := greatest(v_socso_w, 0); v_tax_n := greatest(v_tax_n, 0);

  select * into v_epf from epf_contribution(v_epf_w, pv.citizenship, v_age, v_on, pay.epf_ee_rate, pay.epf_er_rate);
  -- EPF split between normal and additional pay (for PCB's K1 / Kt)
  select employee into v_k_normal from epf_contribution(greatest(v_epf_w - (select coalesce(sum(amount),0) from payslip_items where payslip_id = ps.id and kind = 'earning' and epf and additional), 0),
                                                      pv.citizenship, v_age, v_on, pay.epf_ee_rate, pay.epf_er_rate);
  v_k_add := greatest(v_epf.employee - v_k_normal, 0);

  v_cat := case when pv.citizenship = 'foreign' or v_age >= 60 then 'socso_2' else 'socso_1' end;
  if pay.socso_enabled then
    select coalesce(b.employee,0), coalesce(b.employer,0) into so_ee, so_er from band_contribution(v_cat, v_socso_w, v_on) b;
  end if;
  if pay.eis_enabled and pv.citizenship <> 'foreign' and v_age between 18 and 59 then
    select coalesce(b.employee,0), coalesce(b.employer,0) into ei_ee, ei_er from band_contribution('eis', v_socso_w, v_on) b;
  end if;

  -- year-to-date before this month (this business), plus previous employer for the same year
  select coalesce(sum(p.taxable_normal + p.taxable_additional),0), coalesce(sum(p.epf_ee),0), coalesce(sum(p.pcb),0), coalesce(sum(p.zakat),0)
    into ytd_gross, ytd_epf, ytd_pcb, ytd_zakat
  from payslips p join payroll_runs r on r.id = p.run_id
  where p.employee_id = e.id and r.year = run.year and r.month < run.month and r.status <> 'draft';
  if pay.prev_year = run.year then
    ytd_gross := ytd_gross + pay.prev_gross; ytd_epf := ytd_epf + pay.prev_epf;
    ytd_pcb := ytd_pcb + pay.prev_pcb; ytd_zakat := ytd_zakat + pay.prev_zakat;
  end if;
  ytd_lp := pay.other_reliefs_monthly * (run.month - 1);

  if pay.pcb_enabled and pv.citizenship <> 'foreign' then
    v_pcb := pcb_mtd(run.year, run.month, pay.tax_category, pay.qualifying_children, pay.disabled, pay.spouse_disabled,
                   v_tax_n, least(v_k_normal, v_epf.employee), v_tax_a, v_k_add, ytd_gross, ytd_epf, ytd_pcb, ytd_zakat,
                   ytd_lp, pay.other_reliefs_monthly, pay.zakat_monthly);
  else
    v_pcb := jsonb_build_object('pcb', 0);
    if pv.citizenship = 'foreign' and pay.pcb_enabled then
      v_warn := array_append(v_warn, 'Non-resident tax (flat rate) is not calculated automatically — enter it as a deduction');
    end if;
  end if;

  v_minw := stat('MY','minimum_wage_monthly', v_on);
  if pay.pay_basis = 'monthly' and e.employment_type = 'full_time' and pay.basic_salary < v_minw then
    v_warn := array_append(v_warn, ('Basic salary is below the minimum wage of RM' || v_minw));
  end if;
  if pay.tax_no is null and (v_pcb->>'pcb')::numeric > 0 then v_warn := array_append(v_warn, 'Income tax number missing'); end if;

  update payslips set
    basic = coalesce((select sum(amount) from payslip_items where payslip_id = ps.id and code = 'basic'),0),
    gross = v_gross, epf_wages = v_epf_w, socso_wages = v_socso_w, taxable_normal = v_tax_n, taxable_additional = v_tax_a,
    epf_ee = v_epf.employee, epf_er = v_epf.employer,
    socso_ee = coalesce(so_ee,0), socso_er = coalesce(so_er,0),
    eis_ee = coalesce(ei_ee,0), eis_er = coalesce(ei_er,0),
    pcb = (v_pcb->>'pcb')::numeric,
    zakat = case when pay.pcb_enabled then least(pay.zakat_monthly, coalesce((v_pcb->>'mtd_normal')::numeric,0) + coalesce((v_pcb->>'mtd_additional')::numeric,0)) else 0 end,
    other_deductions = v_ded, claims = v_claims,
    net_pay = v_gross - v_ded - v_epf.employee - coalesce(so_ee,0) - coalesce(ei_ee,0) - (v_pcb->>'pcb')::numeric
              - case when pay.pcb_enabled then least(pay.zakat_monthly, coalesce((v_pcb->>'mtd_normal')::numeric,0) + coalesce((v_pcb->>'mtd_additional')::numeric,0)) else 0 end
              + v_claims,
    employer_cost = v_gross - coalesce((select sum(amount) from payslip_items where payslip_id = ps.id and code = 'unpaid_leave'),0)
                    + v_epf.employer + coalesce(so_er,0) + coalesce(ei_er,0),
    calc = jsonb_build_object('age', v_age, 'socso_category', v_cat, 'pcb', v_pcb),
    warnings = v_warn
  where id = ps.id;
  -- unpaid leave reduces pay but was counted in 'ded'; gross shown before it
end $$;

create or replace function public.payroll_run_guard(p_run uuid)
returns payroll_runs language plpgsql security definer set search_path = public as $$
declare r payroll_runs;
begin
  select * into r from payroll_runs where id = p_run;
  if not found then raise exception 'Unknown payroll run'; end if;
  if not has_perm(r.tenant_id, 'hr.payroll.run') then raise exception 'Not allowed'; end if;
  return r;
end $$;

create or replace function public.create_payroll_run(p_tenant uuid, p_year int, p_month int, p_pay_date date default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare rid uuid; e record; m_start date := make_date(p_year, p_month, 1); m_end date;
begin
  if not has_perm(p_tenant, 'hr.payroll.run') then raise exception 'Not allowed'; end if;
  m_end := (m_start + interval '1 month - 1 day')::date;
  if exists (select 1 from payroll_runs where tenant_id = p_tenant and status = 'draft' and (year, month) < (p_year, p_month)) then
    raise exception 'Approve the earlier draft payroll first';
  end if;
  if exists (select 1 from payroll_runs where tenant_id = p_tenant and status <> 'draft' and (year, month) > (p_year, p_month)) then
    raise exception 'A later month is already approved — add missed pay to the next payroll instead';
  end if;
  insert into payroll_runs (tenant_id, year, month, pay_date) values (p_tenant, p_year, p_month, coalesce(p_pay_date, m_end))
  on conflict (tenant_id, year, month) do nothing returning id into rid;
  if rid is null then raise exception 'Payroll for %/% already exists', p_month, p_year; end if;
  for e in select id from employees where tenant_id = p_tenant and start_date <= m_end and (end_date is null or end_date >= m_start)
             and status in ('active','resigned','terminated','retired') loop
    insert into payslips (tenant_id, run_id, employee_id) values (p_tenant, rid, e.id);
  end loop;
  perform recalc_payroll_run(rid);
  return rid;
end $$;

create or replace function public.recalc_payroll_run(p_run uuid)
returns int language plpgsql security definer set search_path = public as $$
declare r payroll_runs; ps record; n int := 0;
begin
  r := payroll_run_guard(p_run);
  if r.status <> 'draft' then raise exception 'Payroll is already %', r.status; end if;
  for ps in select id from payslips where run_id = r.id loop
    perform payslip_build_items(ps.id);
    perform payslip_calc(ps.id);
    n := n + 1;
  end loop;
  return n;
end $$;

-- Manual lines (bonus, commission, advance…) — recalculates that payslip
create or replace function public.add_payslip_item(p_payslip uuid, p_kind text, p_code text, p_name text, p_amount numeric,
                                                   p_taxable boolean default true, p_additional boolean default false,
                                                   p_epf boolean default true, p_socso boolean default true)
returns void language plpgsql security definer set search_path = public as $$
declare ps payslips; r payroll_runs;
begin
  select * into ps from payslips where id = p_payslip;
  r := payroll_run_guard(ps.run_id);
  if r.status <> 'draft' then raise exception 'Payroll is already %', r.status; end if;
  if p_amount <= 0 then raise exception 'Amount must be positive'; end if;
  insert into payslip_items (tenant_id, payslip_id, kind, code, name, amount, taxable, additional, epf, socso, sort_order)
  values (ps.tenant_id, ps.id, p_kind, p_code, p_name, round(p_amount, 2), p_taxable, p_additional, p_epf, p_socso, 50);
  perform payslip_calc(ps.id);
end $$;

create or replace function public.remove_payslip_item(p_item uuid)
returns void language plpgsql security definer set search_path = public as $$
declare it payslip_items; ps payslips; r payroll_runs;
begin
  select * into it from payslip_items where id = p_item;
  select * into ps from payslips where id = it.payslip_id;
  r := payroll_run_guard(ps.run_id);
  if r.status <> 'draft' then raise exception 'Payroll is already %', r.status; end if;
  if it.system then raise exception 'Change this in the employee set-up, attendance or leave, then recalculate'; end if;
  delete from payslip_items where id = it.id;
  perform payslip_calc(ps.id);
end $$;

create or replace function public.ensure_chart(p_tenant uuid)
returns void language sql security definer set search_path = public as $$
  insert into accounts (tenant_id, code, name, type, is_system) values
    (p_tenant,'1000','Cash on hand','asset',true),
    (p_tenant,'1010','Card & e-payment clearing','asset',true),
    (p_tenant,'1020','Bank','asset',true),
    (p_tenant,'1100','Accounts receivable','asset',true),
    (p_tenant,'1200','Inventory','asset',true),
    (p_tenant,'1300','Staff advances','asset',true),
    (p_tenant,'2100','Tax payable','liability',true),
    (p_tenant,'2200','Accounts payable','liability',true),
    (p_tenant,'2300','Salaries payable','liability',true),
    (p_tenant,'2310','EPF payable','liability',true),
    (p_tenant,'2320','SOCSO & EIS payable','liability',true),
    (p_tenant,'2330','PCB (income tax) payable','liability',true),
    (p_tenant,'3000','Owner''s equity','equity',true),
    (p_tenant,'3100','Retained earnings','equity',true),
    (p_tenant,'4000','Sales','income',true),
    (p_tenant,'4100','Other income','income',true),
    (p_tenant,'5000','Cost of goods sold','expense',true),
    (p_tenant,'5100','Freight & logistics costs','expense',true),
    (p_tenant,'6000','Operating expenses','expense',true),
    (p_tenant,'6100','Inventory adjustments & losses','expense',true),
    (p_tenant,'6200','Loyalty rewards','expense',true),
    (p_tenant,'6300','Salaries & wages','expense',true),
    (p_tenant,'6310','Employer EPF, SOCSO & EIS','expense',true),
    (p_tenant,'6400','Staff claims','expense',true)
  on conflict (tenant_id, code) do nothing;
$$;

-- Approve: lock and post to the books
--   Dr Salaries & wages (gross − unpaid leave)   Dr Employer statutory   Dr Staff claims
--   Cr Salaries payable (net)  Cr EPF payable  Cr SOCSO & EIS payable  Cr PCB payable  Cr Staff advances (deductions)
create or replace function public.approve_payroll_run(p_run uuid)
returns void language plpgsql security definer set search_path = public as $$
declare r payroll_runs; t record; zakat_t numeric;
begin
  r := payroll_run_guard(p_run);
  if r.status <> 'draft' then raise exception 'Payroll is already %', r.status; end if;
  perform recalc_payroll_run(r.id);
  select coalesce(sum(p.gross),0) g,
         coalesce(sum((select coalesce(sum(i.amount),0) from payslip_items i where i.payslip_id = p.id and i.code = 'unpaid_leave')),0) ul,
         coalesce(sum(p.other_deductions),0) ded,
         coalesce(sum(p.epf_ee),0) epf_ee, coalesce(sum(p.epf_er),0) epf_er,
         coalesce(sum(p.socso_ee + p.eis_ee),0) se_ee, coalesce(sum(p.socso_er + p.eis_er),0) se_er,
         coalesce(sum(p.pcb),0) pcb, coalesce(sum(p.zakat),0) zakat, coalesce(sum(p.claims),0) claims, coalesce(sum(p.net_pay),0) net
    into t from payslips p where p.run_id = r.id;
  if exists (select 1 from payslips where run_id = r.id and net_pay < 0) then raise exception 'A payslip has negative net pay'; end if;
  perform post_entry(r.tenant_id, coalesce(r.pay_date, current_date), 'Payroll ' || r.month || '/' || r.year, 'payroll', r.id, jsonb_build_array(
    jsonb_build_object('code','6300','debit', t.g - t.ul),
    jsonb_build_object('code','6310','debit', t.epf_er + t.se_er),
    jsonb_build_object('code','6400','debit', t.claims),
    jsonb_build_object('code','2300','credit', t.net + t.zakat),     -- zakat is paid on the employee's behalf with net pay
    jsonb_build_object('code','2310','credit', t.epf_ee + t.epf_er),
    jsonb_build_object('code','2320','credit', t.se_ee + t.se_er),
    jsonb_build_object('code','2330','credit', t.pcb),
    jsonb_build_object('code','1300','credit', t.ded - t.ul)));
  update payroll_runs set status = 'approved', approved_by = auth.uid(), approved_at = now() where id = r.id;
  update claims set status = 'paid' where payslip_id in (select id from payslips where run_id = r.id) and status = 'approved';
end $$;

create or replace function public.mark_payroll_paid(p_run uuid, p_paid_on date default current_date)
returns void language plpgsql security definer set search_path = public as $$
declare r payroll_runs; net numeric;
begin
  r := payroll_run_guard(p_run);
  if r.status <> 'approved' then raise exception 'Approve the payroll first'; end if;
  select coalesce(sum(net_pay + zakat),0) into net from payslips where run_id = r.id;
  perform post_entry(r.tenant_id, p_paid_on, 'Salaries paid ' || r.month || '/' || r.year, 'payroll_paid', r.id, jsonb_build_array(
    jsonb_build_object('code','2300','debit', net), jsonb_build_object('code','1020','credit', net)));
  update payroll_runs set status = 'paid', paid_at = now() where id = r.id;
end $$;

-- Pay EPF / SOCSO+EIS / PCB to the authorities for a run
create or replace function public.pay_statutory(p_run uuid, p_scheme text, p_paid_on date default current_date)
returns numeric language plpgsql security definer set search_path = public as $$
declare r payroll_runs; amt numeric; acct text;
begin
  r := payroll_run_guard(p_run);
  if r.status = 'draft' then raise exception 'Approve the payroll first'; end if;
  select case p_scheme when 'epf' then sum(epf_ee + epf_er) when 'socso_eis' then sum(socso_ee + socso_er + eis_ee + eis_er)
                       when 'pcb' then sum(pcb) end into amt from payslips where run_id = r.id;
  acct := case p_scheme when 'epf' then '2310' when 'socso_eis' then '2320' when 'pcb' then '2330' end;
  if acct is null then raise exception 'Unknown scheme'; end if;
  if exists (select 1 from journal_entries where source_type = 'statutory_' || p_scheme and source_id = r.id) then
    raise exception 'Already recorded as paid';
  end if;
  perform post_entry(r.tenant_id, p_paid_on, upper(p_scheme) || ' paid ' || r.month || '/' || r.year, 'statutory_' || p_scheme, r.id,
    jsonb_build_array(jsonb_build_object('code', acct, 'debit', amt), jsonb_build_object('code','1020','credit', amt)));
  return amt;
end $$;

create or replace view public.payroll_run_summary with (security_invoker = true) as
select r.*, count(p.id) as headcount,
  coalesce(sum(p.gross),0) as gross, coalesce(sum(p.net_pay),0) as net,
  coalesce(sum(p.epf_ee + p.epf_er),0) as epf, coalesce(sum(p.socso_ee + p.socso_er),0) as socso,
  coalesce(sum(p.eis_ee + p.eis_er),0) as eis, coalesce(sum(p.pcb),0) as pcb,
  coalesce(sum(p.employer_cost),0) as employer_cost,
  count(*) filter (where cardinality(p.warnings) > 0) as warnings,
  exists (select 1 from journal_entries j where j.source_type = 'statutory_epf' and j.source_id = r.id) as epf_paid,
  exists (select 1 from journal_entries j where j.source_type = 'statutory_socso_eis' and j.source_id = r.id) as socso_paid,
  exists (select 1 from journal_entries j where j.source_type = 'statutory_pcb' and j.source_id = r.id) as pcb_paid
from payroll_runs r left join payslips p on p.run_id = r.id
group by r.id;

-- ===== RLS =====
alter table public.employees enable row level security;
create policy emp_read on public.employees for select using (has_perm(tenant_id, 'hr.employee.view') or user_id = auth.uid());
create policy emp_write on public.employees for all
  using (has_perm(tenant_id, 'hr.employee.manage')) with check (has_perm(tenant_id, 'hr.employee.manage'));

alter table public.employee_private enable row level security;
create policy emp_priv_read on public.employee_private for select using (has_perm(tenant_id, 'hr.employee.manage') or is_self_employee(employee_id));
create policy emp_priv_write on public.employee_private for update
  using (has_perm(tenant_id, 'hr.employee.manage')) with check (has_perm(tenant_id, 'hr.employee.manage'));

alter table public.employee_pay enable row level security;
create policy emp_pay_read on public.employee_pay for select using (has_perm(tenant_id, 'hr.payroll.run') or has_perm(tenant_id, 'hr.employee.manage'));
create policy emp_pay_write on public.employee_pay for update
  using (has_perm(tenant_id, 'hr.payroll.run') or has_perm(tenant_id, 'hr.employee.manage'))
  with check (has_perm(tenant_id, 'hr.payroll.run') or has_perm(tenant_id, 'hr.employee.manage'));

alter table public.employee_pay_items enable row level security;
create policy emp_items_rw on public.employee_pay_items for all
  using (has_perm(tenant_id, 'hr.payroll.run')) with check (has_perm(tenant_id, 'hr.payroll.run'));

alter table public.public_holidays enable row level security;
create policy holidays_read on public.public_holidays for select using (is_member(tenant_id));
create policy holidays_write on public.public_holidays for all
  using (has_perm(tenant_id, 'hr.employee.manage')) with check (has_perm(tenant_id, 'hr.employee.manage'));

alter table public.attendance enable row level security;
create policy att_read on public.attendance for select using (has_perm(tenant_id, 'hr.employee.view') or is_self_employee(employee_id));
create policy att_write on public.attendance for all
  using (has_perm(tenant_id, 'hr.attendance.manage')) with check (has_perm(tenant_id, 'hr.attendance.manage'));

alter table public.leave_types enable row level security;
create policy lt_read on public.leave_types for select using (is_member(tenant_id));
create policy lt_write on public.leave_types for all
  using (has_perm(tenant_id, 'hr.employee.manage')) with check (has_perm(tenant_id, 'hr.employee.manage'));

alter table public.leave_adjustments enable row level security;
create policy la_read on public.leave_adjustments for select using (has_perm(tenant_id, 'hr.employee.view') or is_self_employee(employee_id));
create policy la_write on public.leave_adjustments for insert with check (has_perm(tenant_id, 'hr.employee.manage'));

alter table public.leave_requests enable row level security;
create policy lr_read on public.leave_requests for select
  using (has_perm(tenant_id, 'hr.employee.view') or has_perm(tenant_id, 'hr.leave.approve') or is_self_employee(employee_id));

alter table public.claims enable row level security;
create policy claims_read on public.claims for select
  using (has_perm(tenant_id, 'hr.claim.approve') or has_perm(tenant_id, 'hr.payroll.run') or is_self_employee(employee_id));
create policy claims_self_cancel on public.claims for update
  using (is_self_employee(employee_id) and status = 'pending') with check (status in ('pending','cancelled'));

alter table public.payroll_runs enable row level security;
create policy runs_read on public.payroll_runs for select using (has_perm(tenant_id, 'hr.payroll.run') or has_perm(tenant_id, 'hr.payroll.view'));

alter table public.payslips enable row level security;
create or replace function public.run_released(p_run uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from payroll_runs where id = p_run and status <> 'draft');
$$;
create policy payslips_read on public.payslips for select
  using (has_perm(tenant_id, 'hr.payroll.run') or has_perm(tenant_id, 'hr.payroll.view')
         or (is_self_employee(employee_id) and run_released(run_id)));
create policy runs_self_read on public.payroll_runs for select
  using (status <> 'draft' and exists (select 1 from employees e where e.tenant_id = payroll_runs.tenant_id and e.user_id = auth.uid()));

alter table public.payslip_items enable row level security;
create policy payslip_items_read on public.payslip_items for select
  using (exists (select 1 from payslips p where p.id = payslip_id));

alter table public.statutory_params enable row level security;
alter table public.pcb_brackets enable row level security;
alter table public.statutory_bands enable row level security;
create policy stat_read on public.statutory_params for select to authenticated using (true);
create policy pcb_read on public.pcb_brackets for select to authenticated using (true);
create policy bands_read on public.statutory_bands for select to authenticated using (true);

do $$ declare t text; begin
  foreach t in array array['employees','employee_pay','employee_pay_items','attendance','leave_requests','claims','payroll_runs','payslip_items'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- New and existing businesses get the standard leave types
create or replace function public.tenant_hr_init()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  perform ensure_leave_types(new.id);
  return null;
end $$;
create trigger trg_tenant_hr_init after insert on public.tenants for each row execute function public.tenant_hr_init();
do $$ declare t record; begin
  for t in select id from public.tenants loop perform public.ensure_leave_types(t.id); end loop;
end $$;

update public.templates set bundle = jsonb_set(bundle, '{modules}', (bundle->'modules') || '"HR"')
where code in ('retail','cafe','services','kids_care','logistics','wholesale') and not (bundle->'modules' ? 'HR');
