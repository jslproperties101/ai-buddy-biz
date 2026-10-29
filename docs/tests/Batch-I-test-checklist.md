# Ai buddy Biz — Batch I test checklist (Restaurant, orders, delivery, bookings, online shops)

**APK:** https://github.com/jslproperties101/ai-buddy-biz/releases/download/batch-i/ai-buddy-biz-batch-i.apk
(the first APK build will include Batches B–I)

Before testing:
- Apply `0001` → `0010_ext.sql`.
- Host `web/menu.html`, `web/order.html`, `web/book.html` together (put your Supabase URL + anon key in each).
- More → Modules → turn on **Restaurant, orders & bookings**. Open a shift if your role uses shifts.
- Logins: **Owner/Manager**, **Cashier** (waiter), **Kitchen** (role "Kitchen"), **Rider** (role "Driver") — invite them in More → Team & access.

## 1. Setup (Owner → Orders → ⚙)
- [ ] Ordering & booking options: web pages address `https://…`, service charge 10% (dine-in only), QR ordering on, auto-send off → Save
- [ ] Opening hours: Monday 10:00–22:00 → "Copy Mon to all"
- [ ] Areas & tables: area "Indoor", tables T1 (4), T2 (2), T3 (6) → print QR codes (PDF shows one card per table)
- [ ] Kitchen stations: add "Bar"; Menu: Nasi Lemak → Kitchen, Teh Tarik → Bar
- [ ] Options: "Spice level" (at least 1, up to 1: Mild, Hot) and "Add-ons" (up to 2: Egg +2, Rendang +6) → Choose items → Nasi Lemak
- [ ] Delivery areas: "Bangsar", postcodes 59000, 59100, fee 5, minimum 20

## 2. Dine-in (Cashier)
- [ ] Floor → tap T1 → 3 guests → order #001 opens
- [ ] + Items → Nasi Lemak → "Choose Spice level" until Hot is picked; 3 add-ons is refused; Hot + Egg, qty 2, note "no cucumber"
- [ ] Send 2 → items show "sent"; T1 is blue with total
- [ ] Removing an unsent item works; voiding a sent item asks for a manager
- [ ] ⋮ Move table → T3; Print bill → shows service charge and tax

## 3. Kitchen display (Kitchen login, or tablet)
- [ ] Kitchen tab: ticket "#001 · T T3" with options in red; filter Kitchen / Bar shows only that station's items
- [ ] Tap item → 🔥 preparing → ✔ ready; "All ready"; tickets older than 15 min turn red; refreshes every 10 s
- [ ] Floor shows T3 green "2 ready"; waiter taps item → Served

## 4. Pay (Cashier)
- [ ] Pay → total = items + 10% service charge + tax → cash 100 → change shown → receipt prints; table becomes free
- [ ] Sales history shows the receipt; Teh Tarik stock went down; Reports include the sale

## 5. QR at the table (customer's phone)
- [ ] Scan T2's QR → menu with categories; sold-out item shows "Sold out"
- [ ] Add Nasi Lemak without a spice level → asked to choose; add with Hot; View order → Place order → tracking page "Waiting for the shop to accept"
- [ ] Staff: T2 turns amber; open → "New order waiting" → Accept → goes to kitchen; tracking page updates within 20 s
- [ ] Order more from the same QR → added to the same table order
- [ ] Settings: auto-send on → QR orders go straight to the kitchen
- [ ] Menu → mark Teh Tarik sold out → customers can't order it

## 6. Online pickup & delivery
- [ ] Settings: online ordering + delivery on; copy the online ordering link
- [ ] Without phone → refused; postcode 50000 → "we don't deliver"; below RM20 → minimum order message
- [ ] Delivery order (59100, full address) → "#00x" tracking page; customer gets accepted/ready/on-the-way messages (if messaging is set up)
- [ ] Orders → New (1) → Accept → Kitchen marks ready → order shows "Ready"
- [ ] ⋮ Assign rider → only Driver-role staff are listed
- [ ] Rider login → Deliveries tab → "Picked up — on my way" → "Delivered"; tracking page shows each step
- [ ] Cashier → Pay → includes delivery fee line → order completed
- [ ] When closed (outside hours) the customer must choose a later time

## 7. App / marketplace orders
- [ ] Orders → + Order → App → GrabFood, their order number → add items → Send → Pay (method of the platform)

## 8. Bookings
- [ ] Services: "Haircut" 45 min + 15 min clean-up, RM35; Staff "Aina" offers Haircut
- [ ] Bookings → + Booking → Service → today/tomorrow → free times → pick 10:00 → name/phone → Book (customer gets confirmation)
- [ ] The same time can't be booked twice for Aina (another service person or time is offered)
- [ ] Table booking for 5 → smallest table that fits (T3) is chosen automatically
- [ ] Settings → bookings on → open the booking link: choose Haircut → date → times → book → confirmation page with "Cancel this booking"
- [ ] Customer cancels online (more than 2 h before) → shows Cancelled in the app
- [ ] Table booking → "Seat now" opens that table's order; Service booking → Arrived → Check out & pay → receipt
- [ ] No-show / Cancel work; "Send reminders for the next 24 hours" queues messages

## 9. Shopify / WooCommerce (test store)
- [ ] Deploy `shop-sync`; Settings → Online shop sync → Connect Shopify (shop.myshopify.com + Admin API token) or WooCommerce (https + keys)
- [ ] Sync now → "x linked" for products with the same SKU
- [ ] Place an order in the shop → after sync it appears in Orders as New, marked "paid", from Shopify #1001
- [ ] An item whose SKU isn't in your catalog blocks checkout with a clear message
- [ ] Shop stock = your stock at the chosen outlet minus open orders; changes in the app reach the shop within 5 minutes
- [ ] Complete the order → recorded as paid online; stock drops in both places

## Known limits in this batch
- Online card/FPX/e-wallet payment for web orders isn't built in yet (pay on pickup/delivery or at the counter).
- GrabFood/foodpanda/ShopeeFood need partner API access for automatic orders — enter them as "App" orders for now.
- No split bills yet (pay one total per order); no kitchen printer — use the kitchen display on a tablet.
- Live updates refresh every 10–20 seconds (not instant push).
- Shopify customer name/email may be hidden unless your Shopify app is approved for protected customer data.
