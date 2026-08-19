# Integration notes — Milestone 3, marketplace, spend path and dashboard

Covers F4.1–F4.8, F5.1 and F5.4. Per §9 of the brief: files added or changed,
wiring required, import assumptions, the surface exposed, and what went wrong
while building it. Written to be defensible under questioning.

F5.2 (suspension and reinstatement) was already delivered alongside F5.3 in M2;
what M3 adds to it is the catalogue sweep described below.

---

## What M3 has to prove

The exit criterion is one continuous run:

> dispose → approved → balance up → spend at checkout → confirm receipt →
> balance up again, with four distinct `source` values visible in the ledger

The four sources are `disposal`, `claim`, `redemption` and `purchase`. M2
delivered the first two. M3 delivers the second two, and they are what turn the
points economy from a pipeline into a cycle: the spend loop *terminates by
crediting*.

---

## Files

**Added — Flutter (23)**

| File | Purpose |
|---|---|
| `lib/core/product_taxonomy.dart` | Closed category vocabulary, tag normalisation, `searchTokens[]` builder, query tokeniser |
| `lib/core/checkout_math.dart` | Cart lines, seller grouping, largest-remainder discount allocation, the buyer's quote |
| `lib/models/product_model.dart` | Listing, with derived index fields and the rules' bounds mirrored |
| `lib/models/cart_model.dart` | Cart and its pure mutations |
| `lib/models/order_model.dart` | Order, line snapshots, and the status machine |
| `lib/models/appeal_model.dart` | Appeal, subject vocabulary, text bounds |
| `lib/models/stats_model.dart` | Dashboard counters and the figures derived from them |
| `lib/services/product_service.dart` | Catalogue queries, seller writes, the admin sweep call |
| `lib/services/cart_service.dart` | Cart document read/write |
| `lib/services/order_service.dart` | Order streams; checkout, advance and confirm over HTTP |
| `lib/services/appeal_service.dart` | Appeal create, streams, admin resolve |
| `lib/services/stats_service.dart` | `stats/platform` stream |
| `lib/controllers/catalog_controller.dart` | Filter state and the catalogue stream |
| `lib/controllers/cart_controller.dart` | Cart, resolved lines, unavailable items, the quote |
| `lib/controllers/orders_controller.dart` | Buyer and seller order lists, checkout and fulfilment actions |
| `lib/controllers/seller_products_controller.dart` | Seller's own listings, create/edit/delist, photo upload |
| `lib/controllers/appeals_controller.dart` | User appeals, admin queue, raise and resolve |
| `lib/controllers/dashboard_controller.dart` | Platform counters and live account totals |
| `lib/views/market/{catalog,product_detail,cart,checkout}_view.dart`, `product_card.dart` | Buyer path |
| `lib/views/orders/{buyer_orders_view,order_card}.dart` | Buyer's orders and the shared card |
| `lib/views/seller/{seller_products,product_edit,seller_orders}_view.dart` | Seller console |
| `lib/views/appeals/{appeals_view,appeal_form_view,appeal_button}.dart` | Appeals, both sides |
| `lib/views/admin/{admin_dashboard,admin_appeals}_view.dart` | F5.1 and the F5.4 queue |

**Added — server and tests (7)**

| File | Purpose |
|---|---|
| `server/src/checkout.js` | The checkout transaction, plus the pure allocation and cart-parsing helpers |
| `server/src/orders.js` | Status machine, seller advancement, buyer confirmation and the purchase award |
| `server/src/listings.js` | Hide/restore a suspended seller's catalogue |
| `server/scripts/seed.js` | Demonstration data with an accumulated ledger |
| `server/test/checkout.test.js` | 35 pure unit tests over the arithmetic and the machine |
| `rules_test/market.rules.test.js` | 69 rules tests over products, carts, orders, appeals and stats |
| `test/core/{product_taxonomy,checkout_math,label_format_taka}_test.dart`, `test/models/{product,cart,order,appeal,stats}_model_test.dart` | Dart unit tests |

**Changed (14)**

| File | Change |
|---|---|
| `firestore.rules` | Five new collection blocks and four helpers. Nothing existing modified |
| `firestore.indexes.json` | Nine composite indexes |
| `server/src/index.js` | Five routes; `requireSeller` import; version `0.4.0` |
| `server/src/auth.js` | `requireSeller` middleware |
| `server/src/cloudinary.js` | `products` added to `PHOTO_KINDS` |
| `server/src/pointsPolicy.js` | `pointsToSpendForTaka`, `maxRedeemablePoints`, `applyRedemption` |
| `server/test/cloudinary.test.js` | Folder list assertion updated; new cross-folder test |
| `lib/core/label_format.dart` | `formatTaka`, `orderCount` |
| `lib/services/photo_upload_service.dart` | `uploadProductPhoto` |
| `lib/controllers/admin_users_controller.dart` | Suspension now sweeps the catalogue and reports both halves |
| `lib/views/admin/admin_users_view.dart` | Reports the sweep, including partial failure |
| `lib/routing/router.dart` | 13 routes and a `requireSeller` guard |
| `lib/views/shared/app_shell.dart` | Shop destination with a cart badge |
| `lib/views/home/home_view.dart` | Orders, appeals, seller console and dashboard cards |
| `lib/views/history/submission_history_view.dart`, `lib/views/claims/claim_submit_view.dart` | Appeal button on a rejection |

No new package dependencies on either side. `image_picker`, `cached_network_image`
and `http` were already present.

---

## The decisions worth defending

### 1. `products` is a client write and means it; `orders` is not

This is the same test applied everywhere in `firestore.rules`: **is the governing
constraint expressible where it is enforced?**

For a price, it is. "The owning seller, in good standing, holding the seller role,
within these bounds, on their own document" is a sentence rules can state — so a
listing is written by the seller's client and the rules validate it against an
exact key set.

For an order, it is not. `confirmed` is the transition that credits a wallet
(F4.7), and its governing condition is "this is the buyer, the seller has already
marked it delivered, and it has not already been confirmed" — the last clause
being an idempotence property that has to hold *inside the transaction that
credits*. So every order transition goes to the server, and `orders` is denied to
every client, administrators included, exactly as `disposals` is.

The tempting middle position — let rules handle `shipped` and `delivered`, and
the server handle `confirmed` — was rejected deliberately. It would state one
invariant in two places with different reasoning behind each, and the seam would
fall exactly where the money is.

**Nothing about a client-written product weakens the payout boundary.** The one
number here that reaches the ledger is `price`, and the server reads it from the
stored document inside the checkout transaction, never from the buyer's request.

### 2. Checkout is one transaction, and that is not a performance decision

It touches four kinds of document: it decrements stock, debits a wallet, writes a
ledger entry, creates one order per seller, and deletes the cart. Any partial
commit is a specific failure:

- stock decremented without an order → inventory destroyed
- an order without a debit → goods given away
- a debit without a ledger entry → NFR-4 broken, balance no longer reconstructable

It also resolves the stock race (§7.4) for free: the decrement lives inside the
same transaction as the order write, so two buyers going for the last unit produce
one success and one clean failure — never two orders and a negative count.

**Checkout is deliberately not idempotent.** It consumes the cart, so a retry
finds an empty one and fails with "Your cart is empty". That is the safe direction:
a duplicate checkout would decrement stock twice and debit points twice. Compare
`confirmOrder`, which *is* idempotent through its status check, because there the
retry-safe outcome is a refusal rather than a double payout.

### 3. The discount is allocated by largest remainder, in two places

A cart may hold several sellers, but an order carries one `sellerId` (§7.4), so a
checkout-wide discount has to be split across orders. Naive flooring loses money:
three ৳100 orders sharing a ৳50 discount floor to 16 + 16 + 16 and drop ৳2 — two
taka the buyer spent points on and did not receive.

`allocateDiscount` therefore distributes leftovers to the largest fractional
remainders, so the parts always sum to the whole. Remainders are compared as
scaled integers rather than floats, because a floating-point tie can break
differently between two runtimes — and this function exists **twice**, in
`lib/core/checkout_math.dart` and `server/src/checkout.js`.

Two copies because the buyer must see a total before committing and the button
must not be what decides it. `test/core/checkout_math_test.dart` and
`server/test/checkout.test.js` assert the same worked examples — including
`allocateDiscount([333, 667], 49) == [16, 33]` — so a drift between the copies
fails a test rather than being discovered by a buyer.

### 4. The cart's element shape is enforced where it is read, not in the rules

Rules cannot iterate a list. They pin the cart's owner, its top-level key set and
its item count, and stop there.

That is safe only because of §6.2's invariant: **the cart stores no prices.** It is
the user's own scratchpad and carries no value. `readCartItems` in
`server/src/checkout.js` is the other half of the bargain — it resolves every
`productId` against a live listing and refuses anything malformed. A cart with a
cached price in it cannot buy anything at that price; the price is simply ignored,
and `server/test/checkout.test.js` asserts exactly that.

It refuses rather than silently skipping a bad line, because dropping a line the
buyer believes they are buying is worse than telling them the cart is broken.

### 5. Product images are validated by index, and that is why there are three

`validProductImages` in `firestore.rules` checks `imageUrls[0]`, `[1]` and `[2]`
explicitly, each against the same provenance pattern a disposal photograph uses:
the URL must name **this seller's own folder** on the configured host.

The three-image ceiling exists so that each slot can be named. An unbounded list
would mean unvalidated entries, and an unvalidated entry is an arbitrary URL that
every buyer's browser then fetches. `market.rules.test.js` includes a test that
puts the bad image in the *last* slot, which is the test that fails if a slot is
ever forgotten.

### 6. `shopName` is self-declared, and the interface says so

`users` is readable only by its owner and by an administrator (§6.3), so a buyer
cannot resolve a seller's real name. Widening that read to serve a vendor label
would expose every account's email to every signed-in user — a far worse trade
than a catalogue without one.

So a listing carries `shopName`, the seller writes it, rules bound its length and
nothing verifies it. The interface renders it as "Shop: …" rather than as an
identity claim. **An order is different**: `buyerName` and `sellerName` are
resolved by the server from `users` at checkout, because there the counterparty's
identity actually matters and neither party is entitled to invent it.

*Stated limitation:* nothing stops a seller naming their shop after somebody
else's. The mitigation is moderation — an administrator can suspend the account,
which now also hides the catalogue.

### 7. Suspending a seller sweeps their catalogue, and it is two operations

§7.4 requires that suspension hide products without deleting them. The suspension
itself is a client write, because rules can express who may set it. The sweep
cannot be: `products` is writable only by its owning seller, and inventing an
"admin may edit any listing" rule would be a much larger privilege than the job
needs. The Admin SDK bypasses rules, so `POST /sellers/:uid/listings` runs the
sweep and the ownership rule stays as narrow as it is.

`hiddenBySuspension` marks the listings the sweep hid, so reinstatement restores
only those — a seller may have taken products down themselves, and republishing
those is not the administrator's decision to make. Rules keep the flag out of
every seller-writable key set.

**The pair cannot be atomic** — one is a Firestore write from the client, the
other an HTTP call — so `SuspensionOutcome` carries both results and the admin
screen says "Suspended. Their listings are STILL VISIBLE — …" when the second half
fails. A partial failure that reads as a success is worse than the failure.

### 8. An appeal moves no points, which is why it lives in the rules

`appeals` is shaped exactly like `sellerApplications`: create your own pending
document, an administrator flips it once and writes an answer. That is only
possible because resolving one credits nothing.

Keeping payouts out of this collection is a deliberate design decision, not an
omission. A rejection already releases the bin lockout (§7.4), so the remedy for
a wrong rejection is a fresh submission that goes through the whole verification
pipeline — not a hand-credited award that skips it. Both screens say so in those
words, because a user who thinks they are requesting their 50 points will be
disappointed by an upheld appeal.

The rules go further than the client does: creation is refused unless the named
disposal or claim **exists, belongs to the caller, and was actually rejected**.
Without that clause, `appeals` would be an unmoderated text collection any signed-in
account could write into against any id at all.

### 9. The dashboard mixes counters and counts, and labels which is which

Platform figures (`pointsIssued`, `ordersConfirmed`, …) are incremented with
`FieldValue.increment()` inside the same server transactions that cause them
(§6.3), so the screen costs one document read however much data accumulates. They
are a record of what the server did, not a recount.

Account totals are counted live from `users`. §6.3's argument does not apply to
them: registration is a client write that cannot touch `stats` — nothing can — so
a counter would need a server hook on a path that deliberately has none, and the
admin account list already streams that collection.

The screen states both provenances. The obvious viva question is "so is that a
count or a counter?", and a dashboard that cannot answer it is one nobody should
trust.

The figure worth pointing at during the demonstration is **points outstanding** —
issued minus redeemed, the standing liability of the economy.

---

## The surface exposed

**Server (all under the existing auth middleware)**

| Route | Role | Returns |
|---|---|---|
| `POST /photos/product` | seller | `{photoUrl, publicId, bytes}` |
| `POST /checkout` | auth | `{checkoutId, orders[], subtotal, pointsApplied, discount, payable, balanceAfter}` |
| `POST /orders/:id/status` | seller | `{orderId, status, paymentStatus}` |
| `POST /orders/:id/confirm` | auth (buyer) | `{orderId, status, pointsAwarded, balanceAfter}` |
| `POST /sellers/:uid/listings` | admin | `{sellerId, visible, changed}` |

Failures return `409` with a message written for the person who will read it — a
buyer sees "only 2 left", an administrator sees "already decided". Those are
surfaced verbatim by the Flutter services, because a generic failure at checkout
leaves nothing to act on.

**Riverpod providers**

`catalogFilterProvider`, `catalogProvider`, `productProvider(id)`,
`cartProvider`, `cartCountProvider`, `cartLinesProvider`,
`unavailableCartItemsProvider`, `checkoutPointsProvider`, `checkoutQuoteProvider`,
`cartActionsProvider`, `buyerOrdersProvider`, `sellerOrdersProvider`,
`ordersAwaitingConfirmationProvider`, `sellerOpenOrdersProvider`,
`orderActionsProvider`, `sellerProductsProvider`, `sellerProductActionsProvider`,
`userAppealsProvider`, `appealedSubjectIdsProvider`, `pendingAppealsProvider`,
`appealActionsProvider`, `platformStatsProvider`, `accountTotalsProvider`.

`cartProvider` is deliberately **not** `autoDispose`: the shell's cart badge reads
it on every screen. Everything else is `autoDispose`.

**Routes**

`/market`, `/market/:productId`, `/cart`, `/checkout`, `/orders`,
`/seller/products`, `/seller/products/new`, `/seller/products/:productId`,
`/seller/orders`, `/appeals`, `/appeals/new?type=&id=`, `/admin/appeals`,
`/admin/dashboard`.

`requireSeller` sends a non-seller to `/apply-seller` rather than `/home` — they
reached the route because they want to sell, and the next step exists.

---

## Import assumptions

- `lib/core/*` and `lib/models/*` import no Firebase. Services convert
  `Timestamp` to `DateTime` at the boundary, as the M2 models already did.
- `product_edit_view.dart` uses `image_picker` and **not**
  `flutter_image_compress`, which has no web implementation. Resizing is done
  through `pickImage(maxWidth:, maxHeight:, imageQuality:)`, which works on both
  targets. Nothing in the marketplace touches `dart:io`, so the seller console,
  the catalogue, the cart, checkout and both dashboards run on web — which
  matters, because the seller console and the dashboard are web-primary (§5.5).
- `admin_users_controller.dart` now imports `catalog_controller.dart` for
  `productServiceProvider`. One `ProductService` instance is shared.

---

## What went wrong while building it

**1. `_SplitNotice` shadowed `orderCount`.** A widget field named `orderCount`
hid the `orderCount(int)` helper added to `label_format.dart` in the same change,
and the string interpolation that resulted compiled into nonsense before the
analyzer caught it as "the expression doesn't evaluate to a function". Renamed to
`sellerCount` — which reads better anyway, since one order per seller means the
number is both figures at once.

**2. `dart format` broke two single-line `if` statements across lines**, which
then tripped `curly_braces_in_flow_control_structures`. Worth recording because
the failure appears *after* formatting, so a clean analyze before `dart format`
proves nothing.

**3. The `PHOTO_KINDS` test asserted an exact list**, so adding `products` failed
`server/test/cloudinary.test.js`. That is the test doing its job: the folder name
is what `firestore.rules` builds its provenance pattern from, and a folder added
on the server without a matching rule would accept an upload the rules then refuse
— a photograph that uploads successfully and cannot be saved. The test now names
all three and adds a case proving a listing cannot borrow the disposal folder.

**4. `hiddenBySuspension` nearly broke every seller edit.** The field is in
`validProduct`'s `hasOnly` list but not its `hasAll` list. Leaving it out of
`hasOnly` would have been the obvious reading — it is server-owned, so why let a
client send it? — but `request.resource.data` on an update carries the *whole
resulting document*, flag included, so every edit after a suspension would have
failed with no stated reason. What stops a seller *changing* it is the affected-key
set on the update rule, not its absence from the shape. Two tests pin both halves.

---

## Verification status

| Check | Result |
|---|---|
| `flutter analyze lib test` | clean |
| `flutter test` | 425 passed |
| `npm test --prefix server` | 212 passed |
| `rules_test` against the emulator | 209 passed |
| `firebase deploy --only firestore:rules --dry-run` | compiles |
| `flutter build web --release` | succeeds, Wasm dry run clean |

**Not yet verified on real hardware or against the deployed service.** The
marketplace has been exercised by unit tests, rules tests and a compile of both
targets; no order has been placed against the live Render instance, and no release
APK has been installed. That is the honest boundary, and it is the same one M2
recorded for push and GPS.
