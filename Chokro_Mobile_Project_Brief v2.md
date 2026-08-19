# Chokro Mobile — Project Brief & Build Plan

**Course:** CSE489 — Android App Development, BRAC University
**Student:** Arnish (solo project)
**Platform:** Flutter (Android + Web, single codebase) + Node service
**Repository:** `https://github.com/alsabaharnish/chokro`
**Document version:** 2.1 — Milestones 1 and 2 complete, Milestone 3 code complete

> Formerly titled *EcoPoint360*. The product is now **Chokro**. Older drafts of
> this document circulate under the previous name; this file supersedes them.

---

## 0. How to use this document

This is a self-contained handoff brief. It is written so that a fresh
conversation can begin implementation without prior context. It contains the
course constraints, the approved scope, the architecture, the data model, the
delivery milestones, and the working conventions to follow.

**Read Sections 1–3 before proposing anything.** Sections 4–7 are the
specification, including the points policy (7.3) and integrity edge cases (7.4).
Section 8 is the milestone plan, Section 9 describes how I work, Section 10
covers the written coursework, and Section 11 covers security posture.

### What changed since v1.5

Version 1.5 was a pre-implementation baseline with three open decisions. All
three are now closed, and closing them changed the architecture more than
expected:

| v1.5 open decision | Resolution |
|---|---|
| Backend: Firebase or Node/Express? | **Both.** Firebase for data and auth, plus a small Node service for anything that decides a payout |
| Point-award mechanism: rule-constrained client writes or Cloud Functions? | **Neither.** An external Node service on Render, because Cloud Functions require a billing card |
| Points policy values | **Locked** as §7.3 defaults, and made admin-tunable at runtime |

Three further changes worth flagging because they contradict v1.5:

- **AI photo screening moved from deferred (§7.2) to core.** Disposals are now
  screened automatically and can be auto-approved. This is the largest scope
  increase in the project.
- **`minSdk` is 23, not 21.** `mobile_scanner` raised its Android floor.
- **Notifications moved from deferred to core**, as real FCM push.

---

## 1. Course context and approvals

CSE489 is an Android App Development course. Its published outline is built
around native Android in Java — Activities, Intents, Fragments, `LayoutInflater`,
Retrofit/GSON/Picasso, SQLite and Firebase. Assessment is 40% project and term
paper, with phase updates marked at roughly Weeks 10, 11 and 12, and a final
presentation in Week 13.

Two approvals have already been granted by the course instructor and are **not
open questions**:

1. **Flutter is approved** as the implementation technology in place of native
   Android/Java.
2. **Reusing the product concept is approved**, with the understanding that this
   is an independent solo build.

Do not re-litigate either point. If a suggestion depends on native Android APIs
or Java, it is out of scope.

## 2. Relationship to the CSE470 project

A separate, team-based web implementation of the same product concept exists for
CSE470 (MERN stack, four developers). That project is **not** an input to this
one.

**Hard rules:**

- No code is carried over from the CSE470 repository. Not the Express server,
  not the models, not the QR encoder, not the React client. This is a new
  codebase written from scratch.
- The two projects have separate repositories and separate Firebase resources.
- Feature IDs in this document are specific to this project and do **not**
  correspond to CSE470 feature IDs. Do not cross-reference them.

Design *knowledge* carries over freely — the domain understanding, the
fraud-prevention reasoning, the decision to open a wallet atomically at
registration. Code does not.

## 3. Project overview

### 3.1 What this project is

A cross-platform mobile and web application that rewards verified sustainable
behaviour with points, and lets those points be spent with small eco-friendly
sellers. It is built as a single Flutter codebase targeting Android and the
browser, backed by a cloud datastore and a small trusted service.

### 3.2 The problem

Two sustainability problems exist alongside one another in Bangladesh and are
almost never addressed together.

**Correct waste disposal carries no positive incentive.** A resident who
separates recyclables and carries them to a proper bin receives nothing for it —
no recognition, no record, no measurable proof that they did. The behaviour is
invisible, so it is neither reinforced in the individual nor measurable in
aggregate. Municipal programmes can count tonnage collected but cannot attribute
any of it to the people whose effort produced it. Absent attribution, the only
lever available is exhortation, which is weak and unmeasurable.

**Small and informal eco-friendly sellers have no dedicated channel.** Producers
of handmade, recycled-material and low-impact goods — frequently home-based,
frequently women — sell through scattered social-media pages. They compete for
attention against mass-produced imports with far better distribution, and they
carry no portable reputation: a seller with two years of satisfied customers on
one page starts from nothing on another.

**The two problems are treated as unrelated.** Waste applications reward
disposal. Green marketplaces sell products. Neither is aware of the other, so a
person's sustainable behaviour is fragmented across platforms that do not talk to
each other, and no cumulative record of it exists anywhere.

### 3.3 The approach

Both behaviours are sustainable actions, so both credit **one wallet**.

Points earned by disposing of waste correctly can be spent on a handmade
product. That purchase supports a small seller, which is itself a sustainable
act, so it credits the same wallet again. The two halves of the system feed each
other rather than sitting side by side:

```
    dispose waste  ──►  earn points  ──►  spend on eco-seller
          ▲                                       │
          └───────────  earn points  ◄────────────┘
```

The unification is structural, not presentational. It is expressed in one wallet
document per user and one source-tagged ledger from which every balance is
reconstructable. A `source` field distinguishes disposal from purchase from
redemption, which is what permits a single balance to serve every earning route
without maintaining parallel currencies.

### 3.4 Strategy

Five decisions carry the design.

**Verification proportionate to risk.** Points are never credited on an
unverified assertion, and the award value tracks how strongly the route can be
verified. Disposal requires a photograph taken within a geofenced radius of a
registered bin, plus automated screening, plus a time-window lockout against
repeat claims — so it pays most. Purchases require two independent parties and
the buyer's confirmation of receipt before points are released. Self-reported
actions can be verified by no mechanical means at all, so they carry the weakest
safeguards available — human review, a fixed action vocabulary and a weekly quota
— and consequently the smallest award. No route awards points on a user's word
alone.

**Printed QR codes rather than smart bins.** Hardware integration is out of
scope, and a printed code performs the same identification function within the
verification workflow at effectively zero deployment cost — which also happens to
be the only realistic way such a system would actually reach bins in a
Bangladeshi neighbourhood.

**Machine assistance with a human fallback.** Automated checks screen and sort.
Where every mechanical check passes and the screen is confident, the submission
is credited automatically. Where anything is uncertain — a low confidence score,
a count that disagrees with the photograph, a duplicate-looking image, a
screening service that could not be reached — the submission is routed to an
administrator rather than paid out. **The system fails toward review, never
toward payout.**

**No client decides a payout.** Every field that determines or records an award
is written by a trusted service the user cannot reach or modify. Security rules
cannot validate that a photograph was screened; they can only ensure that nothing
except the server is able to claim it was. This is enforced in `firestore.rules`
and proven by the tests in `rules_test/`.

**Mobile-first, not mobile-only.** Disposal happens standing at a bin, so it is a
phone action. Reviewing a queue of submissions or managing a product catalogue is
desk work. Both are served from one codebase with layouts that respond to the
screen rather than two separately maintained products.

### 3.5 Contribution and intended benefit

| Beneficiary | Benefit |
|---|---|
| Residents | Sustainable effort becomes visible, cumulative and materially worth something. A behaviour that previously returned nothing now returns spending power. |
| Small eco-sellers | A dedicated channel where being handmade or recycled-material is the basis of the marketplace rather than a disadvantage against mass production, plus a portable reputation attached to the seller rather than to a social-media page. |
| Local authorities and bin operators | Attributable, timestamped, location-verified disposal data. Which bins are used, when, and by how many distinct people — currently not measurable at all. |
| The wider community | Money circulating between residents and small local producers rather than leaving for mass-produced imports, and a measurable rather than exhortative approach to disposal behaviour. |

The wider claim is modest and should be stated as such: this does not solve waste
management. It makes one link in the chain — the individual's decision at the
point of disposal — measurable and rewarded, and it routes the resulting value
toward local sustainable production instead of out of the community.

### 3.6 User roles

| Role | Primary goals |
|---|---|
| Resident (Buyer) | Dispose of waste at registered bins, earn points, browse and purchase from the marketplace, redeem points at checkout |
| Eco-Seller | List products, manage inventory, fulfil orders and advance order status |
| Administrator | Register bins and generate QR codes, review flagged submissions, approve seller applications, manage accounts, tune the points policy, view platform statistics |

A single `User` entity carries a `role` field. There are no parallel account
structures — a seller is a user whose role changed after an approved application,
and retains their buyer capabilities.

### 3.7 Scale of ambition

This is a solo academic build on a five-week runway. It is a working prototype
demonstrating a complete earn-and-spend cycle end to end, not a production
system. Deferred capabilities are listed in Section 7.2 with reasons, so that the
boundary of what is delivered is stated rather than left implicit.

---

## 4. Technology decisions

### 4.1 Client

| Layer | Choice | Notes |
|---|---|---|
| Framework | Flutter (stable channel) | Single codebase, Android + Web targets |
| Language | Dart | |
| State management | Riverpod (`flutter_riverpod` 3.4.x, `AsyncNotifier`) | Chosen over Provider for testability and role-gated state |
| Routing | `go_router` | Gives real URLs on the web build — required for admin deep links |
| QR generation | `qr_flutter` | |
| QR scanning | `mobile_scanner` 7.4.0 | |
| Location | `geolocator` 14.0.3 | |
| Photo capture | `image_picker` 1.2.3 | |
| Image compression | `flutter_image_compress` 2.5.1 | Compress and strip metadata before upload — see §7.4 |
| Image display | `cached_network_image` | Catalogue and queue screens load many remote images |
| Push notifications | `firebase_messaging` | Send side is server-only; see §4.3 |
| Linting | `dart analyze` with `flutter_lints` | Must be clean before any device test |

**Android configuration:**

| Setting | Value | Driver |
|---|---|---|
| `minSdk` | **23** | `mobile_scanner` 7.x raised its floor from 21 to 23. v1.5 said 21; that is now wrong |
| `targetSdk` | current | |
| Manifest permissions | `INTERNET`, `CAMERA`, `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` | Runtime-requested with denial states handled |
| `uses-feature` camera | `required="false"` | With `true`, Play Store hides the app from camera-less devices; the marketplace half works fine without one |

**Note on `image_picker` and the camera permission.** Declaring `CAMERA` in the
manifest changes `image_picker`'s behaviour: without the declaration it delegates
to the system camera app and needs no runtime grant, but once declared, Android
requires the app to hold the grant itself. The scanner needs that grant anyway.
If photo capture fails with a permission error, this is why — not a flaky plugin.

**Package policy:** CSE489 explicitly teaches library use — Week 9 is "External
Libraries" and Week 10 "Server Communication," naming Retrofit, GSON, Ion and
Picasso. Third-party packages are **permitted and expected**. No hand-written QR
codec is needed.

### 4.2 Data and identity

| Layer | Choice | Notes |
|---|---|---|
| Auth | Firebase Auth | |
| Database | Cloud Firestore | Syllabus material, Week 11 |
| File storage | Cloudinary, via the Node service | Disposal and claim photographs. Firebase Storage needs the Blaze plan, so uploads go through `POST /photos/disposal` and the client never holds a storage credential |
| Web hosting | Firebase Hosting | Live at `https://chokro-30887.web.app` |
| Rules testing | Firebase Emulator Suite + Jest | 130 tests across 5 files in `rules_test/`, run serially |
| Firebase project | `chokro-30887` | |

### 4.3 Trusted service

**This is the significant departure from v1.5.**

| Layer | Choice | Notes |
|---|---|---|
| Runtime | Node 20+ / Express 4 | `server/` in the same repository |
| Firebase access | `firebase-admin` | Bypasses security rules by design |
| Hosting | Render, free instance | Live at `https://chokro.onrender.com` |
| Screening | Groq, `qwen/qwen3.6-27b` | Free tier, multimodal, no billing card |

**Why not Cloud Functions.** Cloud Functions require the Firebase Blaze plan,
which requires a payment card. An external Node service on a free host achieves
the same trust properties with no billing relationship, and demonstrates the
Week 10 "Server Communication" syllabus material more directly than Cloud
Functions would.

**Cost of that choice.** Render's free instance sleeps after ~15 minutes idle;
the next request takes 30–60 seconds. Mitigation is to warm `/health` before any
demo, optionally with an uptime pinger. This must be in the presentation
checklist, not discovered live.

**Groq free tier caveats**, all of which belong in the term paper's limitations
section:

1. Rate limits are modest and revised without notice. The server must treat a
   `429` as "route to review," never as a failure or an approval.
2. **`qwen/qwen3.6-27b` is served as a preview model for evaluation**, and Groq's
   multimodal lineup changed more than once during this project. A model
   withdrawn mid-semester routes every submission to review — which is the safe
   direction, but it is a dependency on a third party's roadmap.
3. Photographs are sent to a third-party inference provider, so users' disposal
   photographs leave the project's own infrastructure. That is a defensible
   trade-off for an academic prototype only if it is disclosed.
4. Groq accepts only remote HTTP(S) image URLs, not base64. The flow satisfies
   this by design — photographs reach Cloudinary before screening — but it is why
   the upload must precede verification rather than run alongside it.

---

## 5. Architecture

### 5.1 The trust boundary

The single most important structural fact about this system:

> **No client writes a balance. Not a user, not an administrator.**

Firestore security rules can check *who* is making a request. They cannot check
*what happened* — whether a photograph was screened, whether a hash matched an
earlier submission, whether a distance was recomputed from stored coordinates
rather than accepted from the client. So every field that determines or records a
payout is written by the Node service using the Admin SDK, which bypasses rules
entirely.

The rules are therefore not "the rules that award points." They are the rules
that make it impossible for anything except the server to award points.

| Concern | Server | Client | Reason |
|---|---|---|---|
| Wallet credits and debits | ✅ | ❌ | Rules cannot validate a payout decision |
| Ledger writes | ✅ | ❌ | Append-only is meaningless if a client can append |
| Disposal status transitions | ✅ | ❌ | Approval is a payout decision |
| Perceptual hashing | ✅ | ❌ | A client-supplied fingerprint is worthless |
| AI screening call | ✅ | ❌ | Holds the API key; the verdict must be trustworthy |
| Points policy writes | ✅ | ❌ | Rules cannot express the cross-field invariants |
| Bin registration | ✅ | ❌ | Coordinates and radius are payout inputs |
| Push sends | ✅ | ❌ | A device cannot push to other users |
| Wallet creation at signup | ❌ | ✅ | Pinned to `balance == 0` by rules; safe, and keeps registration independent of the server being awake |
| Reading own data | ❌ | ✅ | Rules handle this correctly; no server hop needed |

**Why the administrator is blocked too.** If administrators could write wallets
directly, there would be two code paths that credit a balance and rules could
only police one of them. The admin's approve button calls the server like
everything else. That is what makes the sentence above true without
qualification, and it is a strong presentation point.

### 5.2 Layering (client)

Business logic lives in controllers. Widgets read state and render. Services own
all I/O. The answer to "where does your business logic live" must be one word.

```
lib/
  models/         # Dart classes, fromJson/toJson, validation
  services/       # Firebase and HTTP wrappers
  controllers/    # business logic + state (Riverpod notifiers)
  views/
    <feature>/    # e.g. disposal/, catalogue/, admin_review/
      mobile.dart
      web.dart
    shared/       # widgets used across features
  routing/        # go_router config, role guards
  core/           # constants, theme, breakpoints, geo, points policy
test/             # pure Dart unit tests
```

The view layer is organised **feature-first, platform-second**. Splitting at the
top level by platform puts the two layouts of one screen in different parts of
the tree, which at this feature count becomes hard to navigate and easy to let
drift apart.

**Rules:**

- A widget never calls a service directly. It reads a controller.
- A controller never imports anything from `views/`.
- All Firestore access is behind a service class.
- Models are plain Dart with no Firebase imports. The service layer converts
  `Timestamp` to `DateTime` on the way in, and writes
  `FieldValue.serverTimestamp()` on the way out.

### 5.3 Layering (server)

```
server/
  src/
    index.js        # Express app, routes, startup
    firebase.js     # Admin SDK init from env credential
    auth.js         # ID token verification, role loading
    geo.js          # port of lib/core/geo.dart
    pointsPolicy.js # port of lib/core/points_policy.dart
    phash.js        # perceptual hashing
    screen.js       # Groq call
    award.js        # the single wallet-credit path
  README.md         # deployment, credential rotation, endpoints
```

**Duplicated logic is intentional.** `geo.js` and `pointsPolicy.js` mirror their
Dart counterparts. The client computes distance for user feedback; the server
recomputes it for the decision. Both must agree, and both are unit-tested against
the same reference values. Sharing code across the language boundary would cost
more than it saves at this scale.

**One credit path.** Every award — auto-approved, admin-approved, purchase,
claim — goes through `award.js`. There is exactly one function in the system that
writes a wallet balance, and it always writes a matching ledger entry in the same
transaction.

### 5.4 Responsive strategy

One `LayoutBuilder` breakpoint at **900px** (in `lib/core/constants.dart`). Above
it, web layouts; below, mobile layouts. Controllers and routes are shared — only
the view tree diverges.

### 5.5 Platform split

Distinguish a **capability limit** (the platform cannot do it) from a **layout
preference** (both can, but one is more comfortable). Only the first justifies
excluding a feature from a target.

**The one genuine capability limit** is the disposal flow. Camera and geolocation
on Flutter web go through browser APIs, with HTTPS requirements and weaker
permissions than a native build. The disposal flow is therefore **mobile-only by
design** — defensible as a product decision: disposal is a "standing at a bin
with a phone" action.

This is a **runtime** boundary, not a build one, and the distinction matters
because it is easy to misread. The whole application compiles for web: `flutter
build web` succeeds in release and in WebAssembly. What is mobile-only is the
*execution* of five files that take a `dart:io` `File` for photo capture
(`photo_upload_service`, `disposal_controller`, `claim_controller`, `photo_view`,
`declare_view`, plus `claim_submit_view`); on web those code paths would throw
`UnsupportedError` if reached, and nothing routes to them there. A further five
services import `dart:io` only to name `SocketException` in a catch clause, which
is inert on web — the browser raises `http.ClientException`, which each of them
already handles on the next clause.

None of the web-primary screens is affected: the admin review queue, the claim
queue and the QR/PDF label contain no `dart:io` and no `File`.

**Everything else ships to both targets.** Since controllers and services are
shared, a second view tree is roughly a day of work per screen.

| Capability | Mobile | Web | Notes |
|---|---|---|---|
| Disposal flow (scan → photo → GPS) | ✅ | ❌ | Only true platform limit |
| Browse, cart, checkout | ✅ | ✅ | |
| Seller console | ✅ | ✅ primary | |
| Bin registration + QR generation | ✅ primary | ✅ | Mobile-first: GPS captured on site |
| Admin review queues | ✅ | ✅ primary | Table on web, card list on mobile |
| Admin dashboard | ✅ | ✅ primary | Stat cards stack on mobile |
| Points policy editor | ✅ | ✅ primary | Form; web is more comfortable |

**Where web stays preferred, and why:** printing a QR to paper is a print dialog
on web and an export-then-share on mobile; dense review queues read better as a
wide table; dashboard density suits side-by-side comparison.

---

## 6. Data model (Firestore)

| Collection | Key fields |
|---|---|
| `users` | `uid`, `name`, `email`, `role` (buyer/seller/admin), `status` (active/suspended), `suspendedUntil`, `createdAt` |
| `sellerApplications` | `userId`, `businessName`, `description`, `status`, `reviewedBy`, `reviewedAt`, `reason` |
| `bins` | `binId`, `label`, `lat`, `lng`, `radiusMeters`, `qrPayload`, `active`, `createdBy` |
| `disposals` | see below — the largest change from v1.5 |
| `wallets` | `userId`, `balance`, `updatedAt` — one document per user |
| `transactions` | `userId`, `delta`, `source` (disposal/purchase/claim/redemption), `refId`, `balanceAfter`, `createdAt` |
| `products` | `sellerId`, `shopName`, `title`, `titleLower`, `searchTokens[]`, `description`, `category`, `tags[]`, `price`, `stock`, `imageUrls[]`, `active`, `hiddenBySuspension` (server), `createdAt`, `updatedAt` |
| `carts` | `userId`, `items[]` (productId, qty only — never a cached price) |
| `orders` | `buyerId`, `buyerName`, `sellerId`, `sellerName`, `shopName`, `checkoutId`, `items[]` (productId + **snapshot** of title and unit price), `subtotal`, `pointsApplied`, `discount`, `payable`, `settlementMethod`, `paymentStatus`, `status`, `pointsAwarded`, timestamps |
| `claims` | `userId`, `actionType`, `photoUrl`, `photoHash`, `status`, `rejectionReason`, `reviewedBy`, `reviewedAt`, `pointsAwarded`, `createdAt` |
| `claimQuotas` | Document ID `{userId}_{isoWeek}`, field `count` |
| `lockouts` | Document ID `{userId}_{binId}`, field `expiresAt` |
| `config/points` | The runtime points policy — see §7.3 |
| `stats` | Single document (`stats/platform`) holding running counters for the admin dashboard: `disposalsApproved/Rejected`, `claimsApproved/Rejected`, `pointsIssued`, `pointsRedeemed`, `ordersCreated`, `ordersConfirmed`, `salesPayable` |
| `appeals` | `userId`, `subjectType` (disposal/claim), `subjectId`, `message`, `status` (pending/upheld/declined), `response`, `reviewedBy`, `reviewedAt`, `createdAt` |

### 6.1 The `disposals` document

Expanded substantially from v1.5 to carry the screening pipeline:

| Field | Written by | Notes |
|---|---|---|
| `userId`, `binId`, `photoUrl` | client | |
| `capturedLat`, `capturedLng` | client | The raw location fix |
| `distanceMeters` | client | **Feedback only.** The server recomputes from the coordinates |
| `declaredItemCount` | client | How many items the user says they are disposing of |
| `itemType` | client | From a closed vocabulary — see below |
| `status` | server | Four states — see below |
| `flags[]` | server | Why the submission went to review |
| `photoHash` | server | Perceptual hash, for duplicate detection |
| `screenConfidence`, `screenItemCount`, `screenNotes` | server | Screening output. `screenNotes` is admin-only; showing it to users would teach them how to game the screen |
| `pointsAwarded` | server | Snapshotted at decision time |
| `rejectionReason` | server | Mandatory on rejection, shown to the user |
| `reviewedBy`, `reviewedAt` | server | Null on an auto-approval — which is how the two paths stay distinguishable |
| `createdAt` | server timestamp | Client-authored timestamps are rejected by rules |

**Status is a four-state machine, not three:**

| Status | Meaning |
|---|---|
| `pending` | Awaiting a human decision. Wallet untouched; UI shows the amount as pending |
| `autoApproved` | Every mechanical check passed and screening was confident. Credited without human involvement |
| `manualApproved` | Credited by an administrator after review. User is told it was manually verified |
| `rejected` | No points, reason recorded and shown, lockout released so a legitimate retry is possible |

The two approved states are deliberately separate. Collapsing them would lose the
answer to "was this checked by a person?", which is what an examiner will ask
about any auto-credited award and what an appeal needs in order to be meaningful.
Parsing an unrecognised status falls back to `pending` — **fail toward no
payout**.

**`itemType` vocabulary** (closed, not free text): plastic bottles, other
plastic, paper and cardboard, glass, metal and cans, electronic waste, organic
waste. A closed vocabulary makes submissions sortable and gives the screen
something specific to check the photograph against.

**`flags` vocabulary:** `outsideRadius`, `duplicatePhoto`, `countMismatch`,
`lowConfidence`, `itemTypeMismatch`, `dailyCapReached`, `screeningUnavailable`.
Each carries a sentence shown to the reviewing administrator, so the queue
explains itself rather than presenting a photograph with no context. A submission
may carry several at once.

### 6.2 Invariants

- A wallet document is created **atomically with the user account at
  registration**. Downstream flows assume it exists.
- Balance is always reconstructable from the `transactions` ledger. Never write a
  balance without writing a matching transaction in the same atomic operation.
- **Awards are snapshotted, never re-derived.** An administrator lowering the
  disposal award must not rewrite what past submissions were worth.
- Stock is decremented inside the checkout transaction.
- **Order line items snapshot the title and unit price at purchase time.**
- **The cart stores no prices.** Price is authoritative at checkout.
- **Products are never hard-deleted.** F4.1's "delete" sets `active: false`.
- Points are debited at checkout (`source=redemption`) and credited only on buyer
  confirmation (`source=purchase`).
- No payment card data is stored in any schema. Settlement is cash-on-delivery.
- **The cart's element shape is enforced at checkout, not in the rules.** Rules
  cannot iterate a list, and the cart carries no value — the server resolves
  every `productId` against a live listing and ignores anything else it finds.
- **A product's image URLs are validated by index, not by iteration.** The
  three-image ceiling exists so each slot can be named explicitly in the rules;
  an unbounded list would mean unvalidated entries.
- The `bins.qrPayload` is an opaque bin identifier only. It carries no
  coordinates and no user data, so a photographed code discloses nothing.
- Every `createdAt`, `expiresAt` and review timestamp uses
  `FieldValue.serverTimestamp()`.

### 6.3 Rules design

**Security rules were written and deployed before any M2 UI work**, per the M1
lesson. Current shape:

| Collection | Client read | Client write |
|---|---|---|
| `users` | own, or any if admin | create own as buyer; update own name; admin updates role/status/suspension |
| `wallets` | own, or any if admin | **create own at balance 0 only.** No update, no delete, for anyone |
| `transactions` | own, or any if admin | none |
| `bins` | any signed-in | none |
| `disposals` | own, or any if admin | create own `pending` with an exact key set; no update, no delete |
| `lockouts`, `claimQuotas` | any signed-in | none |
| `config` | any signed-in | none |
| `sellerApplications` | own, or any if admin | create own; admin updates status |
| `products` | any signed-in | **owning active seller** creates and updates their own within an exact key set; never deleted |
| `carts` | own only, no admin | own only, exact key set, ≤20 items, server clock |
| `orders` | buyer, seller, or admin | **none** — every transition is a server decision |
| `appeals` | own, or any if admin | create own against your own *rejected* submission; admin resolves once with a written answer |
| `stats` | admin only | none |
| everything else | denied | denied |

Two constructs carry most of the weight:

**`hasOnly` on disposal creation, not `hasAll`.** An exact key set is what keeps
`pointsAwarded`, `photoHash`, `screenConfidence` and `reviewedBy` out of a
client-authored document. `hasAll` would permit extra keys and the guarantee
would leak.

**Single-document lockout lookup.** Rules cannot run time-window queries across a
collection, hence `lockouts/{userId}_{binId}` with an `expiresAt` that rules can
read in one lookup.

**Bootstrapping the first admin.** No self-service path creates an admin. Promote
one account manually in the Firestore console. Rules forbid a user from writing
their own `role` field, and there is a test proving it.

**Firestore has no full-text search.** F4.2's "keyword search" uses a
`searchTokens[]` array queried with `array-contains`, written at product-save
time. Do not reach for Algolia; the catalogue will hold tens of products.

**Composite indexes.** Filtering by category *and* tag *and* sorting requires
composite indexes. Commit `firestore.indexes.json` so the configuration is
reproducible.

**Dashboard counters.** Maintain a `stats` document incremented with
`FieldValue.increment()` inside the same transactions that create users,
submissions and awards, rather than reading whole collections.

**Order status ownership.** `pending` on creation, `shipped` and `delivered` set
by the seller, `confirmed` set by the **buyer** — and only `confirmed` releases
purchase points. A seller cannot confirm their own delivery.

---

## 7. Scope — 35 features

### FR-1 Identity and roles

| ID | Feature | Platform | Status |
|---|---|---|---|
| F1.1 | Account creation and profile management | Both | ✅ M1 |
| F1.2 | Seller role application | Both | ✅ M1 |
| F1.3 | Admin review of seller applications | Both (web primary) | ✅ M1 |

### FR-2 Verified waste disposal

| ID | Feature | Platform | Status |
|---|---|---|---|
| F2.1 | Bin registration with printable QR generation | Both (mobile-first, GPS capture) | M2 |
| F2.2 | Bin QR scan | Mobile | M2 |
| F2.3 | Disposal photo capture and upload | Mobile | M2 |
| F2.4 | Geolocation capture at time of scan | Mobile | M2 |
| F2.5 | GPS radius validation against bin coordinates | Mobile + server | M2 |
| F2.6 | Duplicate-claim lockout (time window per user per bin) | Rules + server | M2 |
| F2.7 | Admin review queue for pending submissions | Both (web primary) | M2 |
| F2.8 | Approve or reject with logged reason | Both (web primary) | M2 |
| F2.9 | **Declared item count and type at submission** | Mobile | M2 |
| F2.10 | **Automated photo screening (Groq)** | Server | M2 |
| F2.11 | **Perceptual-hash duplicate detection** | Server | M2 |
| F2.12 | **Two-lane decision: auto-approve or route to review** | Server | M2 |

The client-side distance check in F2.5 is for user feedback only. The
authoritative check runs on the server against the stored coordinates — a client
can lie about its location, so nothing is trusted merely because the app
calculated it.

### FR-3 Points economy

| ID | Feature | Platform | Status |
|---|---|---|---|
| F3.1 | Unified wallet with single balance | Both | ✅ M1 |
| F3.2 | Source-tagged transaction ledger | Both | M2 |
| F3.3 | **Admin-tunable points policy** | Both (web primary) | M2 |

### FR-4 Marketplace

| ID | Feature | Platform | Status |
|---|---|---|---|
| F4.1 | Seller product create/edit/delete/list | Both | ✅ M3 |
| F4.2 | Catalogue browse with keyword search and category filter | Both | ✅ M3 |
| F4.3 | Shopping cart | Both | ✅ M3 |
| F4.4 | Checkout and order creation | Both | ✅ M3 |
| F4.5 | Point redemption at checkout | Both | ✅ M3 |
| F4.6 | Order status tracking, with seller order list and advancement | Both | ✅ M3 |
| F4.7 | Buyer receipt confirmation, releasing purchase points | Both | ✅ M3 |
| F4.8 | Settlement method and payment status recorded | Both | ✅ M3 |

### FR-5 Administration

| ID | Feature | Platform | Status |
|---|---|---|---|
| F5.1 | Admin dashboard with aggregate statistics | Both (web primary) | ✅ M3 |
| F5.2 | User suspension and reinstatement | Both (web primary) | ✅ M3 |
| F5.3 | **Temporary suspension with an expiry** | Both (web primary) | M2 |
| F5.4 | **User appeal against a rejection** | Both | ✅ M3 |

### FR-6 Self-reported eco-actions

| ID | Feature | Platform | Status |
|---|---|---|---|
| F6.1 | Point-claim submission with action type from a fixed vocabulary | Mobile | M2 |
| F6.2 | Claim photo capture and upload | Mobile | M2 |
| F6.3 | Admin claim review — approve or reject with logged reason | Both (web primary) | M2 |
| F6.4 | Claim rate limiting per user per period | Mobile + rules | M2 |

Action-type vocabulary is fixed, not free text: tree planting, composting,
refusing single-use plastic, reusable bag or bottle use, community cleanup
participation.

This is the **weakest verification route** and is treated accordingly. It reuses
the disposal machinery almost entirely: same photo pipeline, same queue shape,
same approve/reject with reason, same credit path. What it lacks is a bin, a
geofence and a distance check, because there is nothing objective to check
against. **Claims are never auto-approved** — the auto-approval lane exists only
where mechanical checks can pass.

### FR-7 Notifications

| ID | Feature | Platform | Status |
|---|---|---|---|
| F7.1 | **Push notification on a decision (FCM)** | Mobile | M2 |
| F7.2 | **In-app submission history with status and reason** | Both | M2 |

### 7.1 End-to-end workflows

**Earn loop (disposal).**
`Admin registers bin on site → GPS captured → QR generated and printed →
resident scans code → app resolves bin → resident declares item count and type →
photographs disposal → device coordinates captured → submission stored as pending
→ server recomputes distance, hashes the photo, checks for duplicates, screens
the image → if everything passes, credit and push "50 points added" → otherwise
flag and route to the admin queue → admin reviews photo, distance, flags and the
user's history → approve or reject with reason → on approval, wallet credited and
ledger entry written with source=disposal, push "manually verified" → resident
sees balance and reason in history`

**Spend loop (marketplace).**
`Seller lists product → buyer browses and filters catalogue → adds to cart →
checkout: points optionally applied against payable, stock decremented, cart
split into one order per seller → settlement method recorded → seller advances
status to shipped → buyer confirms receipt → order finalised, purchase points
credited with source=purchase`

**Claim loop (self-reported action).**
`Resident selects an action type → photographs it → weekly quota checked → claim
stored as pending → admin reviews photo, action type and the user's previous
claims → approve or reject with reason → on approval, wallet credited with
source=claim at a lower award than disposal → quota counter incremented`

**Governance loop (admin).**
`User applies for seller role → admin reviews → role changes on approval → admin
monitors dashboard statistics → tunes the points policy → suspends an account on
misuse, permanently or with an expiry → suspended account is blocked at the rules
layer and at the server, not only in the UI → user may appeal a rejection`

The spend loop terminates by *crediting* the wallet, which is what makes the two
loops a cycle rather than a pipeline. This must be demonstrable in one continuous
run.

### 7.2 Deferred scope

Excluded from this release, with reasons — state these explicitly so the boundary
is deliberate rather than accidental:

| Deferred | Reason |
|---|---|
| Eco-stories and community feed | Social layer that touches no wallet and no verification path |
| Reviews and ratings | Depends on completed order history that will not accumulate within the timeline |
| Order cancellation and refunds | Reversing a points debit and restoring stock is a second transaction path; the forward path demonstrates the mechanism |
| Rewards catalogue and redemption | Point redemption at checkout already demonstrates the spend path |
| Bangla localisation | Structured for — no hard-coded display strings — but not delivered |
| Cross-user duplicate photo detection | Hashes are compared within a user's own history only. Detecting a photograph shared between two accounts needs a global hash index; stated as a limitation |

**Removed from deferred since v1.5:** AI pre-screening of photographs (now F2.10,
core) and in-app notifications (now F7.1, as real FCM push).

### 7.3 Points policy

Implemented in `lib/core/points_policy.dart` with a mirror in
`server/src/pointsPolicy.js`. The values below are **defaults**; the live values
live in `config/points` and are editable by an administrator (F3.3).

| Parameter | Value | Reasoning |
|---|---|---|
| Disposal award | 50 points | Round number, visible progress from one action |
| Claim award | 15 points | Deliberately below disposal: weakest verification pays least |
| Claim quota | 3 approved claims per user per ISO week | The rate limit *is* the safeguard here |
| Purchase award | 5% of `payable`, in points, rounded down | ৳1000 order earns 50 points |
| Redemption rate | 100 points = ৳10 | Makes one disposal worth ৳5 |
| Max points per order | 50% of subtotal | Points supplement payment, they do not replace it |
| Lockout window | 6 hours per user per bin | Blocks trivial farming; permits genuine twice-daily disposal |
| Daily disposal cap | 3 approved submissions per user | Second line of defence against multi-bin farming |

**On the purchase award unit.** 5% is computed in *points*, not in taka value —
a ৳1000 order earns 50 points, worth ৳5, an effective 0.5% return. This is
deliberate and should be stated as such: the marketplace is a light loyalty
bonus, not a competitive earn route, because two-party confirmation is weaker
verification than a geofence.

**Enforced invariants** (`PointsPolicy.validate()`):

- Every award, quota, window and cap must be positive.
- Percentages must be within 0–100.
- The lockout window may not exceed one week.
- **Claim award must be strictly below disposal award.** If a weaker route ever
  pays better than a stronger one, users optimise into it and the verification
  design stops meaning anything.

Reads are forgiving — a malformed `config/points` falls back per-field to
defaults rather than crashing. Writes are strict — the server runs `validate()`
before persisting, because rules cannot express cross-field invariants.

**Redemption granularity.** 100 points = ৳10 means 10 points = ৳1, so points are
spent in multiples of 10 and remainders stay in the wallet. Without this the
ledger eventually fails to reconcile.

### 7.4 Integrity edge cases

Each is a plausible viva question with a specific answer.

**Multi-seller cart.** A cart may hold products from several sellers, but an
order carries one `sellerId`. Checkout **splits the cart into one order per
seller** under a shared `checkoutId`.

**Self-dealing.** Enforce `buyerId != sellerId` at checkout, in rules and in the
controller.

**Client clock manipulation.** Every timestamp that matters uses
`FieldValue.serverTimestamp()`. Rules reject a client-authored `createdAt` on a
disposal outright.

**Photo metadata.** Uploaded photographs may carry GPS EXIF data. The submission
stores coordinates deliberately in its own fields; strip metadata before upload.

**Client-supplied hash.** The perceptual hash is computed server-side from the
stored image. A client-computed hash is worthless — a modified app would send a
fresh random value every time and the check would never fire. Rules reject a
`photoHash` key on creation.

**Screening unavailable.** A rate limit, timeout or error from the screening
service produces the `screeningUnavailable` flag and routes to review. It never
approves and never rejects. Fail toward review.

**Count disagreement.** Object counting from a photograph is unreliable, so a
mismatch between the declared count and the screen's estimate **flags for review
rather than rejecting**. Auto-rejection on this signal would fire constantly on
honest users.

**Recycled claim photographs.** The mitigations are the weekly quota, the reduced
award, hash comparison against the user's own history, and an administrator who
can see previous claims — so the review screen must show a user's history
alongside the pending item. Cross-user sharing is not detected; state this.

**Claim quota timing.** The counter increments on **approval**, not submission —
otherwise a user could exhaust their own week with rejected junk.

**Rejected submission.** No points, reason recorded and shown, lockout released
so the user can legitimately retry, and the user may appeal (F5.4).

**Suspended seller.** Suspension hides products from the catalogue but does not
delete them, and does not cancel orders in flight.

**Stock race.** The stock decrement lives inside the same transaction as the
order write, so one buyer succeeds and the other fails cleanly.

### 7.5 Non-functional requirements

| ID | Requirement |
|---|---|
| NFR-1 | Primary actions reachable within three taps from the home screen |
| NFR-2 | Firestore reads paginated; images compressed before upload |
| NFR-3 | Passwords handled by Firebase Auth; role enforcement in rules and on the server, not only in client routing |
| NFR-4 | Every balance change written as a ledger entry; balance reconstructable from history |
| NFR-5 | Strict separation between models, services, controllers and views |
| NFR-6 | Both builds run from one codebase; no forked logic between platforms |
| NFR-7 | Firestore offline persistence enabled. A submission composed with no connectivity queues and syncs on reconnection — connectivity at a roadside bin is not assumed |
| NFR-8 | Interface language is English; structured for localisation |
| NFR-9 | **No credential appears in the repository.** Verified by `.gitignore` and checked before each commit |
| NFR-10 | **The server never logs credential content.** Parse failures report length and first character only |

---

## 8. Milestones

### Milestone 1 — Foundation, identity and roles ✅ COMPLETE

**Delivered:**

- Flutter scaffold with `android`, `web` and `ios` targets; Firebase configured
  on all three
- `firestore.rules` with deny-all default and explicit blocks for `users`,
  `wallets`, `sellerApplications`
- 16 rules tests (Jest + `@firebase/rules-unit-testing`) against the emulator
- Models: `UserModel`, `WalletModel`, `SellerApplicationModel`
- Services: `AuthService`, `UserService`
- Controllers: `AuthController`, `SellerApplicationController`
- Views: login, register, home, seller application, admin review queue, inside a
  responsive `AppShell` (NavigationRail above 900px, NavigationBar below)
- Registration creates `users/{uid}` and `wallets/{uid}` atomically in one batch
- Seller applications flip the applicant's role live via Firestore streams
- Deployed to Firebase Hosting

---

### Milestone 2 — Disposal, screening, verification and review

*Target: second phase update*

**Objective:** Both administratively-verified earn paths, plus the automated
screening lane, through one review pipeline.

**Features:** F2.1–F2.12, F3.2, F3.3, F5.3, F6.1–F6.4, F7.1, F7.2

#### Completed so far

- `lib/core/points_policy.dart` — all §7.3 values, redemption arithmetic, lockout
  windows, ISO week keys; 41 unit tests
- `lib/core/geo.dart` — Haversine distance, radius check, coordinate validation;
  verified against reference geodesic values
- `lib/models/bin_model.dart`, `lib/models/disposal_model.dart` — including the
  four-state status machine and the flag vocabulary
- **300 passing Dart unit tests** across 20 files, `flutter analyze` clean
- `firestore.rules` revised: wallets, transactions, disposals, bins, config,
  lockouts and quotas all server-owned for writes
- **130 passing rules tests**, including the two that matter — an administrator
  cannot credit a wallet, and an administrator cannot approve a disposal from the
  client
- Camera, location, scanner, compression and storage packages added; Android
  manifest permissions and iOS usage descriptions in place
- Node service skeleton deployed to Render at `https://chokro.onrender.com` with
  `/health`, `/whoami` and `/admin/ping`
- `server/README.md` documenting deployment and credential rotation

#### Remaining

Every item previously listed here is built: the disposal submission flow, bin
registration with on-site GPS capture and a printable PDF label, all three server
endpoints, `award.js` as the single wallet-credit path, the review queue with
photo, distance, flags and the submitter's record, the wallet and history screens,
FCM push on decision, claims, and temporary suspension with expiry. All nineteen
M2 features and all of M1 have working code.

What actually remains:

- **One exit criterion is not literally met.** The weekly claim quota is enforced
  by the server at approval, not by the rules at creation — see the note under the
  exit criteria below. The guarantee holds either way, because no client can
  approve a claim; it is enforced in a different place from where the criterion
  says.
- **Verification that needs a physical device.** No push notification has been
  delivered, no disposal has gone through the full pipeline against a real bin,
  and no temporary suspension has been observed lapsing. An emulator fakes GPS and
  the camera and yields no FCM token, so none of these can be closed from a
  desktop (§8).
- **The web-primary screens have not been clicked through on the deployed site.**
  The web target compiles — release and WebAssembly builds both succeed — and the
  review queue, claim queue and PDF label touch no `dart:io` and no `File`, so
  there is no known reason they should fail. That is not the same as having seen
  them work.

**Exit criteria:**

- End to end: scan a printed QR → declare count → photo → GPS → submit →
  auto-approved → balance increases → ledger shows a `disposal`-sourced entry →
  push received
- A deliberately ambiguous photo routes to review, appears in the admin queue
  with its flags, and credits on approval with a "manually verified" message
- A submission outside the radius is refused with a clear message
- A second submission at the same bin inside the lockout window is refused
- Screening unavailable routes to review rather than approving or rejecting
- A claim submitted, approved and credited at the lower award
- A user at their weekly quota is refused a fourth claim by rules, not only by
  the UI

**On that last criterion.** As built, the quota is enforced by the trusted server
inside the approval transaction, which reads `claimQuotas/{uid}_{isoWeek}` and
refuses past the limit. The rules do not check it at creation, so a fourth claim
can be *submitted* and is then refused when an administrator tries to approve it.

The criterion is left as originally written rather than softened to match the
implementation. The substantive guarantee — that no client can award itself points
past the quota — does hold, because no client can approve a claim at all. What is
missing is enforcement at the earlier boundary.

The reason it was not done at the rules layer is worth recording: the quota
document is keyed by ISO week, and Firestore rules cannot compute an ISO week
number (`request.time` exposes `year()` and `dayOfYear()` but no ISO-week
arithmetic). A rules-computed approximation would produce a different key from the
server's and the two would silently disagree, which is worse than not checking. It
is achievable by having the server write the window's end date onto the quota
document so the rules need only a timestamp comparison — the same shape as
`lockoutActive()` — at the cost of rekeying the collection.

**Risks:** This is the heaviest and highest-risk milestone — nineteen features
plus a backend service. Camera and location permissions behave differently across
Android versions; **test on a physical device, since emulator location mocking
hides problems.** If the schedule slips, cut in this order: (1) self-reported
claims (F6.x), (2) AI auto-approval, falling back to admin-only review, which
leaves everything else intact. Decide by the milestone's midpoint.

---

### Milestone 3 — Marketplace, spend path and dashboard

*Target: third phase update and final presentation*

**Objective:** The spend path closed and the platform made presentable.

**Features:** F4.1–F4.8, F5.1, F5.2, F5.4

**Deliverables:**

- Seller product management with image upload
- Fixed category vocabulary and normalised tags; `searchTokens[]` at save time
- `firestore.indexes.json` committed
- Buyer catalogue with search and filters
- Cart with quantity adjustment
- Checkout as a single transaction: split per seller, stock decremented, points
  debited, `buyerId != sellerId` enforced
- Point redemption written as a `redemption` ledger entry
- Order status tracking and buyer receipt confirmation crediting purchase points
- Appeals: user raises a question against a rejection; admin resolves
- Admin dashboard reading the `stats` counter document
- User suspension and reinstatement with audit fields
- Theme pass, empty states, loading states, error handling
- Seed script producing demo users, bins, products and orders — never demo from
  an empty database
- Release APK built and installed on a physical device
- Web build deployed at a shareable URL
- Diagrams: use-case, architecture, data model, earn/spend cycle
- Term paper drafted
- Presentation rehearsed against the seeded dataset, on the real device

#### Completed so far

Every code deliverable above is built. See `INTEGRATION_NOTES_M3.md`.

- `lib/core/product_taxonomy.dart` — the closed category vocabulary, tag
  normalisation and the `searchTokens[]` builder; `lib/core/checkout_math.dart` —
  seller grouping and largest-remainder discount allocation, mirrored by
  `server/src/checkout.js` with the same worked examples asserted on both sides
- Models: `product_model`, `cart_model`, `order_model`, `appeal_model`,
  `stats_model`
- **425 passing Dart unit tests** (up from 300), `flutter analyze lib` clean
- `firestore.rules` extended with `products`, `carts`, `orders`, `appeals` and
  `stats`; **209 passing rules tests**, including the one that matters for the
  spend path — a buyer cannot set an order to `confirmed` and credit themselves
- `firestore.indexes.json` carries nine new composite indexes covering every
  catalogue, order and appeal query the client issues
- Trusted service at `0.4.0`: `POST /checkout`, `POST /orders/:id/status`,
  `POST /orders/:id/confirm`, `POST /photos/product`,
  `POST /sellers/:uid/listings`; **212 passing Node unit tests**
- Screens: catalogue with search and category filter, product detail, cart,
  checkout with a points slider, buyer orders, seller console and editor, seller
  fulfilment queue, appeals for both parties, admin dashboard
- `server/scripts/seed.js` — accounts, bins, listings, disposals, claims, orders
  and an appeal, with the ledger accumulated rather than asserted
- Release and WebAssembly web builds both succeed

#### Remaining

- **A release APK on a physical device.** The web build compiles and the whole
  marketplace avoids `dart:io`, so nothing is known to block it — which is not
  the same as having installed it.
- **The web build is not deployed at the shareable URL yet.** `flutter build web`
  succeeds; the deploy is a separate step.
- **Diagrams, the term paper and the rehearsal.** §10, and produced from the
  working system rather than from intention.

**Exit criteria:**

- One continuous demo closes the full cycle: dispose → approved → balance up →
  spend at checkout → confirm receipt → balance up again, with four distinct
  `source` values visible in the ledger
- Both builds run cleanly with no analyzer warnings
- The APK installs and runs without a development server attached
- Every feature except the disposal flow is reachable on both targets

**Risks:** Polish always overruns. Freeze features one week before the
presentation. **Warm the Render service before demonstrating.**

---

## 9. Working conventions

- I reference features by ID (F2.5, F4.3) from Section 7. Use the same IDs when
  reporting progress.
- I give terse, directive implementation commands. Implement carefully and
  incrementally rather than asking many clarifying questions.
- For each feature group delivered, produce an **integration notes file**
  documenting: files added or changed, wiring required, import assumptions, the
  API/state surface exposed, and bugs found while testing. I use these to prepare
  for the presentation, so write them to be defensible under questioning.
- Prefer writing and testing **pure logic modules without Firebase first**
  (distance, tag normalisation, lockout windows, ledger arithmetic, hashing),
  then layering services and controllers on top.
- Run `dart analyze lib/` clean before any device or browser test.
- During terminal work, guide me **one command block at a time** and wait for the
  result before continuing.
- I develop on macOS. Node and other tooling are Homebrew-managed. Disk headroom
  is limited; `~/.gradle/caches` is safe to clear if a build fails on space.
- Tests should prove security properties, not just happy paths — no card data in
  any schema, no client-writable balance field, no auto-approval on any path the
  client controls.
- Three kinds of test only: pure Dart unit tests, Firebase Emulator rules tests,
  and pure Node unit tests for server logic. No widget tests, no integration
  harness — the schedule does not justify them and the marking does not reward
  them.
- **Each Jest suite uses its own `projectId`.** Suites sharing one project ID run
  in parallel against the same emulator namespace and clear each other's seed
  data mid-test.

---

## 10. Course deliverables beyond the code

The CSE489 assessment line is "Project **and Term Paper**," worth 40%.

| Deliverable | Timing | Notes |
|---|---|---|
| Project proposal | Around Week 8 | Sections 3, 5 and 7 are most of it already |
| Phase updates | Weeks 10, 11, 12 | Marked. Each maps to one milestone. Push to GitHub before each |
| Term paper | With final submission | Problem, related work, requirements, architecture, implementation, results, limitations, future work. Draft alongside M3 |
| Diagrams | With the term paper | Produce them from the working system, not from intention |
| Final presentation | Week 13 | Five-minute demo. Rehearse §7.1 until it runs without hesitation |
| Repository | Throughout | Regular commits with meaningful messages |

**Limitations section must include:** photographs are sent to Groq, a third-party
inference provider, and leave the project's own infrastructure; `qwen/qwen3.6-27b`
is a preview model that could be withdrawn; screening confidence thresholds were
tuned on a small sample; duplicate detection is within-user only; the geofence
proves phone proximity, not disposal; Render cold starts; no cross-device testing
beyond one Android phone.

Confirm the current semester's exact dates — the outline in hand is from Summer
2024.

---

## 11. Security posture

Short, and worth stating explicitly because it is a presentation talking point.

1. **One sentence to remember:** no client writes a balance, not even an
   administrator. Enforced in rules, proven by tests.
2. **The service account key bypasses every rule in the project.** It lives in an
   environment variable, never in the repository. `.gitignore` excludes
   `server/.env` and `*.serviceaccount.json`; verify with `git check-ignore -v`
   before any commit that could touch them.
3. **Rotation is cheap.** If a key is ever exposed — pasted into a chat or issue,
   committed, emailed — delete it in the Google Cloud console, generate a
   replacement, update `.env` and the Render variable. Procedure documented in
   `server/README.md`.
4. **Credentials go clipboard-to-destination.** Base64-encode for transport so
   nothing in the chain can mangle braces, quotes or escaped newlines.
5. **Logs never contain credential content.** A parse failure reports length and
   first character only.

---

## 12. Immediate next steps

1. Borrow an Android phone; the submission flow cannot be validated on an
   emulator, which fakes both GPS and the camera.
2. Build the disposal submission UI (F2.2, F2.3, F2.4, F2.9) against the deployed
   rules — it ends at a pending document with the wallet untouched, and needs no
   server.
3. Verify permissions, scanning and a real GPS fix on hardware.
4. Obtain a Groq API key from console.groq.com. It is unrelated to Google Cloud,
   so `chokro-30887`'s billing state stays independent by construction.
5. Build the server's verification endpoint: distance recomputation, perceptual
   hashing, screening, and the single credit path.
6. Build the admin review queue.
