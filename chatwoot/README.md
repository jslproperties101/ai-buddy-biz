# Chatwoot for Ai buddy Biz — self-host package (Phases 1–3)

Chatwoot is the shared customer inbox. The **chatwoot-bridge** Edge Function (`supabase/functions/chatwoot-bridge/`) connects it to Ai buddy Biz.

**Status:** Phase 1 (deploy package, bridge skeleton), Phase 2 (Claude auto-reply, lead capture) and Phase 3 (listings from the product catalogue, viewing requests) are written and unit-tested. The database changes were run on a throwaway local Postgres. Nothing has been run against a real Chatwoot server, the real Anthropic API, WhatsApp, or the EAB-QA-Test project yet. Treat the first deploy as a test.

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

## 5. Phase 2: Claude replies and lead capture (`BRIDGE_MODE=live`)

What it does for each new customer message: de-duplicates the webhook in the database, checks the switches and limits, asks Claude (with the last few messages), saves the lead into Ai buddy Biz (one contact and one lead per conversation, no marketing consent), sends the reply, and hands over to a person when needed (private note with a summary, conversation moved to "open").

**Limits that stop the bot before any AI money is spent:** `chat_accounts.bot_enabled = false`, a human already assigned, conversation already handed over, the plan's monthly AI limit (same counter as the in-app assistant: free 10, starter 50, growth 300 requests a month), and `max_bot_replies` per conversation (default 6). Claude replies containing a link are never sent.

### Apply the database change (needs your approval, test project only)

1. EAB-QA-Test (schema `biz`): paste `supabase/eab-qa-test/20261110120000_biz_0012_chat.sql` into the SQL editor. It stops and changes nothing if biz is not installed or this is already applied. (A stand-alone Biz project: apply `supabase/migrations/0012_chat.sql`.)
2. Link your Chatwoot account to your business (find the Chatwoot account id in its URL, `/app/accounts/<id>/…`):
   ```sql
   insert into biz.chat_accounts (chatwoot_account_id, tenant_id) values (1, '<your tenant id>');
   ```

### Switch it on

```bash
supabase secrets set BRIDGE_MODE=live ANTHROPIC_API_KEY=<key> CHATWOOT_API_TOKEN=<token>
supabase functions deploy chatwoot-bridge --no-verify-jwt
```

Optional: `AI_MODEL` (default `claude-sonnet-5-5`), `BIZ_DB_SCHEMA` (default `biz`; `public` for a stand-alone project). To stop the bot at any time set `BRIDGE_MODE=observe`, or `update biz.chat_accounts set bot_enabled = false`.

Then run the manual checks in `docs/tests/Chatwoot-Phase2-test-checklist.md`.

**What the bot cannot do yet:** it has no listing, price or availability data (Phase 3), so its prompt tells it to leave those to a person. It does not read images, voice notes or documents, and it replies in text only.

### Extra assumptions to confirm on first run

- Chatwoot's `toggle_status` and message-history endpoints and the `message_type` numbers (0 customer, 1 agent/bot) follow its API docs as I understand them but were only tested against fake responses. If handover does not move a conversation to "open", or history is empty, check the function logs for `handover status failed` / `history unavailable`.
- `conversation.meta.assignee` in the webhook is used to detect an assigned human; if Chatwoot does not send it, the bot may reply in conversations a human has taken. Use `bot_enabled` or `max_bot_replies` as the safety net until confirmed.

## 6. Phase 3: listings and viewing requests

Claude can now look up listings and ask for a viewing, using two tools inside the bridge. It cannot do anything else in your data.

**Listings.** Only products you explicitly flag are visible to the bot. For each flagged product it sees just: a reference (the lowest active variant SKU), the name, the "from" price with currency, and the text you wrote for the bot (`chat_info`, cut at 600 characters). It never sees cost, stock, custom fields, suppliers or images. Claude is told to quote only what the search returns, to say prices and availability are subject to confirmation by the team, and never to invent a listing.

**Viewings.** When a customer gives a specific date and time, Claude calls `request_viewing`. This creates a **pending** booking (60 minutes, "Property viewing" service, notes saying it is NOT confirmed) and an unowned task due in one hour, then **always hands the conversation over** to a person, even if Claude did not ask to. Claude is told never to say a viewing is booked or confirmed. Safeguards in the database function: time must be 2 hours to 90 days ahead, in your business time zone; at most 3 pending/confirmed requests per conversation; the same start time in the same conversation is not duplicated; a contact must exist (the bridge saves one first).

### Apply the database change (needs your approval, test project only)

1. EAB-QA-Test (schema `biz`): paste `supabase/eab-qa-test/20261110180000_biz_0013_chat_listings.sql` into the SQL editor. It needs the Phase 2 file applied first and stops without changing anything if that is missing or if this is already applied. (A stand-alone Biz project: apply `supabase/migrations/0013_chat_listings.sql`.) A **fresh** EAB-QA-Test install using the regenerated `20261109120000_biz_schema.sql` already includes both.
2. Flag the listings the bot may talk about. The Flutter app has no switch for this yet, so use SQL:
   ```sql
   update biz.products
      set chat_visible = true,
          chat_info = '3 bedrooms, 1,200 sq ft, fully furnished, near MRT. Freehold.'
    where id = '<product id>';
   ```
   Write `chat_info` as something you are happy for any customer to read. To hide a listing again set `chat_visible = false`.
3. Redeploy the bridge: `supabase functions deploy chatwoot-bridge --no-verify-jwt`.

To turn the two tools off without touching anything else: `supabase secrets set BRIDGE_LISTING_TOOLS=off` (the bot then behaves exactly as in Phase 2).

### Assumptions to confirm on first run (Phase 3)

- Your property listings are stored as Biz products, with the price on the variant. If most of yours have no price or a placeholder price, the "from" price shown to customers will be wrong; check what the bot quotes.
- The business time zone in Biz settings is correct, since customer times are read in it.
- Staff will see the pending viewing under bookings and as a task; confirming it with the customer is a manual step (follow-ups and an approval queue are Phase 4, not built).
- Each customer message may now cost up to 5 Claude calls (searches plus the answer), and all of them count as AI usage tokens; the monthly plan quota still counts one request per customer message.

## Assumptions to confirm on first run (Phase 1)

- **Timestamp format.** Chatwoot's docs say the signature covers the timestamp, a period and the raw body, but do not say whether the timestamp is seconds or milliseconds. The bridge accepts both and rejects deliveries older than 5 minutes. If every webhook returns 401 with `reason: stale_timestamp` or `bad_timestamp`, check the server clock and the header format.
- **Webhook payload fields** (`message_type: "incoming"`, `conversation.id`, `account.id`, `sender`) follow Chatwoot's documented shape but were only tested against sample payloads written from it, not real deliveries.

## Backups and upgrades

- Back up the `postgres` Docker volume and `./data/storage` on a schedule (for example nightly `pg_dump` to off-server storage). Not set up in this phase.
- Pin `CHATWOOT_VERSION` to a release tag once it works, and read Chatwoot's release notes before upgrading.

## Tests

```bash
node --test --experimental-strip-types supabase/functions/chatwoot-bridge/tests/*.test.ts
```
