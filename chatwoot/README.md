# Chatwoot for Ai buddy Biz — self-host package (Phase 1 + Phase 2)

Chatwoot is the shared customer inbox. The **chatwoot-bridge** Edge Function (`supabase/functions/chatwoot-bridge/`) connects it to Ai buddy Biz.

**Status:** Phase 1 (server package, signature check, test reply) and Phase 2 (AI-drafted replies as private notes, leads, product lookup) are written and tested with fakes and a local database. **Nothing has been run on a real Chatwoot server, against the real Claude API, or on the EAB-QA-Test project yet.** Treat the first deploy as a test.

## What you need

- A VPS with at least 4 GB RAM and 20 GB disk, Docker Engine 20.10+ and Docker Compose v2 (Chatwoot's stated minimums).
- A domain or subdomain (for example `chat.yourdomain.com`) with a DNS **A record** pointing at the server, and ports 80 and 443 open.

## 1. Start Chatwoot

```bash
git clone https://github.com/jslproperties101/ai-buddy-biz && cd ai-buddy-biz/chatwoot
cp .env.example .env
# edit .env: CHATWOOT_DOMAIN, FRONTEND_URL, SECRET_KEY_BASE (openssl rand -hex 64),
# POSTGRES_PASSWORD, REDIS_PASSWORD (and the same password inside REDIS_URL)
docker compose up -d
docker compose exec rails bundle exec rails db:chatwoot_prepare   # first run only
```

Open `https://<your domain>`, create the first admin account, then set `ENABLE_ACCOUNT_SIGNUP=false` (already the default) and run `docker compose up -d` again.

First-boot things to check, because they were not tested:
- `docker compose ps`: rails, sidekiq, postgres, redis, caddy all "running".
- `docker compose logs rails --tail 50`: no crash loop. If rails restarts with a stale `server.pid` error, remove `tmp/pids/server.pid` inside the container or add an entrypoint that does, as Chatwoot's own production compose file does.
- Caddy got a certificate (the site opens on https with no warning).

## 2. Test mode (no WhatsApp number yet)

You do not need Meta to prove the loop. In Chatwoot: **Settings → Inboxes → Add Inbox → Website** and use the live-chat widget on any test page. Messages typed in the widget arrive as incoming messages exactly like WhatsApp ones will later.

When the Meta WhatsApp Business Cloud number is ready: **Settings → Inboxes → Add Inbox → WhatsApp** (Cloud API). No change to the bridge is needed.

## 3. Deploy the bridge

```bash
supabase functions deploy chatwoot-bridge --no-verify-jwt
supabase secrets set CHATWOOT_BASE_URL=https://<your domain> BRIDGE_MODE=observe
```

`--no-verify-jwt` is required because Chatwoot cannot send a Supabase login token. Security comes from the HMAC signature; the function returns 401 to anything without a valid one.

Create the webhook in Chatwoot (**Settings → Integrations → Webhooks**), URL `https://<project-ref>.supabase.co/functions/v1/chatwoot-bridge`, subscribed to **message_created**. Copy the webhook's **secret** (Chatwoot's API returns it as the `secret` field when the webhook is created):

```bash
supabase secrets set CHATWOOT_WEBHOOK_SECRET=<secret>
```

Which Supabase project the function is deployed to follows the Biz decision (EAB-QA-Test, schema `biz`). Phase 1 does not touch any database.

## 4. Prove the loop

1. Leave `BRIDGE_MODE=observe`. Send a message from the widget. In the Supabase function logs you should see `observed incoming message …`.
2. To see a reply, create a Chatwoot user (or agent bot) access token, then:
   ```bash
   supabase secrets set BRIDGE_MODE=test-reply CHATWOOT_API_TOKEN=<token>
   ```
   Send another message: a fixed test reply should appear in the conversation, and only once.
3. Set `BRIDGE_MODE=observe` again when done. Phase 2 replaces the fixed reply with Claude.

## Assumptions to confirm on first run

- **Timestamp format.** Chatwoot's docs say the signature covers the timestamp, a period and the raw body, but do not say whether the timestamp is seconds or milliseconds. The bridge accepts both and rejects deliveries older than 5 minutes. If every webhook returns 401 with `reason: stale_timestamp` or `bad_timestamp`, check the server clock and the header format.
- **Webhook payload fields** (`message_type: "incoming"`, `conversation.id`, `account.id`, `sender`) follow Chatwoot's documented shape but were only tested against sample payloads written from it, not real deliveries.

## Backups and upgrades

- Back up the `postgres` Docker volume and `./data/storage` on a schedule (for example nightly `pg_dump` to off-server storage). Not set up in this phase.
- Pin `CHATWOOT_VERSION` to a release tag once it works, and read Chatwoot's release notes before upgrading.

## Tests

```bash
node --test --experimental-strip-types supabase/functions/chatwoot-bridge/tests/bridge.test.ts
```

## Phase 2: Claude drafts, a person sends (`BRIDGE_MODE=draft`)

What happens when a customer writes in:
1. The bridge checks the signature and asks the database whether this delivery is new, a retry of one that failed, or a duplicate (`chatwoot_events`; survives restarts and several instances).
2. **Lead:** the first time a conversation has a name plus a phone or email (WhatsApp gives the phone), it is saved as a lead through Biz's existing lead rules (contact de-duplicated by phone/email, one deal, the message as a note, source `chatwoot`). One lead per conversation. If this fails, the draft still goes out and it is tried again on the next message.
3. **Draft:** Claude (default `claude-sonnet-5-5`) writes a short suggested reply from the last few messages and a **read-only product lookup** (name, description, variant, price, in stock yes/no). It never sees cost or stock counts.
4. The draft is posted as a **private note** starting `Suggested reply (draft, NOT sent to the customer):`. Only your team sees it; a person copies it into the reply box. The bridge never sends anything to the customer in this mode. When Claude is unsure (complaints, refunds, anything not in the product data) the draft starts with `[NEEDS A PERSON]`.

### One-time setup (test project only: EAB-QA-Test)
1. In the EAB-QA-Test SQL editor: if schema `biz` is **not** installed yet, run `supabase/eab-qa-test/20261109120000_biz_schema.sql` (it now includes Chatwoot). If `biz` is **already installed**, run only `supabase/eab-qa-test/20261110000000_chatwoot_biz.sql` (safe to run twice; the main file refuses a second run by design).
2. Link the Chatwoot account to the business (replace the numbers/ids):
   ```sql
   insert into biz.chatwoot_accounts (account_id, tenant_id) values (1, '<tenant uuid>');
   ```
   (Chatwoot account id is the number in the Chatwoot URL, `/app/accounts/<id>/`.) The business also needs its CRM settings opened once in the app so the lead form key exists.
3. Secrets, then switch the mode:
   ```bash
   supabase secrets set ANTHROPIC_API_KEY=<key> CHATWOOT_API_TOKEN=<token> CHATWOOT_BASE_URL=https://<your domain> BRIDGE_MODE=draft
   supabase functions deploy chatwoot-bridge --no-verify-jwt
   ```
   `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` are provided to the function by Supabase.
4. Send a test message from the website widget. Within a few seconds a private note should appear, and a lead in Biz.

### Things to know before using it with real customers
- **Customer messages are sent to Anthropic (Claude) to write the draft.** Mention this in your privacy notice (PDPA) before real WhatsApp customers.
- Every active product of the business can be quoted, including services and bundles. Deactivate anything that should not be offered.
- The draft is only as good as the product data; with no match it says so and asks for a person.
- Cost: one Claude request per customer message (two when it looks up products).

### Assumptions to confirm on the first real run
- Chatwoot's message-list API (`GET …/conversations/{id}/messages`) is read as `{ payload: [{ content, message_type: 0|1, private }] }`. If it differs, drafts still work but without earlier messages (the log says `history unavailable`).
- A failed delivery is retried only if Chatwoot re-sends it; otherwise the customer's next message triggers a fresh draft.
- Not tested under Deno itself (tests run on Node 22 with the same files).

### Tests
```bash
node --test --experimental-strip-types supabase/functions/chatwoot-bridge/tests/*.test.ts     # bridge (no network)
PGHOST=… supabase/tests/run-0012.sh <stand-in-supabase.sql>                                     # database functions on local PostgreSQL
```
