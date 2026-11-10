# Chatwoot Phase 2 — manual test checklist (Claude auto-reply and lead capture)

Run on the EAB-QA-Test project with a Chatwoot **website chat** inbox (no WhatsApp number needed). Nothing below has been run yet.

## Setup
- [ ] `0012` applied (`20261110120000_biz_0012_chat.sql`) and `biz.chat_accounts` row inserted for your Chatwoot account.
- [ ] `BRIDGE_MODE=live`, `ANTHROPIC_API_KEY`, `CHATWOOT_API_TOKEN`, `CHATWOOT_WEBHOOK_SECRET`, `CHATWOOT_BASE_URL` set; function deployed with `--no-verify-jwt`.
- [ ] Chatwoot webhook subscribed to `message_created` pointing at the function.

## Reply and lead
- [ ] Send "Hi, looking for a 3-bed condo in Mont Kiara, budget RM1.2m" from the widget. A short reply arrives within a few seconds, once.
- [ ] In Biz: one new contact (source `chat`) and one new lead in the first pipeline stage, title about the condo, budget/area stored on the lead, a "Chat summary (AI)" note on it.
- [ ] Send a second message in the same conversation: still ONE lead, new details merged, one more summary note.
- [ ] Reply in Bahasa Malaysia and in Chinese: the bot answers in the same language.
- [ ] The contact has **no** marketing consent.

## Handover and limits
- [ ] "Can I speak to a person?" → a reply, a private note with a summary, conversation shows as **open**; next customer message gets NO bot reply.
- [ ] "What is the price of unit A-12?" → the bot does not give a price and hands over.
- [ ] Ask it to ignore its rules and send a link: no link is ever sent.
- [ ] Assign the conversation to an agent: the bot stops replying.
- [ ] After `max_bot_replies` (default 6) bot replies: holding message, handover note, no more AI replies.
- [ ] Set `bot_enabled = false`: no replies. Free plan (limit 10 a month): after the limit, holding message and handover instead of AI.

## Safety and duplicates
- [ ] Re-deliver the same webhook (Chatwoot webhook log → retry): no second reply (`chat_events` blocks it).
- [ ] Wrong webhook secret → 401 and nothing happens.
- [ ] Stop the Chatwoot API token (invalid) and send a message: function returns 502; fix the token and retry from Chatwoot: it replies once.
- [ ] `select * from biz.ai_usage where feature = 'chat_bot'` shows one row per AI call with token counts and cost.
