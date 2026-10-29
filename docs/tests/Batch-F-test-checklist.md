# Ai buddy Biz — Batch F test checklist (HR & payroll)

**APK:** https://github.com/jslproperties101/ai-buddy-biz/releases/download/batch-f/ai-buddy-biz-batch-f.apk
(the first APK build will include Batches B–F)

Before testing: apply `0001` → `0006_hr_payroll.sql`. More → Modules → make sure **HR & payroll** is on.
Tip: with 5+ modules on, the **Team** tab appears at the top of More instead of the bottom bar.

## 1. Employees
- [ ] Team → People → + Employee → name, email, job, start date, working days Mon–Fri, shift 09:00–18:00, 60 min break → Add (number E0001)
- [ ] Private: citizen, MyKad no., date of birth, gender, bank details
- [ ] Pay: basic RM2,200, allowance "Transport RM200" (taxable, EPF, SOCSO), PCB category, tax no.
- [ ] A full-time salary under RM1,700 shows a minimum-wage warning in payroll
- [ ] Manager role can see the staff list but **not** salaries, IC or bank details
- [ ] Team → People → calendar icon → add public holidays (e.g. Deepavali)

## 2. Staff self-service (sign in as the staff member, same email HR entered)
- [ ] More → My work → login links automatically; "Clock in" → shows time; can't clock in twice; "Clock out"
- [ ] Clocking in after shift start shows "x min late"
- [ ] Leave balances: Annual 8 (under 2 years), Sick 14, Maternity 98 (female) / Paternity 7 (male)
- [ ] Apply annual leave Fri → Wed over a weekend and a public holiday → counted as 3 days
- [ ] Overlapping leave and more days than the balance are refused
- [ ] Half-day leave counts 0.5
- [ ] New claim (parking RM12.50) → pending; future-dated claim refused; cancel a pending claim
- [ ] Staff can't see other people, salaries or draft payslips

## 3. Manager
- [ ] Team → Today: who's in, late (red), on leave, not clocked in; move between days
- [ ] Overtime shows as "OT 120m" → approve (can't approve more than worked)
- [ ] Team → Approvals: approve/reject leave and claims (with reason); can't approve own leave or claim

## 4. Payroll (Owner / HR)
- [ ] Team → Payroll → Run payroll → choose month → payslips created for active staff
- [ ] Joiner mid-month → basic prorated by calendar days (e.g. 17/31)
- [ ] Overtime: RM2,200 basic → 2 h normal OT = RM31.73; 4 h on rest day = RM42.31 (½ day); 8 h on public holiday = RM169.23 (2 days)
- [ ] Unpaid leave 2 days = RM169.23 deducted (basic ÷ 26 per day)
- [ ] Approved claims appear as reimbursement (not taxed, no EPF)
- [ ] EPF: wages RM1,700 → 187 / 221; RM5,000 → 550 / 650; RM5,050 → 561 / 612 (12% above RM5,000)
- [ ] EPF wages exclude overtime; SOCSO/EIS wages include it
- [ ] SOCSO top band (≥ RM5,900.01): employer 104.15, employee 29.75; EIS 11.90 each
- [ ] Age 60+: EPF employee 0%, employer 4%; SOCSO employer only; no EIS
- [ ] Foreign worker: EPF 2% + 2%; SOCSO employer-only category; no EIS; warning about non-resident tax
- [ ] PCB: RM5,000 single, no other income → RM110.00 in January; open "How PCB was worked out"
- [ ] Add a bonus (additional pay) → PCB on bonus shown separately
- [ ] Zakat RM50/month → PCB reduced by RM50
- [ ] Remove a manual line works; removing a system line (basic, OT) is refused
- [ ] Recalculate after changing attendance/leave → figures update
- [ ] Approve → locked; staff now see their payslip under My work → PDF payslip
- [ ] Can't create an earlier month once a later month is approved
- [ ] Mark salaries paid; record EPF, SOCSO + EIS, PCB payments (can't record twice)
- [ ] Statutory summary PDF shows totals to pay KWSP, PERKESO and LHDN
- [ ] Reports → Trial balance: Salaries & wages, Employer EPF/SOCSO/EIS, Staff claims, payables clear to zero after payments; Balanced ✓

## 5. Verify against official tools before going live
- [ ] Compare 3–5 payslips with LHDN e-PCB calculator, KWSP contribution table and PERKESO table
- [ ] If any SOCSO band differs, load the official table into `statutory_bands`

## Known limits in this batch
- Non-resident (foreign) employees' flat-rate tax isn't automatic — add it as a deduction
- EA form (yearly), CP22/CP22A and official upload files (Borang A, 8A, CP39) come in a later update; the summary PDF gives the totals
- Clock-in records phone time and outlet; GPS/selfie verification needs the location plugin (later)
- Leave entitlement uses completed years of service at 1 January; carry-forward is done with leave adjustments
