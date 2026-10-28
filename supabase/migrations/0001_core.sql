-- Ai buddy Biz — Batch A core schema
-- Tenants, outlets, memberships, roles/permissions, modules,
-- custom fields, workflows, audit log, AI usage log. RLS on everything.

create extension if not exists pgcrypto;

-- ===== Tenants & outlets =====
create table public.tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  industry_template text,
  country_code char(2) not null default 'MY',
  base_currency char(3) not null default 'MYR',
  plan text not null default 'free' check (plan in ('free','starter','growth','pro','enterprise')),
  created_at timestamptz not null default now()
);

create table public.outlets (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  kind text not null default 'store' check (kind in ('store','warehouse','kitchen','office','kids_centre','port','other')),
  address jsonb,
  timezone text not null default 'Asia/Kuala_Lumpur',
  created_at timestamptz not null default now()
);

-- ===== Roles & permissions =====
create table public.permissions (
  code text primary key,           -- e.g. 'pos.sale.void'
  module text not null,
  description text
);

create table public.roles (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid references public.tenants(id) on delete cascade, -- null = built-in
  name text not null,
  is_builtin boolean not null default false,
  unique (tenant_id, name)
);

create table public.role_permissions (
  role_id uuid not null references public.roles(id) on delete cascade,
  permission_code text not null references public.permissions(code) on delete cascade,
  primary key (role_id, permission_code)
);

create table public.memberships (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role_id uuid not null references public.roles(id),
  outlet_ids uuid[],               -- null = all outlets
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (tenant_id, user_id)
);

-- ===== Modules =====
create table public.tenant_modules (
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  module text not null check (module in ('POS','INV','FIN','CRM','LOG','HR','LAW','KIDS','EXT','AI')),
  enabled boolean not null default true,
  settings jsonb not null default '{}',
  primary key (tenant_id, module)
);

-- ===== Customisation engine =====
create table public.custom_field_defs (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  entity text not null,            -- 'customer','product','shipment','child','employee',...
  key text not null,
  label text not null,
  field_type text not null check (field_type in
    ('text','number','money','date','dropdown','multiselect','file','signature','barcode','lookup','boolean')),
  options jsonb,                   -- dropdown choices, lookup target, validation
  required boolean not null default false,
  sort_order int not null default 0,
  unique (tenant_id, entity, key)
);

create table public.workflows (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  name text not null,
  trigger jsonb not null,          -- {type:'record.updated', entity:'invoice', field:'status'}
  conditions jsonb not null default '[]',
  actions jsonb not null,          -- [{type:'whatsapp', to:'{{customer.phone}}', template:'...'}]
  enabled boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.templates (
  code text primary key,           -- 'cafe','retail','logistics','kids_care',...
  name text not null,
  bundle jsonb not null            -- modules, fields, workflows, roles, layouts
);

-- ===== Audit & AI logs =====
create table public.audit_log (
  id bigint generated always as identity primary key,
  tenant_id uuid not null,
  user_id uuid,
  table_name text not null,
  row_id text,
  action text not null check (action in ('INSERT','UPDATE','DELETE')),
  before jsonb,
  after jsonb,
  at timestamptz not null default now()
);
create index on public.audit_log (tenant_id, at desc);

create table public.ai_usage (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references public.tenants(id) on delete cascade,
  user_id uuid,
  feature text not null,
  input_tokens int,
  output_tokens int,
  cost_usd numeric(10,5),
  proposed_action jsonb,
  confirmed boolean,
  at timestamptz not null default now()
);

-- ===== Helper functions =====
create or replace function public.is_member(t uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from memberships
                 where tenant_id = t and user_id = auth.uid() and active);
$$;

create or replace function public.has_perm(t uuid, perm text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from memberships m
    join role_permissions rp on rp.role_id = m.role_id
    where m.tenant_id = t and m.user_id = auth.uid() and m.active
      and rp.permission_code = perm);
$$;

-- Generic audit trigger
create or replace function public.audit_trigger()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into audit_log (tenant_id, user_id, table_name, row_id, action, before, after)
  values (
    coalesce((case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'tenant_id',
             (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'id')::uuid,
    auth.uid(), tg_table_name,
    (case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end)->>'id',
    tg_op,
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end);
  return coalesce(new, old);
end $$;

do $$ declare t text; begin
  foreach t in array array['tenants','outlets','roles','memberships','tenant_modules','custom_field_defs','workflows'] loop
    execute format('create trigger audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function public.audit_trigger()', t);
  end loop;
end $$;

-- ===== Row Level Security =====
alter table public.tenants enable row level security;
alter table public.outlets enable row level security;
alter table public.roles enable row level security;
alter table public.role_permissions enable row level security;
alter table public.memberships enable row level security;
alter table public.tenant_modules enable row level security;
alter table public.custom_field_defs enable row level security;
alter table public.workflows enable row level security;
alter table public.audit_log enable row level security;
alter table public.ai_usage enable row level security;
alter table public.permissions enable row level security;
alter table public.templates enable row level security;

create policy read_perms on public.permissions for select to authenticated using (true);
create policy read_templates on public.templates for select to authenticated using (true);

create policy tenant_read on public.tenants for select using (is_member(id));
create policy tenant_admin on public.tenants for update using (has_perm(id, 'core.tenant.manage'));

create policy outlets_read on public.outlets for select using (is_member(tenant_id));
create policy outlets_write on public.outlets for all
  using (has_perm(tenant_id, 'core.outlet.manage')) with check (has_perm(tenant_id, 'core.outlet.manage'));

create policy roles_read on public.roles for select using (tenant_id is null or is_member(tenant_id));
create policy roles_write on public.roles for all
  using (tenant_id is not null and has_perm(tenant_id, 'core.role.manage'))
  with check (tenant_id is not null and has_perm(tenant_id, 'core.role.manage'));

create policy rp_read on public.role_permissions for select using (
  exists (select 1 from roles r where r.id = role_id and (r.tenant_id is null or is_member(r.tenant_id))));
create policy rp_write on public.role_permissions for all using (
  exists (select 1 from roles r where r.id = role_id and r.tenant_id is not null and has_perm(r.tenant_id, 'core.role.manage')));

create policy members_read on public.memberships for select using (user_id = auth.uid() or has_perm(tenant_id, 'core.user.manage'));
create policy members_write on public.memberships for all
  using (has_perm(tenant_id, 'core.user.manage')) with check (has_perm(tenant_id, 'core.user.manage'));

create policy modules_read on public.tenant_modules for select using (is_member(tenant_id));
create policy modules_write on public.tenant_modules for all
  using (has_perm(tenant_id, 'core.module.manage')) with check (has_perm(tenant_id, 'core.module.manage'));

create policy cfd_read on public.custom_field_defs for select using (is_member(tenant_id));
create policy cfd_write on public.custom_field_defs for all
  using (has_perm(tenant_id, 'core.customise')) with check (has_perm(tenant_id, 'core.customise'));

create policy wf_read on public.workflows for select using (is_member(tenant_id));
create policy wf_write on public.workflows for all
  using (has_perm(tenant_id, 'core.customise')) with check (has_perm(tenant_id, 'core.customise'));

create policy audit_read on public.audit_log for select using (has_perm(tenant_id, 'core.audit.view'));
create policy ai_read on public.ai_usage for select using (has_perm(tenant_id, 'core.audit.view'));

-- ===== Tenant creation (signup) =====
create or replace function public.create_tenant(p_name text, p_template text default null, p_country char(2) default 'MY')
returns uuid language plpgsql security definer set search_path = public as $$
declare tid uuid; owner_role uuid;
begin
  insert into tenants (name, industry_template, country_code) values (p_name, p_template, p_country) returning id into tid;
  insert into outlets (tenant_id, name) values (tid, 'Main');
  select id into owner_role from roles where tenant_id is null and name = 'Owner';
  insert into memberships (tenant_id, user_id, role_id) values (tid, auth.uid(), owner_role);
  insert into tenant_modules (tenant_id, module) values (tid, 'POS'), (tid, 'INV');
  return tid;
end $$;

-- ===== Seed: core permissions & built-in roles =====
insert into public.permissions (code, module, description) values
  ('core.tenant.manage','CORE','Edit business settings'),
  ('core.outlet.manage','CORE','Add/edit outlets'),
  ('core.user.manage','CORE','Invite/remove users'),
  ('core.role.manage','CORE','Edit roles and permissions'),
  ('core.module.manage','CORE','Turn modules on/off'),
  ('core.customise','CORE','Custom fields and workflows'),
  ('core.audit.view','CORE','View audit trail');

insert into public.roles (tenant_id, name, is_builtin) values
  (null,'Owner',true),(null,'Admin',true),(null,'Manager',true),(null,'Cashier',true),
  (null,'Accountant',true),(null,'HR',true),(null,'Warehouse',true),(null,'Driver',true),
  (null,'Carer',true),(null,'Parent',true),(null,'Viewer',true);

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r cross join public.permissions p
where r.tenant_id is null and r.name = 'Owner';

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code from public.roles r cross join public.permissions p
where r.tenant_id is null and r.name = 'Admin' and p.code <> 'core.tenant.manage';

insert into public.templates (code, name, bundle) values
  ('retail','Retail shop','{"modules":["POS","INV","FIN","CRM"]}'),
  ('cafe','Café / restaurant','{"modules":["POS","INV","FIN","CRM","EXT"]}'),
  ('services','Services / salon','{"modules":["POS","FIN","CRM","EXT"]}'),
  ('logistics','Shipping & cargo','{"modules":["INV","FIN","CRM","LOG"]}'),
  ('kids_care','Kids care centre','{"modules":["POS","FIN","CRM","HR","KIDS"]}');
