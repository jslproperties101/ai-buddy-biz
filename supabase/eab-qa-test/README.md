# Ai buddy Biz in the EAB-QA-Test project (schema `biz`)

Batch 2b, 9 Nov 2026 — Joe's decision D-7N-2. The stand-alone Biz Supabase project (`akabqdzqmqfevlmazyqo`) was paused
on 7 Nov (free plan: 2 active projects). Biz now lives in the EAB-QA-Test project (`talksazsqsgjriamwxdp`) in its own
schema `biz`, beside Estate Agent AI Buddy's tables in `public`. Its demo data was not moved.

| File | What |
|---|---|
| `make.mjs` | Turns `supabase/migrations/0001 … 0011` into one file for schema `biz`. The originals are not changed. |
| `20261109120000_biz_schema.sql` | GENERATED. All Biz tables, functions and rules in schema `biz`. One transaction; a second paste changes nothing. |
| `paste-0012-chatwoot.sh` → `20261110000000_chatwoot_biz.sql` | Chatwoot tables/functions only, for a project where `biz` is already installed (safe to run twice). |

What `make.mjs` changes, and only this: `public.` → `biz.`; `search_path = public` → `search_path = biz, public`; the kids
photo rules on the shared `storage.objects` read folder names with `biz.try_uuid(…)` (EAB's own folder names are not ids);
a header creates the schema with the same default rights Supabase gives `public`. It refuses to run if a migration names
the public schema in a way it does not convert, or uses a `public.*` name the migrations do not create.
The build (`.github/workflows/android.yml`) fails if the generated file is out of date.

## Install (TEST project only)
1. Supabase → EAB-QA-Test → SQL Editor → paste `20261109120000_biz_schema.sql` → Run. Expect
   `AI Buddy Biz installed in schema biz: 136 tables`.
2. Then the Biz admin file from the admin-eab repo: `database/20261109120000_biz_admin_in_eab_qa_test.sql`.
3. Project Settings → Data API → Exposed schemas: add `biz`.
4. Authentication → URL Configuration → Redirect URLs: add `aibuddybiz://login-callback` (and the Admin apps'
   `…://biz-callback`).
5. This repo → Settings → Secrets and variables → Actions: set `SUPABASE_URL` and `SUPABASE_ANON_KEY` to EAB-QA-Test
   (the publishable key, never the secret key).

The app, the web pages and the edge functions ask for schema `biz` (app: `SUPABASE_SCHEMA`, default `biz`; web pages:
`SUPABASE_SCHEMA` constant; functions: secret `BIZ_DB_SCHEMA`, default `biz`). For a stand-alone Biz project use `public`.

Local proof (no cloud): admin-eab repo `database/tests/run-bizqa.sh <this checkout>`.
