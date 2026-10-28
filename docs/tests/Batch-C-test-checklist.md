# Ai buddy Biz — Batch C test checklist (invoicing, accounting, tax, reports, shifts)

**APK:** https://github.com/jslproperties101/ai-buddy-biz/releases/download/batch-c/ai-buddy-biz-batch-c.apk
(the first APK build includes Batches B and C together)

Before testing: apply `0001`, `0002`, then `0003_finance_tax.sql` to Supabase.

## 1. Tax by zone
- [ ] More → Tax shows Malaysia rates: Sales tax 10%, 5%, Service tax 8%, 6%, Exempt
- [ ] Edit a product → Tax → pick "Service tax 8%"; another stays on business default (10%)
- [ ] Sell one of each → each line uses its own rate; receipt and Sales history show the tax names
- [ ] More → Tax → change outlet country to Australia → rates show "included in price"; a RM11 sale shows "Includes tax 1.00" and total stays 11.00
- [ ] Set country United States, state California → 7.25%; Texas → 6.25%; a state not listed → no sales tax
- [ ] Add your own rate (e.g. standard 8% valid from a future date) → today's sales still use the old rate
- [ ] Set the outlet back to Malaysia when done
- [ ] Offline: airplane mode → sell → tax still shows correctly from the saved rates

## 2. Shifts and cash drawer
- [ ] Sell tab shows "No shift open" banner for Owner/Manager/Cashier
- [ ] More → Shift → open with RM100 float → banner disappears
- [ ] Make a cash sale and a card sale → Shift screen "Expected in drawer" = 100 + cash sales only
- [ ] Close shift counting RM1 less → shows "Short by RM 1.00"
- [ ] Trying to open a second shift at the same outlet is blocked

## 3. Sales history and voids
- [ ] More → Sales history lists receipts; search by receipt number works
- [ ] Open a receipt → Reprint opens the receipt PDF
- [ ] Owner/Manager: Void with a reason → receipt shows crossed out; stock goes back up
- [ ] Cashier: no Void button, and only sees their own receipts

## 4. Invoices
- [ ] Invoices tab → + Invoice → choose customer → add a new customer with company and TIN
- [ ] Add a product line and a custom line (with a discount) → totals update as you type
- [ ] Save draft → leave and reopen → everything is still there
- [ ] Issue invoice → number INV-00001; status ISSUED; due date = issue date + 30 days
- [ ] Stock for the product line goes down
- [ ] Issued invoice cannot be edited (no Save button, fields locked)
- [ ] Record payment of part of the balance → PARTIAL; balance goes down
- [ ] Paying more than the balance is blocked
- [ ] Pay the rest → PAID
- [ ] Print → A4 tax invoice PDF with your business, customer TIN, tax per line, totals and balance
- [ ] Issue a second invoice, then Void it with a reason → VOID; stock comes back
- [ ] An invoice with payments cannot be voided
- [ ] Filters: Unpaid, Overdue, Drafts, Paid, All; "Owed to you" total is correct
- [ ] Delete a draft → it disappears

## 5. Accounting (automatic)
- [ ] More → Reports → Trial balance → shows Cash, Card clearing, Bank, Receivables, Inventory, Tax payable, Sales, Cost of goods sold, Owner's equity
- [ ] Bottom line says "Balanced ✓"
- [ ] Opening stock appears as Inventory and Owner's equity
- [ ] A voided sale or invoice is fully reversed (no change in Sales after void)

## 6. Reports
- [ ] Sales: Today / 7 days / This month / Last month / This year change the figures
- [ ] KPIs (sales, receipts, average, tax), by payment method, by-day bars and top items look right
- [ ] All outlets switch appears when you have more than one outlet
- [ ] Profit & loss: income, cost of goods, gross margin %, net profit
- [ ] Tax: tax collected split by tax name, POS vs Invoices — matches what you sold
- [ ] Cashier cannot open Reports

## 7. Roles
- [ ] Accountant role (add in memberships table): sees Invoices and Reports incl. trial balance; can record payments
- [ ] Manager: invoices, payments and sales reports, but no trial balance and can't change tax rates
- [ ] Cashier: no Invoices tab, no Reports

## Known limits in this batch
- e-Invoice (MyInvois) fields are in place; actual submission to LHDN comes with the integrations batch and needs your LHDN API credentials
- Credit notes / refunds of paid invoices come later
- Starter tax rates must be checked with your tax adviser before going live
