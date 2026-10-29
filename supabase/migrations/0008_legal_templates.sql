-- Ai buddy Biz — starter legal templates (Malaysia). Plain-English drafts for everyday use.
-- They are a starting point, not legal advice: have a Malaysian lawyer review them for your business,
-- especially for high-value or unusual deals.

insert into public.legal_templates (tenant_id, code, name, category, description, body, variables) values
(null, 'my_nda_mutual', 'Mutual non-disclosure agreement', 'nda',
 'Both sides keep each other''s confidential information secret while discussing a possible deal.',
$tpl$MUTUAL NON-DISCLOSURE AGREEMENT

This Agreement is made on {{effective_date}} between:

(1) {{company_name}} (Registration No. {{company_reg_no}}), of {{company_address}} ("{{company_short}}"); and
(2) {{counterparty_name}} (Registration / NRIC No. {{counterparty_reg_no}}), of {{counterparty_address}} ("{{counterparty_short}}"),

each a "Party" and together the "Parties".

1. PURPOSE
The Parties wish to share information to evaluate {{purpose}} (the "Purpose").

2. CONFIDENTIAL INFORMATION
"Confidential Information" means all information, in any form, disclosed by one Party (the "Discloser") to the other (the "Recipient") in connection with the Purpose that is marked confidential or that a reasonable person would understand to be confidential, including business plans, prices, customer and supplier details, know-how, software and personal data.

3. EXCLUSIONS
Confidential Information does not include information that the Recipient can show: (a) is or becomes public other than through the Recipient's breach; (b) was lawfully known to the Recipient before disclosure without a duty of confidence; (c) is received from a third party who was free to disclose it; or (d) was developed independently without use of the Discloser's information.

4. OBLIGATIONS
The Recipient shall: (a) use the Confidential Information only for the Purpose; (b) keep it secret using at least the care it uses for its own confidential information, and no less than reasonable care; (c) disclose it only to its directors, employees and professional advisers who need to know it for the Purpose and who are bound by confidentiality duties no less strict than this Agreement; and (d) be responsible for any breach by those persons.

5. REQUIRED DISCLOSURE
The Recipient may disclose Confidential Information if required by law, court order or a regulator, provided it (where lawful) gives the Discloser prompt notice and discloses only what is required.

6. PERSONAL DATA
Each Party shall handle any personal data received under this Agreement in accordance with the Personal Data Protection Act 2010.

7. RETURN OR DESTRUCTION
On request, or when discussions end, the Recipient shall promptly return or destroy the Confidential Information, except copies it must keep by law or in automatic back-ups, which remain subject to this Agreement.

8. NO LICENCE OR COMMITMENT
No rights in the Confidential Information are granted except as stated. Nothing in this Agreement obliges either Party to enter into any further transaction.

9. TERM
This Agreement applies to disclosures made within {{disclosure_period}} from the date above. The obligations in clauses 4 to 7 continue for {{confidentiality_years}} years after the last disclosure, and for trade secrets for as long as they remain trade secrets.

10. REMEDIES
Damages may not be an adequate remedy for breach, and the Discloser may seek an injunction or other equitable relief in addition to any other remedy.

11. GENERAL
This Agreement is the entire agreement on its subject. Any change must be in writing and signed by both Parties. It may be signed electronically and in counterparts. It is governed by the laws of Malaysia, and the Parties submit to the exclusive jurisdiction of the courts of Malaysia.

Signed by the Parties on the dates shown below.
$tpl$,
'[{"key":"effective_date","label":"Date","type":"date","required":true},
  {"key":"company_short","label":"Your short name","type":"text","required":true},
  {"key":"counterparty_name","label":"Other party name","type":"text","required":true},
  {"key":"counterparty_reg_no","label":"Other party reg./NRIC no.","type":"text","required":true},
  {"key":"counterparty_address","label":"Other party address","type":"longtext","required":true},
  {"key":"counterparty_short","label":"Other party short name","type":"text","required":true},
  {"key":"purpose","label":"Purpose (what you are discussing)","type":"longtext","required":true},
  {"key":"disclosure_period","label":"Disclosure period","type":"text","required":true,"default":"12 months"},
  {"key":"confidentiality_years","label":"Years confidentiality lasts","type":"number","required":true,"default":"3"}]'),

(null, 'my_employment', 'Employment contract (Employment Act 1955)', 'employment',
 'Written contract for a permanent employee in Peninsular Malaysia / Labuan. Sabah and Sarawak have their own Labour Ordinances.',
$tpl$CONTRACT OF EMPLOYMENT

Date: {{effective_date}}

Employer: {{company_name}} (Registration No. {{company_reg_no}}), {{company_address}} (the "Company")
Employee: {{employee_name}} (NRIC/Passport No. {{employee_id_no}}), {{employee_address}} (the "Employee")

1. POSITION AND START DATE
The Company employs the Employee as {{job_title}}, starting on {{start_date}}, reporting to {{reports_to}}. The Employee shall perform the duties reasonably assigned by the Company.

2. PROBATION
The first {{probation_months}} months are a probationary period, which the Company may extend once by up to {{probation_months}} months by written notice. During probation either party may end employment by giving {{probation_notice}} written notice or wages in lieu.

3. PLACE AND HOURS OF WORK
The Employee's usual place of work is {{work_location}}. Normal working hours are {{working_hours}}, with {{rest_day}} as the rest day. Normal hours will not exceed those permitted by the Employment Act 1955 (currently 45 hours a week). Overtime, rest-day and public-holiday work will be paid as required by the Employment Act 1955 where it applies to the Employee.

4. WAGES
The Employee's basic salary is {{currency}} {{basic_salary}} per month, paid no later than the 7th day after the end of each wage period by bank transfer. Allowances: {{allowances}}. The Company will make deductions required by law, including EPF, SOCSO, EIS and monthly tax deductions (PCB).

5. ANNUAL LEAVE
The Employee is entitled to {{annual_leave_days}} days of paid annual leave for each 12 months of continuous service, and not less than the Employment Act 1955 minimum (8 days for less than 2 years' service, 12 days for 2 to 5 years, 16 days for 5 years or more), pro-rated in the first and last year.

6. SICK LEAVE, HOSPITALISATION AND OTHER LEAVE
After examination by a registered medical practitioner, the Employee is entitled to paid sick leave of 14 days a year (less than 2 years' service), 18 days (2 to 5 years) or 22 days (5 years or more), and up to 60 days a year in total where hospitalisation is necessary. Maternity leave of 98 consecutive days and paternity leave of 7 consecutive days apply as provided in the Employment Act 1955. The Employee is also entitled to paid public holidays as provided by law.

7. BENEFITS
{{benefits}}

8. CONDUCT AND COMPANY POLICIES
The Employee shall follow the Company's lawful and reasonable instructions and policies, as updated from time to time, including policies on conduct, safety, information security and sexual harassment.

9. CONFIDENTIALITY AND COMPANY PROPERTY
During and after employment, the Employee shall not disclose or misuse the Company's confidential information, including customer, supplier, pricing and personal data. Work produced in the course of employment belongs to the Company. On leaving, the Employee shall return all Company property and information.

10. TERMINATION
After probation, either party may end this contract by giving written notice of not less than {{notice_period}}, and in any case not less than the Employment Act 1955 minimum (4 weeks for less than 2 years' service, 6 weeks for 2 to 5 years, 8 weeks for 5 years or more), or by paying wages in lieu of notice. The Company may end employment without notice for misconduct after due inquiry, as permitted by law. Termination and lay-off benefits are payable where required by law.

11. PERSONAL DATA
The Employee consents to the Company processing their personal data for employment, payroll, statutory and business purposes as described in the Company's privacy notice, in line with the Personal Data Protection Act 2010.

12. GENERAL
This contract replaces any earlier understanding about the Employee's employment. If any term is less favourable to the Employee than the Employment Act 1955 or other law, the law prevails. This contract is governed by the laws of Malaysia.

Signed by the Company and accepted by the Employee on the dates shown below.
$tpl$,
'[{"key":"effective_date","label":"Contract date","type":"date","required":true},
  {"key":"employee_name","label":"Employee full name","type":"text","required":true},
  {"key":"employee_id_no","label":"NRIC / passport no.","type":"text","required":true},
  {"key":"employee_address","label":"Employee address","type":"longtext","required":true},
  {"key":"job_title","label":"Job title","type":"text","required":true},
  {"key":"start_date","label":"Start date","type":"date","required":true},
  {"key":"reports_to","label":"Reports to","type":"text","required":true},
  {"key":"probation_months","label":"Probation (months)","type":"number","required":true,"default":"3"},
  {"key":"probation_notice","label":"Notice during probation","type":"text","required":true,"default":"1 week''s"},
  {"key":"work_location","label":"Place of work","type":"text","required":true},
  {"key":"working_hours","label":"Working hours","type":"text","required":true,"default":"9.00 am to 6.00 pm, Monday to Friday, with a 1-hour break"},
  {"key":"rest_day","label":"Rest day","type":"text","required":true,"default":"Sunday"},
  {"key":"currency","label":"Currency","type":"text","required":true,"default":"RM"},
  {"key":"basic_salary","label":"Basic salary per month","type":"money","required":true},
  {"key":"allowances","label":"Allowances","type":"longtext","required":true,"default":"None"},
  {"key":"annual_leave_days","label":"Annual leave days","type":"number","required":true,"default":"8"},
  {"key":"benefits","label":"Benefits (medical, insurance…)","type":"longtext","required":true,"default":"Medical treatment at the Company''s panel clinics, subject to the Company''s policy."},
  {"key":"notice_period","label":"Notice period after probation","type":"text","required":true,"default":"1 month"}]'),

(null, 'my_service_agreement', 'Service agreement', 'service',
 'You provide services to a client: scope, fees, payment terms, liability and termination.',
$tpl$SERVICE AGREEMENT

This Agreement is made on {{effective_date}} between {{company_name}} (Registration No. {{company_reg_no}}), {{company_address}} (the "Provider"), and {{client_name}} (Registration No. {{client_reg_no}}), {{client_address}} (the "Client").

1. SERVICES
The Provider shall provide the following services (the "Services"): {{scope}}
Deliverables and timelines: {{deliverables}}

2. TERM
This Agreement starts on {{start_date}} and continues until {{end_date}}, unless ended earlier under clause 9.

3. FEES AND PAYMENT
The Client shall pay {{currency}} {{fees}} {{fee_basis}}. The Provider will invoice {{invoice_timing}}, and the Client shall pay each invoice within {{payment_days}} days. Fees exclude applicable taxes (including service tax), which the Client shall pay. Late amounts carry interest at {{late_interest}} per year from the due date until paid.

4. CHANGES
Changes to the Services must be agreed in writing, including any change in fees or timelines.

5. CLIENT RESPONSIBILITIES
The Client shall give the Provider timely access, information and decisions reasonably needed. The Provider is not responsible for delays caused by the Client.

6. STANDARD OF WORK
The Provider shall perform the Services with reasonable skill, care and diligence and in line with applicable law. The Provider shall re-perform, at no extra charge, any Services that do not meet this standard if notified within {{warranty_days}} days of delivery.

7. INTELLECTUAL PROPERTY
On full payment, the Client owns the deliverables created specifically for it. The Provider keeps its pre-existing materials, tools and know-how and grants the Client a non-exclusive licence to use them as part of the deliverables.

8. CONFIDENTIALITY AND PERSONAL DATA
Each party shall keep the other's confidential information secret and use it only for this Agreement. Where the Provider processes personal data for the Client, it shall do so only on the Client's instructions, keep it secure and comply with the Personal Data Protection Act 2010.

9. TERMINATION
Either party may end this Agreement: (a) by {{termination_notice}} written notice; or (b) immediately by written notice if the other party materially breaches it and does not fix the breach within 14 days of notice, or becomes insolvent. On termination the Client shall pay for Services performed up to the termination date.

10. LIABILITY
Neither party is liable for indirect or consequential loss, or loss of profit. Each party's total liability under this Agreement is limited to the fees paid or payable in the 12 months before the claim, except for fraud, wilful misconduct, death or personal injury caused by negligence, or anything that cannot be limited by law.

11. FORCE MAJEURE
Neither party is liable for delay caused by events beyond its reasonable control. If such an event lasts more than 60 days, either party may end this Agreement by notice.

12. GENERAL
This Agreement is the entire agreement on its subject and may be changed only in writing signed by both parties. Neither party may transfer it without the other's consent, which shall not be unreasonably withheld. Notices may be given by email to the addresses each party provides. It may be signed electronically. It is governed by the laws of Malaysia, and the courts of Malaysia have exclusive jurisdiction.
$tpl$,
'[{"key":"effective_date","label":"Date","type":"date","required":true},
  {"key":"client_name","label":"Client name","type":"text","required":true},
  {"key":"client_reg_no","label":"Client reg. no.","type":"text","required":true},
  {"key":"client_address","label":"Client address","type":"longtext","required":true},
  {"key":"scope","label":"Scope of services","type":"longtext","required":true},
  {"key":"deliverables","label":"Deliverables & timelines","type":"longtext","required":true},
  {"key":"start_date","label":"Start date","type":"date","required":true},
  {"key":"end_date","label":"End date","type":"date","required":true},
  {"key":"currency","label":"Currency","type":"text","required":true,"default":"RM"},
  {"key":"fees","label":"Fees","type":"money","required":true},
  {"key":"fee_basis","label":"Fee basis","type":"text","required":true,"default":"per month"},
  {"key":"invoice_timing","label":"When you invoice","type":"text","required":true,"default":"monthly in advance"},
  {"key":"payment_days","label":"Payment days","type":"number","required":true,"default":"30"},
  {"key":"late_interest","label":"Late interest","type":"text","required":true,"default":"8%"},
  {"key":"warranty_days","label":"Days to report defects","type":"number","required":true,"default":"30"},
  {"key":"termination_notice","label":"Notice to end","type":"text","required":true,"default":"30 days''"}]'),

(null, 'my_sales_terms', 'Terms & conditions of sale (B2B)', 'sales_terms',
 'Standard terms for selling goods to business customers: orders, delivery, risk, payment, returns, liability.',
$tpl$TERMS AND CONDITIONS OF SALE
{{company_name}} (Registration No. {{company_reg_no}}) — effective {{effective_date}}

1. APPLICATION
These terms apply to every sale of goods by {{company_name}} (the "Seller") to a business customer (the "Buyer") and override any terms in the Buyer's documents unless the Seller agrees otherwise in writing.

2. ORDERS AND PRICES
A quotation is valid for {{quote_validity}} days. An order is binding only when the Seller confirms it. Prices are in {{currency}} and exclude taxes and delivery unless stated. The Seller may adjust prices before confirmation for changes in costs, duties or exchange rates.

3. DELIVERY
Delivery dates are estimates. Delivery terms are {{delivery_terms}}. Risk passes to the Buyer on delivery. Ownership passes only when the Seller has received payment in full; until then the Buyer holds the goods for the Seller and keeps them identifiable and insured.

4. INSPECTION AND RETURNS
The Buyer shall inspect goods on delivery and report shortages or visible damage within {{inspection_days}} days. Defective goods reported within {{defect_days}} days of delivery will be repaired, replaced or credited at the Seller's option. Goods may not be returned without the Seller's prior written approval.

5. PAYMENT
Payment is due {{payment_terms}}. Late amounts carry interest at {{late_interest}} per year. The Seller may suspend deliveries while any amount is overdue and may recover reasonable collection costs.

6. LIABILITY
The Seller is not liable for indirect or consequential loss, or loss of profit. The Seller's total liability for any order is limited to the price of that order. Nothing limits liability that cannot be limited by law.

7. FORCE MAJEURE
The Seller is not liable for delay or failure caused by events beyond its reasonable control.

8. PERSONAL DATA
The Seller handles personal data in line with its privacy notice and the Personal Data Protection Act 2010.

9. GENERAL
These terms are governed by the laws of Malaysia and the courts of Malaysia have exclusive jurisdiction. If any part is unenforceable, the rest remains in force.
$tpl$,
'[{"key":"effective_date","label":"Effective date","type":"date","required":true},
  {"key":"quote_validity","label":"Quotation valid (days)","type":"number","required":true,"default":"14"},
  {"key":"currency","label":"Currency","type":"text","required":true,"default":"RM"},
  {"key":"delivery_terms","label":"Delivery terms","type":"text","required":true,"default":"delivered to the Buyer''s premises in Peninsular Malaysia"},
  {"key":"inspection_days","label":"Days to report damage","type":"number","required":true,"default":"3"},
  {"key":"defect_days","label":"Days to report defects","type":"number","required":true,"default":"30"},
  {"key":"payment_terms","label":"Payment terms","type":"text","required":true,"default":"within 30 days of the invoice date"},
  {"key":"late_interest","label":"Late interest","type":"text","required":true,"default":"8%"}]'),

(null, 'my_privacy_notice', 'Privacy notice (PDPA 2010)', 'privacy',
 'Tell customers and staff how you use their personal data. Publish it in both Bahasa Malaysia and English.',
$tpl$PRIVACY NOTICE
{{company_name}} (Registration No. {{company_reg_no}}) — last updated {{effective_date}}

This notice explains how we collect and use your personal data under the Personal Data Protection Act 2010 ("PDPA"). A Bahasa Malaysia version is available, and if there is any difference the {{prevailing_language}} version prevails.

1. WHAT WE COLLECT
{{data_collected}}

2. WHY WE USE IT
We use your personal data to: {{purposes}}. We will ask for your consent before sending you marketing, and you can withdraw it at any time.

3. WHERE IT COMES FROM
We collect personal data from you directly, from your use of our services and, where relevant, from {{other_sources}}.

4. WHO WE SHARE IT WITH
We may share personal data with: {{recipients}}. They may use it only for the purposes above. Where data is transferred outside Malaysia, we take steps to ensure it is protected to a standard comparable to the PDPA.

5. WHETHER YOU MUST PROVIDE IT
{{obligatory_data}} Without this information we may be unable to provide our products or services.

6. HOW LONG WE KEEP IT AND HOW WE PROTECT IT
We keep personal data only as long as needed for these purposes or as required by law, and protect it with reasonable security measures. If a personal data breach is likely to cause you significant harm, we will notify the Personal Data Protection Commissioner and you as required by law.

7. YOUR RIGHTS
You may ask to access or correct your personal data, ask us to stop processing it for direct marketing, ask to transfer it to another organisation where the law allows, or withdraw your consent, by contacting us below. We may charge a fee for access requests as allowed by law.

8. CONTACT
{{contact_person}}, {{company_address}}, email {{contact_email}}, phone {{contact_phone}}.
$tpl$,
'[{"key":"effective_date","label":"Date","type":"date","required":true},
  {"key":"prevailing_language","label":"Prevailing language","type":"text","required":true,"default":"English"},
  {"key":"data_collected","label":"What data you collect","type":"longtext","required":true,"default":"Your name, contact details, identity card number where required, delivery address, purchase history, payment details and communications with us."},
  {"key":"purposes","label":"Why you use it","type":"longtext","required":true,"default":"process orders and payments, deliver products, provide customer support, manage loyalty points, meet legal and tax obligations, and improve our services"},
  {"key":"other_sources","label":"Other sources","type":"text","required":true,"default":"our partners, delivery providers and publicly available sources"},
  {"key":"recipients","label":"Who you share with","type":"longtext","required":true,"default":"our delivery, payment, IT and messaging service providers; professional advisers; and government authorities where required by law"},
  {"key":"obligatory_data","label":"Which data is required","type":"longtext","required":true,"default":"Your name, contact details and delivery address are required to fulfil orders. Other information is optional."},
  {"key":"contact_person","label":"Contact person / DPO","type":"text","required":true},
  {"key":"contact_email","label":"Contact email","type":"text","required":true},
  {"key":"contact_phone","label":"Contact phone","type":"text","required":true}]');
