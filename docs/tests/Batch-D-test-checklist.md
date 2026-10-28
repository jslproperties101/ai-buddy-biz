# Ai buddy Biz — Batch D test checklist (CRM & leads)

**APK:** https://github.com/jslproperties101/ai-buddy-biz/releases/download/batch-d/ai-buddy-biz-batch-d.apk
(the first APK build will include Batches B, C and D)

Before testing: apply `0001` → `0004_crm.sql` to Supabase. Bottom tabs are now **Sell · Catalog · Invoices · CRM · More** (Products and Stock moved into Catalog).

## 1. Customers
- [ ] CRM → Customers → + → add a customer with phone, email, tags "vip, wholesale", birthday, and "Agrees to receive offers" ticked
- [ ] Tags show as #vip #wholesale (lower-case, no duplicates)
- [ ] Search by name, part of phone number, or email
- [ ] Filter by Leads / Prospects / Customers / Inactive; sort by Top spenders and Most points
- [ ] Open a customer → Call, Open WhatsApp (number becomes 60… automatically) and Email buttons open the right apps
- [ ] Edit customer → change details → saved

## 2. Leads pipeline
- [ ] CRM → Leads → + Lead → choose customer, title, value, expected close → Create lead
- [ ] Lead shows a score (0–100) with reasons (e.g. "Has phone +8")
- [ ] Log a call → score goes up ("Contacted this week")
- [ ] Tap a stage chip (e.g. Proposal) → lead moves; timeline shows "Moved to Proposal"
- [ ] Customer's stage changes to Prospect once lead reaches 50%+ stages
- [ ] Won → lead closes at 100, customer becomes Customer
- [ ] Lost → must pick a reason; Reopen puts it back to New
- [ ] Top KPIs: Open count/value, Weighted value, Win rate 90d
- [ ] "Mine" filter shows only leads you own

## 3. Tasks
- [ ] On a lead → Log / task → Task with a due date in the past → shows red (overdue)
- [ ] CRM → Tasks lists it; tick it → disappears
- [ ] "Everyone's tasks" switch shows tasks of other staff

## 4. Website lead form
- [ ] More → CRM settings → Website lead form → copy form key
- [ ] Open `web/lead-form.html`, fill in project URL, anon key and form key, submit an enquiry
- [ ] New lead appears in the New stage with a "Web enquiry" note
- [ ] Submit again with the same phone in a different format (e.g. +60 12-… vs 012…) → no duplicate customer
- [ ] "Make new key" → old key stops working

## 5. Loyalty points
- [ ] CRM settings → loyalty: 1 point per RM1, 1 point = RM0.01, minimum 100 → example text updates → Save
- [ ] Sell → Add customer → sell RM220 → customer earns 220 points
- [ ] Next sale → Charge → "Use points" switch → pay part with points, rest cash → points go down
- [ ] Points below 100 → no "Use points" option
- [ ] Void the points sale (Sales history) → points are given back
- [ ] Customer page → tap Points → adjust +50 with a reason; Cashier cannot adjust
- [ ] Points history list on the customer page is correct
- [ ] Reports → Trial balance still Balanced ✓; points used appear under "Loyalty rewards"

## 6. Campaigns
- [ ] CRM → Campaigns → + → WhatsApp, tag "vip" → shows "N will receive it / M skipped (no consent or no phone)"
- [ ] Sending without a template name is blocked
- [ ] Add template name → Preview text fills {{first_name}}, {{points}}, {{business}}
- [ ] Send → only customers who agreed to offers are queued; campaign becomes read-only
- [ ] Email campaign needs a subject; Birthday month / spent / inactive filters change the count
- [ ] Stop sending cancels messages still waiting

## 7. Real sending (needs your accounts)
- [ ] Deploy `send-messages` and the cron job (README → Messaging)
- [ ] CRM settings → Connect WhatsApp (phone number ID + token) → shows Connected; keys are not shown again
- [ ] Send a campaign to your own number → arrives; campaign shows Sent count
- [ ] Customer page → "Send from business" → message arrives (works within 24h of the customer messaging you)
- [ ] Connect Resend → email campaign arrives with an opt-out line

## 8. Roles
- [ ] Cashier: CRM tab shows Customers only; can add a customer at the till; cannot edit customers, see leads or campaigns
- [ ] New "Sales" role: Leads, Customers, Tasks, Invoices; no campaigns, settings or accounts
- [ ] Manager: everything in CRM except changing CRM settings

## Known limits in this batch
- WhatsApp replies from customers don't flow back into the app yet (needs a webhook; planned with the AI batch)
- Lead scoring is rule-based; AI scoring comes in Batch J
- Customer search needs a connection; selling to a customer offline works if they were chosen before going offline
