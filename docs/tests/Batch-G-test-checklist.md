# Ai buddy Biz — Batch G test checklist (Legal & compliance, AI lawyer)

**APK:** https://github.com/jslproperties101/ai-buddy-biz/releases/download/batch-g/ai-buddy-biz-batch-g.apk
(the first APK build will include Batches B–G)

Before testing:
- Apply `0001` → `0008_legal_templates.sql`.
- Host `web/sign.html` (with your Supabase URL + anon key) and set the repo variable `SIGN_URL`.
- For AI: `supabase secrets set ANTHROPIC_API_KEY=…` then `supabase functions deploy ai-legal`.
- For emailed/WhatsApp links and codes: the `send-messages` function from Batch D must be running.
- More → Modules → turn on **Legal & compliance**. (With 5+ modules on, **Legal** appears at the top of More.)

## 1. Company details & templates
- [ ] Legal → 🏢 icon → enter registered name, reg. no. (e.g. 202301012345 (1234567-A)), address → Save
- [ ] Templates tab shows 5 starter templates; open one → text preview
- [ ] Customise a starter template → it becomes "Your template"; edit it again → saved
- [ ] Cashier / Sales role can't create templates (no + button)

## 2. Contract from a template
- [ ] Templates → Mutual NDA → Use → contract LAW-00001 opens with your company name, reg. no. and address already filled
- [ ] Red line lists the blanks left; tap **Fill in** → labelled fields (dates have a date picker, defaults pre-filled) → Apply → no blanks left
- [ ] Details (pencil): link a customer, value, start/end date, notice days, auto-renew → Save
- [ ] Setting an end date + notice days adds "Expiry" and "Notice deadline" under Key dates and in the Calendar
- [ ] Edit the text directly → saved; ⋮ → Save a version → Saved versions shows it
- [ ] ⋮ → Mark in review → Back to draft works
- [ ] Contract list: search by title/number; filters Active / Awaiting signature / Signed / All

## 3. Signers & sending
- [ ] Add signer "you" (Us, order 1) and the customer (Other party, order 2, "Use <customer>" fills name/email/phone)
- [ ] Bad email is refused; "code" without email/phone is refused
- [ ] Send with blanks left → refused with the blank names
- [ ] Send for e-signature → wording locked (Edit/Fill in disappear), fingerprint shown, status "Out for signature"
- [ ] Share icon on each signer → Copy link / WhatsApp / Email
- [ ] With "Send links by email/WhatsApp" on → messages appear in the outbound queue

## 4. Signing page (open the link on another phone or PC)
- [ ] Page shows business, title, full text, signer list, fingerprint
- [ ] Signer 2 opening before signer 1 signs → "Waiting for earlier signers"
- [ ] Sign without name / drawing / consent tick → clear error each time
- [ ] With code on: Send code → code arrives → wrong code refused (5 tries max) → right code works
- [ ] After signing: "✔ Signed"; the app shows ✔ for that signer and status "Partly signed"
- [ ] Last signer signs → status "Signed", Activity shows viewed/signed/completed with times and IP
- [ ] Decline on another test contract → reason shows in the app
- [ ] An old link after **Cancel signing** → "Link not valid"

## 5. Signed PDF & verification
- [ ] PDF icon → contract text, each drawn signature with name and date, then an Audit trail page with the fingerprint and every event
- [ ] Open `SIGN_URL?verify=<fingerprint>` → "✔ Document found" with signers
- [ ] Change one character of the fingerprint → "No match"
- [ ] ⋮ → End / terminate (reason + date) → status Terminated, its open reminders disappear from the Calendar

## 6. Compliance calendar
- [ ] Calendar lists EPF, SOCSO/EIS, PCB (15th), SST return, CP204, EA forms, Form E, PDPA review
- [ ] "Needs a date from you": Form C, SSM annual return, SSM accounts, premise licence → tap → Set the date
- [ ] Mark EPF done → next month's EPF appears automatically
- [ ] "Not applicable to us" on SST (if not registered) → moves to done; Reopen works
- [ ] + → add "Renew halal certificate", yearly → appears in the right group
- [ ] Overdue items in red, due-soon in orange; Show done toggles history
- [ ] Accountant role: can tick off calendar items but can't create contracts

## 7. AI legal assistant (needs the API key)
- [ ] Contract → **AI review** → summary, risk level, issues with suggested wording (Copy wording), missing clauses, tips
- [ ] **Find key dates** → tick dates → "Add to the calendar" → they show under Key dates as "from AI"
- [ ] ✨ icon on Legal → Ask: "Can I deduct a staff member's salary for a broken item?" → answer, key points, laws, "talk to a lawyer" when relevant
- [ ] Draft: describe a supply agreement → draft with {{blanks}} → Make it a contract → opens as a draft
- [ ] Counter shows "x of y AI requests used this month"; at the limit a clear "Monthly AI limit reached" message
- [ ] A role without AI permission doesn't see the AI buttons

## Known limits in this batch
- E-signatures here are "simple" electronic signatures. For deals that need a **digital signature** (licensed certification authority under the Digital Signature Act 1997), use a CA such as MSC Trustgate or Pos Digicert.
- Wills, powers of attorney, trusts and negotiable instruments must be printed and signed by hand.
- Stamp duty is not calculated — stamp contracts through LHDN's STAMPS portal where needed.
- PDFs use the built-in font: Chinese/Tamil/Jawi characters print as "?" (full font support comes later).
- AI answers are general information, not legal advice. Check key dates and statutes yourself.
