# Ai buddy Biz — Batch H test checklist (Kids care monitor + team invitations)

**APK:** https://github.com/jslproperties101/ai-buddy-biz/releases/download/batch-h/ai-buddy-biz-batch-h.apk
(the first APK build will include Batches B–H)

Before testing:
- Apply `0001` → `0009_kids.sql` (it also creates the private `kids` photo bucket).
- Supabase Auth: email confirmation ON. `send-messages` function running (for parent messages).
- You need 3 phones or logins: **Owner**, **Carer** (staff), **Parent**.
- More → Modules → turn on **Kids care** (or create a new business with the "Kids care centre" template).

## 1. Team & access (works for every module)
- [ ] Owner: More → Team & access → Invite `carer@…` as **Carer** → shows under "Waiting to sign up"
- [ ] Carer signs up with that email, confirms it, opens the app → lands straight in the business with the **Kids** tab (no "set up business" screen)
- [ ] Owner changes the carer's role / removes access → the carer loses access after reopening the app
- [ ] You can't change your own access; the last owner can't be removed

## 2. Setup (Owner)
- [ ] Kids → Setup → Centre settings: TASKA, 07:00–18:30, late fee RM10 per 15 min, grace 5 min → Save
- [ ] Add rooms: Babies 0–12 months (suggests 1:3), Toddlers 12–36 (1:5), Pre-school 36–48 (1:10)
- [ ] Setting 1:8 for babies shows a "looser than usual" warning
- [ ] Fee plan "Full day" RM650/month, registration RM200, deposit RM650, sibling discount 10%
- [ ] Calendar (Legal tab, if on): childcare licence, Bomba certificate, fire drill (quarterly), first-aid training appear

## 3. Enrol children & family
- [ ] Children → Enrol: name, date of birth (room suggested by age), days, fee plan, allergy "Peanuts", photo consent on → K0001
- [ ] Open child → edit → add a profile photo
- [ ] Family & pick-up → Add guardian: mother, email, phone, IC last 4, can collect, pays fees, **Invite to the parent app** ✓
- [ ] Add a second child for the same mother (same email → reuses the same guardian)
- [ ] Add a neighbour with "Allowed to collect" OFF (emergency contact only)
- [ ] Carer can see allergies but not MyKid number/address (Profile tab shows private details only to managers)

## 4. Today board & check-in (Carer)
- [ ] Start my duty → Toddlers. Ratio card turns green; Babies room with a child and no carer shows red "Need 1 carer"
- [ ] Tap **In** → pick "dropped off by" chip, temperature 36.8 → "In since 08:05"; allergy warning shown
- [ ] Temperature 38.1 → warning to follow sickness policy; health entry appears in the log
- [ ] Checking in twice is refused
- [ ] Parent receives "checked in" message (if messaging is set up)

## 5. Daily logs & photos (Carer)
- [ ] Child → Day → + Log: Meal (Nasi lemak, Most), "Also log for" two other children → one entry each
- [ ] Nap 12:30–14:00, Nappy wet, Mood 😊, Activity with a note
- [ ] Photo → take a picture → saved; for a child **without** photo consent the photo is refused
- [ ] "Parents can see this" off → entry marked "staff only"
- [ ] Long-press your own entry → delete; another carer's entry can't be deleted (manager can)

## 6. Safe pick-up
- [ ] Tap **Out** → neighbour is listed as "Not allowed to collect"
- [ ] Mother with wrong IC last 4 → refused "do not release"
- [ ] Parent adds "Grandma, IC last 4 567A, today" in their app → appears in the Out dialog; releasing without/with wrong IC is refused; correct → released
- [ ] Parent sets a PIN in the app → PIN pick-up works; wrong PIN shows "1 of 5 tries"; after 5 wrong tries PIN is locked for the day
- [ ] Carer can't use "Someone else"; manager override needs name + reason and alerts all guardians
- [ ] After closing time: collected 40 min late → "40 min late", RM30 late fee recorded
- [ ] Here now → roll call ticks; Print register PDF shows in/out, who dropped off/collected, how verified

## 7. Medicine & incidents
- [ ] Parent app → Health → Authorise: Paracetamol 5 ml, every 6 h, max 3/day, today → staff see it in Records
- [ ] Staff Give → recorded; giving again within 6 h is refused; carer can't override; parent sees "Given 10:15"
- [ ] Parent taps Stop → staff can no longer give it
- [ ] Manager records a signed paper form for another medicine
- [ ] Report incident: Injury, minor, playground, first aid → parent gets a message and must **Acknowledge**; staff see "parent acknowledged"
- [ ] Safeguarding concern → private notice with JKM reporting duty; parents never see it; carer sees only their own reports
- [ ] Incident PDF with signature lines; manager closes the incident with a note

## 8. Parent app
- [ ] Parent signs up with the invited email → **My children** tab with both children and today's status
- [ ] Today: arrival/collection times, timeline with photos (tap to zoom); staff-only notes hidden; previous days with arrows
- [ ] Messages: parent ↔ centre chat; unread badge clears after opening
- [ ] Report absence (sick, 3 days) → those days show "Off sick" on the staff board
- [ ] Photo consent switch off → staff can no longer add photos
- [ ] Parent can't see other children, invoices of other families, or any staff menus

## 9. Fees
- [ ] Setup → Monthly fees → this month → Create & issue → 1 invoice per family: fee per child, sibling −10% on the younger,
      registration + deposit once, late pick-up fee, extra charge (e.g. field trip RM45)
- [ ] Run again → "already done", no duplicates; next month → no registration/deposit
- [ ] Invoices tab shows them; record a payment there
- [ ] Parent app → Fees: balance due and invoice lines; drafts are not visible to parents

## Known limits in this batch
- Ratios, licence rules and fee tax treatment are data you should check against your JKM/KPM licence and tax adviser.
- The deposit is booked as income by the invoice; move it to a liability with a manual journal if your accountant prefers.
- No live push notifications yet — parents get email/WhatsApp messages and see updates when they open or pull to refresh.
- Messages to parents without email go by WhatsApp (needs an approved WhatsApp template for business-initiated messages).
- Guardian photos for visual ID at pick-up and CCTV/live camera are not included.
