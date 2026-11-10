# Chatwoot for Ai buddy Biz — self-host package (Phase 1)

Chatwoot is the shared customer inbox. The **chatwoot-bridge** Edge Function (`supabase/functions/chatwoot-bridge/`) connects it to Ai buddy Biz.

**Status:** files written and checked for syntax only. Nothing here has been run on a real server yet. Treat the first deploy as a test.

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
