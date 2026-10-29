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
| H | Kids care: rooms & ratios, safe check-in/out, daily logs & photos, medicine, incidents, parent app, fees; team invitations | Built |
| I | Restaurant & orders (tables, kitchen display, QR/online ordering), delivery, bookings, Shopify/WooCommerce sync, customer web app | Built |
| J | AI assistant & agents: ask about your business, daily briefing, approved actions (reorders, reminders, follow-ups, prices) | Built |
| K | Business plan and valuation roadmap | |

## Android app (`app/`)

Flutter app. The APK is built by GitHub Actions (`.github/workflows/android.yml`) on every push to `main` and published to a release per batch:

`https://github.com/jslproperties101/ai-buddy-biz/releases/download/batch-j/ai-buddy-biz-batch-j.apk`

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

## Team access (Batch H, all modules)

- More → **Team & access**: invite people by email with a role; change roles or remove access. At least one owner always stays.
- People sign up in the app with the invited email, confirm it, and get access on their next sign-in (`claim_invites()`).
  Make sure **email confirmation is on** in Supabase Auth (it is by default) — unconfirmed emails are never linked.
- Someone in several businesses (e.g. a parent at two centres, or staff at two companies) gets More → **Switch business**.

## Kids care (Batch H)

- Turn on **Kids care** in More → Modules (on by default for the "Kids care centre" template).
- Kids → Setup: centre type & hours, late pick-up fee, rooms with carer ratios, fee plans.
  Default ratios by age: under 1 yr 1:3, 1–3 yrs 1:5, 3–4 yrs 1:10 (TASKA), 4 yrs 1:10, 5–6 yrs 1:15 (TADIKA). Check them against your licence.
- **Safe pick-up**: a child is only released to a guardian marked "can collect", a person the parent authorised for that day
  (last 4 of IC checked), or the parent's 6-digit PIN (5 wrong tries locks it for the day). Anyone else needs a manager override
  with a reason, and every guardian is alerted.
- **Parents** are guardians with an email: "Invite to the parent app" sends them an email; they see check-in/out, daily updates
  and photos, chat with the centre, authorise medicine, acknowledge incidents, add a one-off pick-up person, set a PIN,
  report absences and see their fee invoices.
- **Photos** go to a private Storage bucket `kids` (created by `0009_kids.sql` together with its access rules). Photos need parent consent.
- **Medicine** is only given against a parent's authorisation (in the app or a signed paper form), with interval and daily-maximum checks.
- **Safeguarding** concerns are private to managers and never sent to parents.
- **Fees**: Kids → Setup → Monthly fees creates one invoice per paying guardian (sibling discount, first-time registration and deposit,
  late pick-up fees, extra charges) in Invoices. Run it once a month; families already invoiced are skipped.
- Needs the `send-messages` function (Batch D) for check-in, pick-up, incident and invitation messages.

## Restaurant, orders, delivery & bookings (Batch I)

- Turn on **Restaurant, orders & bookings** in More → Modules (on by default for the café template). New tab: **Orders**
  (Floor · Orders · Kitchen · Bookings). Riders (Driver role) get a **Deliveries** tab; the **Kitchen** role sees the kitchen display.
- Every order — dine-in, takeaway, delivery, QR at the table, online, GrabFood/foodpanda (entered as "App" orders), Shopify/WooCommerce —
  is paid through the normal POS sale (receipt, stock, accounts, loyalty). Service charge and delivery fee are added as lines.
- **Customer web app** (`web/menu.html`, `web/order.html`, `web/book.html`): host the three files together (GitHub Pages, Netlify,
  Supabase Storage…), put your project URL and anon key in each, then set **Orders → ⚙ → Ordering & booking options → Web pages address**.
  Print table QR codes from Areas & tables. Share the online ordering and booking links from the same screen.
- **Bookings**: services with duration and clean-up time, staff/rooms that offer them, opening hours, tables. Double-booking is blocked
  by the database. Reminders: run `select queue_booking_reminders();` daily (Supabase Cron) or tap the button in settings.
- **Shopify / WooCommerce**: connect in Orders → ⚙ → Online shop sync (keys are stored server-side only). Deploy and schedule:
  ```
  supabase functions deploy shop-sync
  select cron.schedule('shop-sync', '*/5 * * * *', $$ select net.http_post(
    url := 'https://<project-ref>.supabase.co/functions/v1/shop-sync',
    headers := jsonb_build_object('Authorization', 'Bearer <SERVICE_ROLE_KEY>')) $$);
  ```
  Products match by SKU. Shopify uses the GraphQL Admin API (default version 2026-07; set `api_version` in the keys to change).
- Online payments (card/FPX/e-wallet) for web orders are not built in yet: customers pay on pickup/delivery or in the shop.

## AI assistant & agents (Batch J)

- Turn on **AI assistant & agents** in More → Modules. New tab **Assistant** (Ask · To approve · Briefing) for roles with `ai.use`.
- The assistant (`supabase/functions/ai-agent`) uses Claude with read-only tools (sales, stock, money owed, pipeline, customers, staff,
  operations, deadlines). Each tool is a database function that checks the user's permissions, so a manager and an accountant see
  different things. Anonymous visitors cannot call them.
- It can only **propose** actions: draft purchase order, message to a customer, follow-up task, price change, note. A person with the
  matching permission approves (and can edit) each one. Messages go to the address on the customer's record; marketing only with consent;
  price changes are capped (default 20%).
- Daily briefing: turn it on in Assistant → ⚙. Deploy and schedule (it only runs for businesses whose briefing hour has passed):
  ```
  supabase functions deploy ai-agent
  select cron.schedule('ai-briefing', '*/30 * * * *', $$ select net.http_post(
    url := 'https://<project-ref>.supabase.co/functions/v1/ai-agent',
    headers := jsonb_build_object('Authorization', 'Bearer <SERVICE_ROLE_KEY>')) $$);
  ```
  Uses the same `ANTHROPIC_API_KEY` secret as Batch G. Every question and briefing counts toward the monthly AI limit of the plan.
