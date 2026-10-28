# Ai buddy Biz

All-in-one business super app: POS, inventory, invoicing, accounting, tax, CRM, HR, legal, logistics, kids care and AI, all switchable per business.

- `docs/ARCHITECTURE.md` — Batch A architecture and customisation engine
- `supabase/migrations/` — database schema
- `docs/tests/` — test checklist per batch

## Batches

| Batch | Scope | Status |
|---|---|---|
| A | Architecture, customisation engine, core schema | Built |
| B | POS, inventory, SKU, barcode and labeling (first APK) | Built |
| C | Invoicing, accounting, zone-based tax, reports, shifts | Built |
| D | CRM and leads | |
| E | Shipping, cargo, air waybills, vessels, supplier CRM | |
| F | HR and payroll | |
| G | Legal and AI lawyer | |
| H | Kids care monitor | |
| I | Restaurant, e-commerce sync, bookings, delivery, customer app | |
| J | AI agents across modules | |
| K | Business plan and valuation roadmap | |

## Android app (`app/`)

Flutter app. The APK is built by GitHub Actions (`.github/workflows/android.yml`) on every push to `main` and published to a release per batch:

`https://github.com/jslproperties101/ai-buddy-biz/releases/download/batch-c/ai-buddy-biz-batch-c.apk`

Set repo secrets `SUPABASE_URL` and `SUPABASE_ANON_KEY` first, and apply `supabase/migrations/*.sql` in order.
