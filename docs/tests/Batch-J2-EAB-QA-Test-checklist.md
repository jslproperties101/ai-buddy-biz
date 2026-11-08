# Batch J2 (Batch 2b) — Ai buddy Biz on the EAB-QA-Test database: test checklist

Date 9 Nov 2026. Same features as Batch J; only the database moved (EAB-QA-Test, schema `biz`). Demo data was NOT
moved: start with an empty business. Built and tested on the computer only — NOT yet on a phone.

## Before you start (Joe, once)
- [ ] SQL Editor on EAB-QA-Test: run `supabase/eab-qa-test/20261109120000_biz_schema.sql` → "installed … 133 tables".
- [ ] Then the admin-eab file `database/20261109120000_biz_admin_in_eab_qa_test.sql`.
- [ ] Data API → Exposed schemas: add `biz`.
- [ ] Redirect URLs: add `aibuddybiz://login-callback`.
- [ ] Repo secrets `SUPABASE_URL` / `SUPABASE_ANON_KEY` = EAB-QA-Test; run the Android APK build again.

## On the phone
- [ ] 1. Install `ai-buddy-biz-batch-j2.apk` (uninstall the Batch J app first if Android refuses).
- [ ] 2. Continue with Google → you come back into the app signed in.
- [ ] 3. Create a business (e.g. a café) → Home shows its modules.
- [ ] 4. Add a product with a price → sell it at the POS → receipt R000001 appears in Sales.
- [ ] 5. Invoices / CRM / HR screens open without "relation does not exist" or "schema" errors.
- [ ] 6. Sign in with a second Google account → it sees no business until invited.
- [ ] 7. Estate Agent AI Buddy QA app still signs in and shows its listings (nothing changed there).

## Admin EAB 0.13.0 (combined admin or Admin Biz)
- [ ] 8. Biz space → any Biz tile → "Sign in to AI Buddy Biz" asks for nothing to type → Continue with Google.
- [ ] 9. Joe becomes Owner on the Biz admin list; Businesses shows the café from step 3.
- [ ] 10. Switch a module on with a reason → the café app shows it after a refresh.

## Known limits
- Demo data from the paused Biz project was not moved (1 tenant, 2 sales — test data only).
- Edge functions (send-messages, ai-agent, ai-legal, shop-sync) are NOT deployed to EAB-QA-Test in this batch.
- A Biz sign-up also gets an On Da Way profile row (EAB-QA-Test's shared sign-up rule). Harmless on test data.
