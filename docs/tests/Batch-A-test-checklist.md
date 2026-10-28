# Ai buddy Biz — Batch A test checklist

Batch A has no app screens yet. These tests check the database foundation once the migration is applied to a Supabase project.

## Setup
- [ ] Migration `0001_core.sql` runs with no errors
- [ ] Tables exist: tenants, outlets, roles, permissions, role_permissions, memberships, tenant_modules, custom_field_defs, workflows, templates, audit_log, ai_usage
- [ ] 11 built-in roles and 5 industry templates are seeded

## Signup / tenant creation
- [ ] Signed in as User 1, call `create_tenant('Test Shop','retail')` → returns an ID
- [ ] A "Main" outlet was created for it
- [ ] User 1 is Owner of that tenant
- [ ] POS and INV modules are turned on

## Data isolation (most important)
- [ ] User 2 creates their own tenant
- [ ] User 1 cannot see User 2's tenant, outlets or custom fields (and vice versa)
- [ ] Signed out (anon), nothing can be read except nothing at all from tenant tables

## Permissions
- [ ] Owner can add an outlet, a custom field and a workflow
- [ ] Add User 2 to User 1's tenant as Cashier → Cashier can read outlets but cannot add one or change roles
- [ ] Owner clones a role and removes a permission → that role loses that ability

## Customisation
- [ ] Add a custom field "Favourite colour" (dropdown) to customer entity → saved
- [ ] Same key twice on the same entity is rejected

## Audit trail
- [ ] Every action above appears in `audit_log` with user, time, before/after
- [ ] Cashier cannot read the audit log; Owner can
