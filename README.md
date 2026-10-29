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
| E | Shipping, cargo, air waybills, containers, vessels, customs landed cost, supplier CRM, purchasing | Built |
| F | HR & payroll: staff, attendance, EA overtime, leave, claims, EPF/SOCSO/EIS/PCB, payslips | Built |
| G | Legal & compliance: contracts, templates, e-signing, compliance calendar, AI legal assistant | Built |
| H | Kids care monitor | |
| I | Restaurant, e-commerce sync, bookings, delivery, customer app | |
| J | AI agents across modules | |
| K | Business plan and valuation roadmap | |

## Android app (`app/`)

Flutter app. The APK is built by GitHub Actions (`.github/workflows/android.yml`) on every push to `main` and published to a release per batch:

`https://github.com/jslproperties101/ai-buddy-biz/releases/download/batch-g/ai-buddy-biz-batch-g.apk`

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

## Shipping & customs (Batch E)

- Turn on **Shipping & cargo** in More → Modules (on by default for the freight templates).
- Validation built in: container numbers (ISO 6346), air waybills (mod-7) and IMO ship numbers are check-digit verified.
- Chargeable weight: air 1:6000, courier 1:5000, road 1:3000, sea LCL W/M, FCL in TEU.
- Customer tracking page: host `web/track.html`, then set the repo **variable** `TRACK_URL` to its address so the app shares links.
- Customs: `customs_profiles` holds valuation basis and low-value rules per country (seeded for MY, US, EU, GB, AU, SG — verify);
  `duty_rates` is empty by design — load a tariff schedule from a data provider or enter rates per HS code.

## HR & payroll (Batch F)

- Statutory rules are data: `statutory_params` (rates, ceilings, reliefs, minimum wage, OT multipliers with start dates),
  `pcb_brackets` (LHDN computerised method Table 1) and `statutory_bands` (SOCSO / EIS bands).
- EPF uses the Third Schedule band method (RM20 bands to RM5,000, RM100 bands to RM20,000, rounded up to the ringgit).
- SOCSO/EIS bands are generated from PERKESO's mid-point method (top band RM104.15 / RM29.75 / RM11.90 matches the published table).
  Load the official table into `statutory_bands` (source = 'perkeso') if any band differs.
- PCB follows LHDN's computerised formula incl. additional remuneration (bonus) and zakat. Check results against e-PCB before the first live run.
- Overtime follows the Employment Act: ORP = monthly ÷ 26; 1.5× normal days; rest-day ½/1 day + 2×; public holiday 2 days + 3×.
- Staff link their login automatically when HR enters the same email on their employee record.

## Legal & compliance (Batch G)

- Turn on **Legal & compliance** in More → Modules. Fill in More → Legal → 🏢 Company details (used by templates).
- Five Malaysian starter templates (mutual NDA, employment contract to EA 1955 minimums, service agreement, sales terms, PDPA privacy notice).
  They are starting points, not legal advice — have a lawyer review them for your business.
- **E-signing** (Electronic Commerce Act 2006 s.62 style: identifies the signer, shows approval, reliable):
  1. Host `web/sign.html` (any static host: GitHub Pages, Netlify, Supabase Storage). Put your project URL and anon key in it.
  2. Set the repo **variable** `SIGN_URL` to its address (e.g. `https://sign.example.com/sign.html`) so the app builds links.
  3. Sending locks the wording, stores a SHA-256 fingerprint, saves a version and issues a secret link per signer.
     Signers type their name, draw a signature, tick consent and (optionally) enter a one-time code. Every step is logged with time and IP.
  4. Anyone can check a signed PDF at `SIGN_URL?verify=<fingerprint>`.
  - Powers of attorney, wills, trusts and negotiable instruments can't be e-signed (the Act excludes them) — such templates are print-only.
- **Compliance calendar** seeds EPF/SOCSO/EIS/PCB (15th), SST returns, CP204, EA forms, Form E, Form C, SSM annual return/accounts,
  premise licence and a yearly PDPA review. Items with no date ask you for one. Done items roll to the next period.
- **AI legal assistant** (`supabase/functions/ai-legal`): contract review, key-date extraction, drafting and Q&A, focused on Malaysian law.
  ```
  supabase secrets set ANTHROPIC_API_KEY=sk-ant-...      # required
  supabase secrets set AI_MODEL=claude-sonnet-5-5         # optional (default)
  supabase functions deploy ai-legal
  ```
  Monthly AI requests per plan are in `ai_plan_limits`; usage and cost are logged in `ai_usage`.
  The assistant gives general information, not legal advice, and flags when to see a lawyer.
