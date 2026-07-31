# EcoPoint360 — Sprint 1

MERN implementation of the SRS, following the MVC separation described in §5.1.
This build delivers the first three features:

Every path below is prefixed with `server/` (backend: Express + Mongoose) or
`client/` (frontend: React), so you can tell at a glance which half of the app a
file belongs to. The quick rule: `pages/`, `components/`, `context/` and `hooks/`
are always frontend; `models/`, `controllers/`, `routes/`, `middleware/`,
`config/` and `utils/` are always backend. Both halves have a `services/` folder —
`client/src/services/` holds only the API client, everything else is `server/`.

| ID | Feature | Where it lives |
| --- | --- | --- |
| **F1.1** | Account creation and profile management | `server/src/models/User.js` · `server/src/services/accountService.js` · `server/src/controllers/authController.js` · `server/src/controllers/userController.js` · `client/src/pages/Register.jsx` · `client/src/pages/Profile.jsx` |
| **F1.2** | Seller role application | `server/src/models/SellerApplication.js` · `server/src/services/sellerApplicationService.js` · `server/src/controllers/sellerApplicationController.js` · `client/src/pages/SellerApplication.jsx` |
| **F1.3** | Seller application review | `server/src/services/applicationReviewService.js` · `server/src/controllers/adminApplicationController.js` · `client/src/pages/admin/ApplicationQueue.jsx` |
| **F2.1** | Bin registration and QR generation | `server/src/models/Bin.js` · `server/src/services/binService.js` · `server/src/utils/qr/` · `server/src/controllers/adminBinController.js` · `client/src/pages/admin/BinRegistry.jsx` |
| **F2.2** | QR scan | `server/src/services/scanService.js` · `server/src/controllers/scanController.js` · `client/src/pages/ScanStart.jsx` · `client/src/pages/ScanBin.jsx` |
| **F2.3** | Geolocation capture | `server/src/models/ScanSession.js` · `server/src/utils/geo.js` · `client/src/hooks/useGeolocation.js` |
| **F3.1** | Product management | `server/src/models/Product.js` · `server/src/services/productService.js` · `server/src/controllers/productController.js` · `client/src/pages/SellerProducts.jsx` · `client/src/components/ProductForm.jsx` |
| **F3.2** | Categories and tagging | `server/src/models/Product.js` (fixed categories, tag rules) · `server/src/services/productService.js` (`normaliseTags`) · `client/src/components/TagInput.jsx` |
| **F3.3** | Browse, search and filter | `server/src/services/productService.js` (`browseCatalogue`, `catalogueFacets`) · `server/src/controllers/catalogueController.js` · `client/src/pages/Marketplace.jsx` |
| **F4.1** | Unified wallet | `server/src/models/Wallet.js` · `server/src/models/PointTransaction.js` · `server/src/services/walletService.js` · `server/src/controllers/walletController.js` · `client/src/pages/Wallet.jsx` |
| **F8.2** | User management | `server/src/services/adminUserService.js` · `server/src/controllers/adminUserController.js` · `client/src/pages/admin/UserDirectory.jsx` |

Login and registration are not counted as features under the project outline, but
registration is where the wallet is opened, so F1.1 and F4.1 are delivered together.

## Running it

```bash
# backend
cd server
cp .env.example .env          # set MONGO_URI and a long random JWT_SECRET
npm install
npm run dev                   # http://localhost:5000

# frontend, in a second terminal
cd client
cp .env.example .env
npm install
npm run dev                   # http://localhost:5173
```

`GET http://localhost:5000/api/health` should return `{"success":true,"data":{"status":"up"}}`.

### Creating the first administrator

There is no route that grants the admin role. The only way in is a script run by
someone with database access, so the privilege cannot be reached from the web at all.

```bash
cd server
npm run seed:admin -- admin@ecopoint360.bd "a-strong-passphrase" "Ops Admin"
```

Sign in with that account and the Applications and Accounts screens appear in the nav.

## MVC mapping

| Layer | Contents |
| --- | --- |
| **Model** | `server/src/models/` — Mongoose schemas, validation rules, `toPublic()` serialisers. No HTTP awareness. |
| **Controller** | `server/src/controllers/` — reads the request, calls a service, returns a response. `server/src/services/` holds the business rules the controllers orchestrate. |
| **View** | `client/src/` — React. Every call to the backend goes through `services/api.js`; no component holds database access. |
| **Routing** | `server/src/routes/` — binds URLs to controller functions and nothing else. |

## API

All responses use one envelope: `{ success, data }` or `{ success, error: { message, details } }`.
Protected routes need `Authorization: Bearer <token>`.

| Method | Path | Purpose |
| --- | --- | --- |
| POST | `/api/auth/register` | Create account **and** wallet (F1.1, F4.1) |
| POST | `/api/auth/login` | Sign in |
| GET | `/api/auth/me` | Current account, role read live from the database |
| GET | `/api/users/me` | View profile (F1.1) |
| PATCH | `/api/users/me` | Edit name, phone, address, bio (F1.1) |
| PATCH | `/api/users/me/password` | Change password |
| DELETE | `/api/users/me` | Delete account and its wallet |
| POST | `/api/seller-applications` | Submit seller application (F1.2) |
| GET | `/api/seller-applications/mine` | Own application history |
| GET | `/api/seller-applications/mine/status` | Latest application, drives the profile status card |
| DELETE | `/api/seller-applications/:id` | Withdraw a pending application |
| GET | `/api/wallet/me` | Balance and lifetime totals (F4.1) |
| GET | `/api/wallet/me/transactions` | Source-tagged ledger, paginated |
| GET | `/api/wallet/me/integrity` | Rebuilds the balance from the ledger (NFR-4) |
| GET | `/api/admin/stats` | Account and queue counters |
| GET | `/api/admin/seller-applications` | Review queue, filter by status (F1.3) |
| PATCH | `/api/admin/seller-applications/:id/approve` | Approve and promote to seller (F1.3) |
| PATCH | `/api/admin/seller-applications/:id/reject` | Reject with a required reason (F1.3) |
| GET | `/api/admin/users` | Account directory, search and filters (F8.2) |
| GET | `/api/admin/users/:id` | One account with wallet and application history |
| PATCH | `/api/admin/users/:id/suspend` | Suspend with a required reason (F8.2) |
| PATCH | `/api/admin/users/:id/reinstate` | Reinstate a suspended account (F8.2) |
| POST | `/api/admin/bins` | Register a bin, returns its printable code (F2.1) |
| GET | `/api/admin/bins` | Bin registry, search and status filter (F2.1) |
| PATCH | `/api/admin/bins/:id` | Edit or take a bin out of service (F2.1) |
| GET | `/api/admin/bins/:id/qr` | Regenerate the printable SVG (F2.1) |
| GET | `/api/bins/by-code/:code` | Resolve a scanned or typed code (F2.2) |
| POST | `/api/scans` | Record a scan with the position captured (F2.2, F2.3) |
| GET | `/api/scans/mine` | Recent scans for the signed-in user |
| POST | `/api/products` | Create a listing, seller-only (F3.1) |
| GET | `/api/products` | The seller's own listings (F3.1) |
| PATCH | `/api/products/:id` | Edit own listing (F3.1) |
| DELETE | `/api/products/:id` | Delete own listing (F3.1) |
| GET | `/api/catalogue` | Browse with keyword, category, tag, sort (F3.3) |
| GET | `/api/catalogue/facets` | Categories and in-use tags with counts (F3.3) |
| GET | `/api/catalogue/:id` | One public product |

`/api/products` sits behind `requireRole('seller')`; `/api/catalogue` behind
`requireAuth`. A buyer can browse the catalogue but has no listings to manage,
and one seller can neither see nor edit another's products — the service scopes
every management query by `seller` and returns 404, never 403, on a mismatch.

Everything under `/api/admin` sits behind `requireAuth` + `requireRole('admin')`,
applied once at the top of the router so a new admin route cannot be added without it.

### Quick check with curl

```bash
curl -X POST localhost:5000/api/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"name":"Arnish","email":"arnish@example.com","password":"password123"}'

curl localhost:5000/api/wallet/me -H "Authorization: Bearer <token from above>"
```

## The QR encoder

`server/src/utils/qr/` encodes QR symbols from scratch — Galois field arithmetic,
Reed–Solomon error correction, module placement, mask selection and format
information. It is roughly 500 lines and has no dependencies.

It is hand-written because "QR generation" is half of F2.1, and the project rules
forbid a package that implements a major feature. Byte mode, versions 1 to 9 and
all four error correction levels are supported, which is far more than a bin URL
needs. Bin stickers are generated at level Q, about 25% recoverable, because they
live outdoors and get rained on and scuffed.

```bash
cd server && npm run test:qr
```

The test reads a finished symbol back out of the module matrix — undoing the
mask, walking the zigzag, de-interleaving the blocks — then checks that every
Reed–Solomon syndrome is zero and that the payload decodes to the original
string. 478 symbols across every supported version and level pass.

During development the encoder was additionally checked against two independent
implementations: matrices were compared module-for-module against the `qrcode`
package, and every symbol was decoded with `jsqr`. Both were used at the terminal
only and are not dependencies of this project. Two real bugs surfaced that way and
are worth knowing about, because both produce a symbol that looks perfectly normal:

- The format information strips run **down the column first, then along row 8**.
  Transposing them corrupts 8 modules and no scanner will read the result.
- The version information block is required from **version 7**, not version 10.
  Version 10 is where the byte-mode character count grows to 16 bits — a
  different rule that is easy to conflate with this one.

## Categories are closed; tags are open

F3.2 pairs a fixed category with free-form tags, and the split is deliberate.
Category is an `enum` on the model: a buyer filtering by category (F3.3) needs
the values finite and shared, or "Handmade", "handmade" and "hand-made" would
never group. Tags are the open half — but `normaliseTags` lowercases, trims,
turns spaces to hyphens, strips punctuation and de-duplicates before anything
is stored, so a seller typing "Recycled Material" and one typing
"recycled-material" both land on the single tag a buyer can filter on. That
normalisation is unit-tested (`npm run test:products`, 10 cases) because it is
the one piece of pure logic here and the one most likely to drift.

## Decisions worth defending at viva

1. **The wallet is created inside registration, not lazily on first use.** A user
   without a wallet would break the unified points economy. If the wallet write
   fails, the user document is deleted and the request fails, so the two documents
   are never out of step. On a replica set this can become a session transaction;
   the compensating delete gives the same guarantee on a standalone `mongod`.
2. **The balance is cached but the ledger is authoritative.** `walletService`
   is the only code that writes a balance, and every write also appends a
   `PointTransaction` with its `source`. `/wallet/me/integrity` recomputes the
   balance by aggregating the ledger and reports any drift — the concrete form of NFR-4.
3. **Role is an attribute on `User`, not a separate collection.** A buyer promoted
   to seller keeps the same `_id`, wallet and history. `SellerApplication` is a
   separate entity so that rejected applications, their reasons and their reviewers
   survive for audit, and so F1.3 has a queue to read.
4. **The application never changes the applicant's role.** Promotion happens only
   in the administrator review path (F1.3, Sprint 1), keeping the elevation
   decision in one place.
5. **Role is read from the database on every request, not from the JWT.** A promotion
   or a suspension takes effect on the next request rather than the next login.
6. **A partial unique index enforces "one pending application per user"** at the
   database level, so two concurrent submissions cannot both succeed, while still
   allowing a rejected applicant to apply again.
7. **Login returns the same message for an unknown email and a wrong password**, so
   the endpoint cannot be used to enumerate registered addresses.
8. **Approval is a guarded write, not a read-then-write.** Both the application
   status and the role change use `findOneAndUpdate` filtered on the expected
   current value (`status: 'pending'`, `role: 'buyer'`). Two administrators
   clicking approve at the same moment cannot both succeed. If the role write
   fails after the decision was recorded, the decision is rolled back, so an
   approved application can never sit against an account that was not promoted.
9. **Rejection and suspension both require a written reason.** The reason is
   stored on the record and shown to the person affected — on the profile card
   for a rejected application, in the sign-in error for a suspended account.
   A decision nobody can explain is not a decision the platform should support.
10. **Suspension is reversible and non-destructive.** Nothing is deleted; the
   wallet and its ledger are untouched, and the account resumes where it stopped.
   Because `requireAuth` reads the live account rather than trusting the token,
   a suspension takes effect on the very next request instead of at token expiry.
11. **Administrators cannot suspend themselves or each other** from this screen,
   which removes the obvious way to lock the whole platform out of its own admin tools.
12. **The admin UI guard is convenience, not security.** `AdminRoute` hides screens
   a buyer has no use for; `requireRole('admin')` on the server is what actually
   protects the data, since anything in the browser can be bypassed.
13. **A printed QR code proves nothing on its own, and the design says so.**
   The sticker encodes only a URL containing the bin's public code. It is on a
   public object, so anyone can photograph and reprint it. Possession of the code
   establishes *which* bin, never that the person was standing at it. That is the
   entire reason F2.3 captures a position, F2.6 checks it against a radius, F2.4
   requires a photograph and F2.9 leaves the decision with a human. Adding a
   signature to the QR would not help: whatever is printed on the sticker is
   equally copyable.
14. **Bin codes are random, not sequential.** `BIN-000001` upwards would let
   anyone enumerate every bin in the city. Codes are drawn from a Crockford-style
   alphabet with I, L, O and U removed, so a code read off a weathered sticker
   and typed by hand is unambiguous.
15. **`maximumAge: 0` on the geolocation request.** The default lets the browser
   return a position it cached earlier, possibly from somewhere else entirely —
   precisely the reading this feature must not accept. A fresh fix is slower and
   occasionally fails, and that is the right trade.
16. **The server timestamps the scan; the device's clock is only evidence.**
   `capturedAt` is the server's own time and is what anything downstream relies
   on. `deviceReportedAt` is stored beside it purely so the two can be compared,
   and a large gap is flagged for the reviewer. A client timestamp is a claim.
17. **A weak reading is recorded, not rejected.** A poor accuracy figure or a
   skewed clock adds a `qualityFlag` and nothing more. Discarding the reading
   would leave an administrator with nothing to look at in F2.8 when the
   submission is questioned. The scan records; F2.6 and F2.9 judge.
18. **Distance is computed once and frozen on the record.** Deriving it on demand
   would mean that moving a bin later silently rewrote the history of every scan
   taken against its old position.
19. **GeoJSON stores `[longitude, latitude]`, the reverse of every phone API.**
   The swap happens in exactly two helpers in `utils/geo.js` so it cannot be got
   wrong in three different places.
20. **The QR image is fetched as data, not loaded from an image URL.** An `<img>`
   tag cannot carry an Authorization header, so an image route would need the
   token in the query string, where it lands in browser history and server logs.
21. **Products are priced in whole points, the platform's own unit (F4.1).**
   An integer count of points has no rounding error, which a fractional major
   currency unit would. The marketplace and the wallet speak the same language,
   so checkout in Sprint 3 needs no currency conversion.
22. **Ownership is enforced by scoping every query, and a mismatch is a 404.**
   `productService` loads a product by id *and* seller together; a seller who
   asks for another's product is told it does not exist rather than that it
   exists but is forbidden, which is information they have no need for.
23. **The catalogue shows only what a buyer can act on.** `browseCatalogue`
   returns active, in-stock products by default; a seller's hidden or
   out-of-stock listings never leak into it. `includeOutOfStock` is an explicit
   opt-in, not the default.
24. **Keyword search uses a weighted text index, not a regex scan.** Title is
   weighted above tags above description, and results are ranked by relevance
   before the chosen sort, so a match in the name beats a passing mention in the
   body. It also scales, where a regex over every document would not.
25. **Multiple tag filters combine with AND (`$all`), not OR.** Adding a second
   tag narrows the results, which is what a shopper expects a filter to do.
26. **The tag filter facet is built from the live catalogue, with counts.** The
   browse UI offers the tags actually in use rather than a guessed list, so a
   buyer never picks a filter that returns nothing.
27. **Deletion is a hard delete only while nothing references a product.** The
   service comment marks where this becomes a soft archive in Sprint 3, once an
   order points at a product and losing the row would orphan an order line.
28. **Validation is hand-written** (`middleware/validate.js`) rather than delegated
   to a schema package, which keeps input rules inside the team's own code as the
   course constraint on third-party features requires.

## Scanning, end to end

The printed code holds a plain URL, `PUBLIC_APP_URL/scan/BIN-XXXXXX`. That means
the phone's own camera app opens it — no decoder is needed on our side at all,
which is both the simplest path and the one that avoids importing a decoding
library. `/scan` additionally offers an in-page scanner using the browser's
native `BarcodeDetector` where it exists (Chrome and Android; Safari and Firefox
fall back to the camera app), and a typed-code box for a sticker too scuffed to read.

`PUBLIC_APP_URL` must be reachable from a phone. On a laptop demo it is
`http://localhost:5173`; a phone on the same network cannot open that, and
geolocation is blocked outside HTTPS and localhost anyway. Demo the scan flow in
a desktop browser, or tunnel the dev server over HTTPS.

## Sprint 1 is complete

The full buyer-to-seller path now works end to end: a user registers (F1.1), a wallet
opens with the account (F4.1), they apply to sell (F1.2), an administrator approves or
rejects with a reason (F1.3), and any account can be suspended or reinstated (F8.2).
F2.1 (bin registration and QR generation) is the remaining Sprint 1 item.

The ledger UI is deliberately empty until Sprint 2 credits the first verified disposal.
`walletService.credit()` and `debit()` are the entry points those features will call;
`adminUserService.getUserStats()` is the seed of the F8.1 dashboard.

## Testing the review path by hand

1. Register two accounts, `buyer@test.com` and `maker@test.com`.
2. As `maker@test.com`, submit a seller application from **Sell with us**.
3. Seed an admin, sign in, open **Applications** — the application is waiting.
4. Approve it. Sign back in as `maker@test.com`: the role chip now reads `seller`.
5. As the admin, open **Accounts**, suspend `buyer@test.com` with a reason, and try
   to sign in as them — the reason comes back in the error.
6. Reinstate, and sign-in works again with the wallet balance unchanged.

## Testing the marketplace by hand

There is a seed for this so you are not entering a catalogue by hand:

```bash
cd server && npm run seed:marketplace
```

It creates a demo seller (`demo-seller@ecopoint360.bd` / `password123`) with
eight products across six categories, one of them out of stock.

1. Sign in as any user and open **Marketplace**. Eight products, minus the
   out-of-stock one, so seven are shown.
2. Type "jute" in search — the tote and the gamcha surface.
3. Pick the **Home and kitchen** category — the jug and the beeswax wraps.
4. Click the **plastic-free** tag, then **handmade**: the results narrow to
   products carrying *both*, not either.
5. Sign in as the demo seller and open **My products**. Edit one, hide another,
   and watch the marketplace reflect it. A hidden product leaves the catalogue;
   the out-of-stock one is listed for the seller but not shown to buyers.

## Testing the scan path by hand

1. As the admin, open **Bins**, and register one with **Use this device's
   location** so the coordinates are genuinely yours.
2. The print sheet opens with the generated code. Leave it on screen.
3. In another browser profile, sign in as a resident and open **Scan a bin**.
   Type the code, or point a phone camera at the sheet on your monitor.
4. Press **Record my location**. The captured coordinates, the accuracy of the
   reading and the distance from the bin are shown back.
5. Register a second bin with coordinates a few hundred metres away and scan it:
   the distance is recorded and *not* rejected. Enforcing the radius is F2.6.
