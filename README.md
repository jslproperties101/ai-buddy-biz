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
| D | CRM & leads: pipeline, scoring, tasks, loyalty, campaigns, web lead form | Built |
| E | Shipping, cargo, air waybills, vessels, supplier CRM | |
| F | HR and payroll | |
| G | Legal and AI lawyer | |
| H | Kids care monitor | |
| I | Restaurant, e-commerce sync, bookings, delivery, customer app | |
| J | AI agents across modules | |
| K | Business plan and valuation roadmap | |

## Android app (`app/`)

Flutter app. The APK is built by GitHub Actions (`.github/workflows/android.yml`) on every push to `main` and published to a release per batch:

`https://github.com/jslproperties101/ai-buddy-biz/releases/download/batch-d/ai-buddy-biz-batch-d.apk`

Set repo secrets `SUPABASE_URL` and `SUPABASE_ANON_KEY` first, and apply `supabase/migrations/*.sql` in order.

## Messaging (Batch D)

Campaigns and "send from business" messages are queued in `outbound_messages` and sent by the
`send-messages` Edge Function (WhatsApp Cloud API, Resend email, Twilio SMS).

1. Deploy it (it checks the service key itself):
   `supabase functions deploy send-messages --no-verify-jwt`
2. Run it every minute with Supabase Cron (SQL editor; needs the `pg_cron` and `pg_net` extensions):
   ```sql
   select cron.schedule('send-messages', '* * * * *', $$
     select net.http_post(
       url := 'https://<project-ref>.supabase.co/functions/v1/send-messages',
       headers := jsonb_build_object('Authorization', 'Bearer <SERVICE_ROLE_KEY>')
     ) $$);
   ```
   (Better: keep the key in Supabase Vault and read it inside the job.)
3. Each business connects its own WhatsApp / email / SMS account in the app: More → CRM settings.
   WhatsApp marketing messages need a template approved in Meta Business Manager.

## Website lead form

`web/lead-form.html` posts enquiries to `capture_lead()` with the business's form key
(More → CRM settings). Put in the project URL, anon key and form key, then host it or embed it.
