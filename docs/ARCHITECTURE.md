# Ai buddy Biz — Batch A: Architecture & Customisation Engine

Version 0.1 · 28 Oct 2026 · Owner: Joe Matthew

## 1. Product shape

Ai buddy Biz is one platform with switchable modules. A business signs up, picks its industry template (retail, F&B, services, logistics, kids care, etc.), and only the modules it needs are turned on. Everything shares one customer record, one product catalogue, one ledger and one audit trail.

**Modules (each becomes its own batch):**

| Code | Module | Batch |
|---|---|---|
| CORE | Tenants, users, roles, custom fields, workflows, audit, AI layer | A |
| POS | Checkout, payments, offline mode, receipts | B |
| INV | Inventory, SKU, barcode, labeling, multi-outlet stock | B |
| FIN | Invoicing, accounting, tax engine (zone-based) | C |
| CRM | Customers, leads, pipeline, campaigns, loyalty | D |
| LOG | Shipping, cargo, air waybills, vessels, supplier CRM, customs | E |
| HR | Staff, attendance, leave, payroll | F |
| LAW | Contracts, e-sign, compliance calendar, AI lawyer | G |
| KIDS | Kids care monitor: attendance, pickup authorisation, parent alerts | H |
| EXT | Restaurant, e-commerce sync, bookings, delivery, customer app | I |
| AI | Cross-module AI agents | J |

## 2. Stack

- **Mobile app (Android APK, later iOS):** Flutter, one codebase. Offline-first with a local SQLite cache that syncs when online, so POS keeps selling without internet.
- **Web app (back office):** Next.js.
- **Backend:** Supabase (Postgres, Auth, Storage, Realtime, Edge Functions). Matches your other apps.
- **AI:** Claude API through Supabase Edge Functions. API keys never sit in the app.
- **Payments:** gateway adapters (Stripe, iPay88, Billplz, GrabPay, DuitNow QR) behind one interface.
- **Tax & customs rates:** provider adapters (e.g. Avalara, TaxJar, Vertex, customs-data APIs) feeding a local rate table. Rates are data, never hard-coded.

## 3. Multi-tenancy

- Every business is a **tenant**. Every table carries `tenant_id`.
- Postgres **Row Level Security** enforces isolation: a user only ever sees rows for tenants they belong to.
- A tenant has many **outlets** (branches, warehouses, kitchens, kids care centres).
- Users can belong to several tenants (accountants, franchise owners) and switch between them.

## 4. Roles & permissions

- Built-in roles: Owner, Admin, Manager, Cashier, Accountant, HR, Warehouse, Driver, Teacher/Carer, Parent, Viewer.
- Permissions are strings like `pos.sale.void`, `fin.invoice.approve`, `kids.pickup.override`.
- Owners can clone a role and tick or untick permissions. Permissions can be scoped to an outlet.

## 5. Customisation engine (the "customisable for every use case" part)

Three layers, all configured in the web back office without code:

1. **Custom fields.** Add fields to any record (customer, product, shipment, child, employee). Types: text, number, money, date, dropdown, multi-select, file, signature, barcode, lookup to another record. Stored in a `custom_values` JSON column, validated against `custom_field_defs`.
2. **Workflows.** "When X happens, if Y, then do Z." Triggers: record created/updated, status changed, schedule, webhook. Actions: send WhatsApp/email/push, create task, update field, call AI, call webhook, require approval.
3. **Industry templates.** A template is a saved bundle of enabled modules, custom fields, workflows, roles, receipt layouts and dashboards. Picking "Café" at signup applies the café template; the owner can then change anything.

Layouts (forms, receipts, invoices, labels) use a JSON layout schema so they can be edited in a drag-and-drop designer later.

## 6. AI layer

- One **AI gateway** Edge Function. Every AI call goes through it, which logs the prompt, tenant, user, cost and result.
- AI can read only what the calling user is allowed to read (same RLS rules).
- AI actions that change data (e.g. "create a purchase order") are **proposed, then confirmed** by a human. Nothing irreversible happens automatically.
- Per-tenant monthly AI usage limits tied to the subscription plan.

## 7. Audit trail

Every insert, update and delete on business tables writes to `audit_log` (who, when, what changed, before/after). Owners can view and export it. This also supports tax and legal compliance.

## 8. Security & compliance basics

- Auth: email/phone OTP, optional 2FA for Owner/Admin.
- Data at rest encrypted (Supabase default); sensitive fields (IDs, bank details, children's medical notes) additionally encrypted at column level.
- PDPA (Malaysia) first, GDPR-ready structure for later markets.
- Kids data: parent consent recorded, access limited to assigned carers, full access log.

## 9. Subscription tiers (draft, finalised in Batch K)

| Tier | For | Includes |
|---|---|---|
| Free | Solo seller | POS, basic inventory, 1 outlet |
| Starter | Small shop | + invoicing, CRM, 3 users |
| Growth | Growing SME | + accounting, HR, workflows, AI assistant |
| Pro | Multi-outlet | + logistics, legal, unlimited outlets, API |
| Enterprise | Chains, logistics firms | Custom modules, SLA, dedicated support |

## 10. What Batch A delivers

- This architecture document
- Supabase migration `0001_core.sql`: tenants, outlets, memberships, roles, permissions, modules, custom fields, workflows, audit log, AI usage log, with RLS
- Repo scaffold and README
- Test checklist

No APK yet: the first APK comes with Batch B (POS and inventory).
