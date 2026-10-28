# Ai buddy Biz — Batch B test checklist (POS, inventory, SKU, barcode, labels)

**APK:** https://github.com/jslproperties101/ai-buddy-biz/releases/download/batch-b/ai-buddy-biz-batch-b.apk
(works once the repo exists, secrets are set and the first GitHub build finishes)

Before testing: apply `0001_core.sql` then `0002_pos_inventory.sql` to the Supabase project. Install the APK and allow "install unknown apps".

## 1. Sign up and set up
- [ ] Create an account with email + password; sign in
- [ ] Set up screen appears; create "Test Shop" as Retail shop
- [ ] Home shows business name, "Main" outlet and role "Owner"
- [ ] Bottom tabs: Sell, Products, Stock

## 2. Products, SKU and barcodes
- [ ] Add a product with price, cost, auto SKU, opening stock 50, reorder at 10
- [ ] Scan a real product barcode into the Barcode field with the camera
- [ ] Tap the sparkle icon → an in-store barcode starting with 2 is generated
- [ ] Add a carton barcode with 24 units/carton
- [ ] Add a product with 3 variants (e.g. S / M / L), each with its own SKU and price
- [ ] Saving two products with the same SKU or barcode shows a clear error
- [ ] Add a category from the product form
- [ ] Turn a product inactive → it disappears from the Sell search after sync
- [ ] Add a Service (no stock tracking) → no stock fields shown

## 3. Selling
- [ ] Sell tab: scan the product with the camera (continuous scanning adds each scan)
- [ ] Scanning the carton barcode adds 24 units in one go
- [ ] Type a SKU in search and press Enter → item is added
- [ ] Tap a cart line to change quantity or give a discount; − / + buttons work
- [ ] Menu → Default tax rate → 6% → tax line shows on the cart
- [ ] Charge → Cash → quick-cash buttons → change is shown correctly
- [ ] Charge by Card / QR / E-wallet → amount locked to the total
- [ ] Receipt number shows (R000001, R000002 …) and goes up by 1 each sale
- [ ] Print receipt → Android print screen opens (save as PDF to check it)

## 4. Offline selling (important)
- [ ] Turn on airplane mode → sync shows "Offline — using saved products"
- [ ] Make 2 sales offline → "Saved offline"; sync icon shows a badge of 2
- [ ] Turn internet back on → tap sync → "Synced 2 offline sale(s)"
- [ ] Stock goes down correctly; no sale appears twice

## 5. Stock
- [ ] Stock tab shows quantities for the outlet; sold items have gone down
- [ ] Receive 10, Count (enter real shelf count), Damage 1 → numbers update
- [ ] Item at or below reorder point shows red; "Low stock" filter lists it
- [ ] "Scan to count" opens the camera and jumps to that item
- [ ] Add a second outlet in Supabase (outlets table) → Transfer 5 between outlets works; Switch outlet in the menu

## 6. Labels
- [ ] Products → label icon → choose 3 labels, 40 × 30 mm → print preview shows name, price, barcode and SKU
- [ ] Scan the printed (or on-screen) label at the POS → correct item is added
- [ ] Try the 100 × 50 mm carton size and "Show price" off

## 7. Roles and limits
- [ ] Add a second user as Cashier (memberships table in Supabase)
- [ ] Cashier sees Sell, Products (read only, no + button) and Stock (no adjust)
- [ ] Cashier discount over 10% is blocked with "needs a manager"
- [ ] Cashier only sees their own sales
- [ ] A user from another business cannot see your products or sell from your outlet

## Known limits in this batch
- Tax is one default rate; zone-based tax comes in Batch C
- Sales reports, shifts screen and voids in the app come in Batch C; voiding works through the database for now
- Purchase orders are in the database but have no screen yet
