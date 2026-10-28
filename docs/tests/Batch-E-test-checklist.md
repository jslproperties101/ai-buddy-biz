# Ai buddy Biz — Batch E test checklist (shipping, cargo, customs, suppliers, purchasing)

**APK:** https://github.com/jslproperties101/ai-buddy-biz/releases/download/batch-e/ai-buddy-biz-batch-e.apk
(the first APK build will include Batches B–E)

Before testing: apply `0001` → `0005_logistics.sql`. Optional: host `web/track.html` and set the GitHub repo variable `TRACK_URL`.

## 1. Modules
- [ ] Sign up a new business as **Freight forwarder** → bottom tabs: Shipping · Invoices · CRM · More (no Sell or Catalog)
- [ ] Retail business → More → Modules → turn on "Shipping & cargo" → Shipping tab appears
- [ ] Turn on all five modules → only 4 fit at the bottom; the 5th appears at the top of More and opens fine
- [ ] Turning a module off hides it; turning it back on shows the old data again

## 2. Air shipment
- [ ] Shipping → + Shipment → Air, KUL → LHR, customer, shipper, consignee, carrier, ETD/ETA → Create (gets SHP-000001)
- [ ] MAWB `232-12345670` is rejected (wrong check digit); `232-12345675` is accepted
- [ ] Add cargo: 10 cartons 50×40×30 cm, 8 kg each + 1 pallet 120×100×150 cm, 200 kg → totals 11 pkgs, 280 kg, 2.4 cbm, **chargeable 400 kg**
- [ ] Switch mode to Sea LCL → chargeable becomes 2.4 W/M
- [ ] Dangerous goods without a UN number is refused; with UN1263 class 3 it saves
- [ ] ETA earlier than ETD is refused

## 3. Tracking
- [ ] "Update" button → Booked → Departed → Arrived → Released → Delivered; status follows; departed/arrived times fill in
- [ ] Posting an older milestone (e.g. Picked up after Departed) doesn't move the status backwards
- [ ] An update marked "not shown to customer" shows "(internal)"
- [ ] Copy tracking link → open it (or `web/track.html?t=<code>`) → status and milestones show; internal notes, prices and parties don't
- [ ] Draft shipments don't show on the tracking page
- [ ] Driver role (memberships table) sees shipments and can post updates, but sees no charges and can't edit

## 4. Sea FCL, containers, vessels
- [ ] Shipping → Fleet → add vessel with IMO `9074729` (valid); `9074728` is refused
- [ ] Add voyage PKG → RTM with ETD/ETA → pick it on an FCL shipment (ETD/ETA fill in)
- [ ] Add container `CSQU3054384` → refused (ISO 6346 check digit); `CSQU3054383` 40HC tare 3900 cargo 18000 → VGM 21,900 kg
- [ ] 2×40HC + 1×20GP → chargeable 5 TEU
- [ ] Mark the voyage departed / arrived from the Fleet list

## 5. Charges, profit, billing
- [ ] Add cost: freight 400 × 9.50 MYR from carrier; add revenue: freight 400 × 12 MYR, docs 50 USD at FX 4.40 with Service tax 8%
- [ ] Revenue 5,020 · cost 3,800 · profit shown with %
- [ ] Invoice customer → draft invoice opens with both lines; USD line shows its original amount; tax applied per line
- [ ] Invoiced charges can't be edited; deleting the draft invoice frees them; voiding an issued invoice frees them too
- [ ] Post costs → "posted to accounts payable"; can't post twice
- [ ] Reports → Trial balance: Freight & logistics costs and Accounts payable appear; still Balanced ✓
- [ ] Operations role can run shipments but can't invoice or post costs

## 6. Quotes & rate cards
- [ ] Rates → add air KUL→LHR for two carriers (kg, minimum, buy/sell, valid to); add an expired cheaper one
- [ ] Quote → Air, 280 kg / 2.4 cbm → both carriers priced on 400 kg, cheapest first, expired rate ignored
- [ ] Tiny parcel (10 kg) → minimum charge used
- [ ] FCL quote 2×40HC + 1×20GP → only carriers that price **every** container type appear
- [ ] "Use" on a quote → creates a quoted shipment with matching revenue and cost lines
- [ ] Rates expiring within 7 days show in red

## 7. Duties & taxes (landed cost)
- [ ] Quote tab → destination Port Klang (MY), HS 621410, value 2000, freight 300, insurance 20 → customs value 2,320 (CIF), "no duty rate on file", sales tax 10% = 232
- [ ] Value 400 + freight 50 → "below the MYR 500 duty-free limit"
- [ ] Destination US with duty rate 5% entered by hand → valuation basis FOB (freight not included)
- [ ] Destination Germany/Netherlands → note about the €3 flat low-value charge
- [ ] On a shipment with item values and HS codes → menu → Estimate duties & taxes → per-line breakdown

## 8. Documents
- [ ] Menu → Print package labels → one 4×6" label per package: big origin/destination codes, consignee, barcode of SHP ref, "Package n of N", tracking QR, DG box when relevant
- [ ] Menu → Commercial invoice & packing list → 2-page PDF with parties, HS codes, values, dimensions, weights, containers

## 9. Suppliers & purchasing
- [ ] More → Suppliers & purchasing → add a goods supplier (lead time 5 days, rating 4★) and an airline (AWB prefix)
- [ ] Add contact person and a document expiring in 10 days (orange) and one expired (red)
- [ ] New PO → supplier fills expected date from lead time → add item, 100 × 3.00 → Mark as sent (PO-00001)
- [ ] Receive 40 → status Partial; item cost becomes the moving average; stock goes up
- [ ] Receiving more than 110% of ordered is refused
- [ ] Receive the remaining 60 at 3.50 → Received; scorecard shows POs on time %, spend 12m
- [ ] Carrier scorecard shows shipments and freight spend; transit on-time % after a shipment arrives
- [ ] Trial balance: Inventory and Accounts payable increase by the goods received

## Known limits in this batch
- Duty rates are not preloaded — load a tariff schedule from a provider or enter rates by HS code
- Customs values are in the destination currency you type; automatic exchange rates come later
- Live carrier tracking (airline/shipping-line APIs, AIS) and e-filing to customs (e.g. uCustoms) need partner accounts; planned for the integrations batch
- Supplier documents store details only; file upload comes with the documents/storage update
