# Commit log

A running record of every change to this repository: the date, the time, and a
short message describing what changed and why.

Newest first. Entries dated before 2026-08-24 12:52 are backfilled from
`git log`; everything from that point on is written when the change is made.

**Format**

```
## YYYY-MM-DD HH:MM (+06) — <short title>
<one or two sentences: what changed, and what it fixes or adds>
Files: <the areas touched>
Checks: <analyze / test results, when the change is verifiable>
```

---

## 2026-08-26 11:40 (+06) — The five never-audited areas, audited

The prior audit planned eleven areas of `lib/` and ran six. The remaining five
— `admin-queues`, `admin-config`, `wallet-donations`, `seller`, `shared-core` —
had never been looked at by anyone. They have now been, and the results were
worse than the six that had: **six high-severity defects**, three of them in
paths that move points or make decisions about them.

The ones worth naming:

- **Sign-out could not complete offline.** `unregisterDevice` was written to
  "never throw" so cleanup could not block sign-out — but Firestore offline
  persistence *queues* a delete, and the Future neither returns nor throws
  until it reaches a server. The `await` simply never finished, the catch never
  ran, and a user out of signal was never signed out at all.
- **The appeal review gate leaked between appeals.** The "I reviewed the
  photograph" tick lives in the card's local State and the cards were unkeyed,
  so resolving one appeal shifted the rest up a position and Flutter re-used the
  State by index — arming Uphold and Decline on evidence nobody had opened.
- **A listing save wrote stale stock over the server's decrements**,
  resurrecting stock that sales had already consumed.
- **Retrying a failed donation could debit twice.** `resetDraft()` nulled the
  idempotency key and the screen called it from six ordinary-interaction
  callbacks, so tapping the same amount chip after a lost response minted a
  second key.
- **The redemption block accepted ratios the app will not honour** — only the
  integer quotient is used, so "150 points to BDT 20" was applied as 7 points
  per taka and "10 points to BDT 100" gave away a hundredfold.
- **The points policy silently reverted another admin's change**: a full
  overwrite from a baseline cached for the whole session, with no version check
  anywhere on the path.

Plus: every text field's resting outline measured 1.33:1 against its own fill,
under WCAG's 3:1 floor for a control boundary; `friendlyErrorMessage` forwarded
raw `StateError` text so users read "Bad state: Not signed in."; an offline user
with a cold cache was told their profile was missing and to register again; and
a failure in `main()` left a black screen.

Two reported findings dissolved on contact with the code, and one of my own
earlier fixes was a regression the audit caught: the image work had downscaled
the eco-action queue's photo, which is not a thumbnail but the image an admin
decides a claim from. `image_delivery.dart`'s own library doc states the
invariant that was broken. The appeals queue's private viewer is now shared as
`EvidenceThumbnail`/`showEvidencePhoto`.

Files: ~25 modified, 3 added (`views/shared/evidence_viewer.dart`,
`views/shared/notice_card.dart`, `core/image_delivery.dart`), 7 new test files.

Checks: `flutter analyze` clean · `flutter test` 619 → **646** ·
`npm test --prefix server` 282 · `rules_test` 232 · `flutter build web` succeeds.

## 2026-08-26 09:30 (+06) — Verified the outstanding UX audit, then fixed it

`UX_AUDIT_OUTSTANDING.md` opened by saying its own verification stage never
ran, and that roughly one in ten of its findings would dissolve on contact with
the code. That stage was run: all 44 leads read against the real source. 43
confirmed or partly confirmed, 1 dissolved (`market-buyer-9` — the catalogue's
Search key does work). Two of the doc's *suggested fixes* were also wrong and
would have shipped new bugs: comparing bins by the nullable `id` skips the
reset in exactly the case that needs it, and clearing the cached photo upload
on `clearPhoto` would have attached a stale photo URL to a retaken photograph.
Both corrections are recorded in the code where they were made.

Highlights: the eco-action form opened onto a stale "Sent for review" with no
form for anyone who had ever left it by the back button; a suspended user's
navigation tabs were silently inert; the quota banner said "3 claims left this
week" when the number counts *approvals*; the profile picker could not be
scrolled at accessibility text sizes, locking an Admin out of the Champion
workspace; and signing out recorded the current screen, so the next person to
sign in on a shared handset landed there.

Also consolidated three divergent private `_Notice` widgets into one shared
tone-based `NoticeCard`.

Files: 30 modified, 2 added (`views/shared/notice_card.dart`, and the corrected
quota expectations in `test/claim_quota_status_test.dart`).

Checks: `flutter analyze` clean · `flutter test` 594 → **598**.

## 2026-08-26 09:31 (+06) — Performance: image decode and list virtualisation

Two costs shipped for the life of the project, neither visible in a screenshot.

Every photograph was delivered at upload resolution — the compressor targets
1600 px — and painted into 40 px avatars and 76 px thumbnails. Flutter decodes
to uncompressed RGBA regardless of the box, so each was ~10 MB of cache: a
twenty-item catalogue held ~200 MB of bitmaps and pulled ~8 MB over the wire to
draw twenty thumbnails. `core/image_delivery.dart` now asks Cloudinary for the
size actually being painted and caps the decode either way. Stored URLs are
never rewritten, so `isTrustedImageReference` is unaffected, and admin review
surfaces keep their full-resolution request — an admin judges evidence from
that image and there is no zoom viewer — taking only the decode bound.

`ListView(children: [Center(child: Column(...))])` gives the list a single
child, so nothing virtualises: all forty order cards and every listing were
laid out and painted every frame. The width constraint moved to the viewport
and the rows now build lazily.

Files: `core/image_delivery.dart` (new), 8 views, `test/core/image_delivery_test.dart`
and `test/performance_regression_test.dart` (new).

Checks: `flutter analyze` clean · `flutter test` 598 → **611**.

## 2026-08-26 09:32 (+06) — Wallet and donation audit, and a gap the disposal fix opened

Neither area had ever been audited. The wallet header rendered
`balance?.toString() ?? '0'`, so a newest ledger entry with no `balanceAfter`
showed a Champion with points a balance of **zero**, beside a ledger full of
credits — `ledgerBalanceProvider`'s own doc comment already promised a fallback
to `wallets/{uid}` and now has one. The donation screen stranded its receipt
the same way the eco-action form did. A suspended Greenpreneur could open the
listing editor and upload photos before the save was refused, though
`firestore.rules:860` requires `isActiveSeller()` to create a listing at all.

The gap: guarding `startForBin` on the bin changing — so re-scanning the same
bin stops destroying the photograph — also reused a *submitted* draft, marching
the user through photo and location to land on a receipt from ten minutes ago.
A submitted draft is now never reused, and both halves are pinned against each
other in `test/disposal_draft_reuse_test.dart`.

Files: `controllers/ledger_controller.dart`, `views/donations/donation_view.dart`,
`views/disposal/scan_view.dart`, `views/seller/seller_products_view.dart`,
`test/disposal_draft_reuse_test.dart` (new).

Checks: `flutter analyze` clean · `flutter test` 611 → **619**.

## 2026-08-24 19:15 (+06) — Fixed two navigation dead ends on the Champion path

"My appeals" and "My orders" were bare `Scaffold`s reached with `context.go`,
which replaces the stack — so no back button rendered and neither screen has a
navigation bar, leaving no way off either one. The orders case is on the
purchase path, straight from the checkout receipt. Both now sit inside
`AppShell`, which supplies its "Back to home" affordance exactly when there is
nothing to pop. Also corrected the README's local-run command, whose
copy-pasteable block gave the Android-emulator address to every target.

Files: `views/appeals/appeals_view.dart`, `views/orders/buyer_orders_view.dart`,
`core/api_config.dart`, `services/server_warmup.dart`, `README.md`,
`test/core/api_config_test.dart` (new).

Checks: `flutter analyze` clean · `flutter test` 567 → **576**.

## 2026-08-24 18:40 (+06) — Greenpreneur sales report, and web fixes

Added a sales report for the 3ZERO Greenpreneur — order value, cash collected,
simulated payments and amounts still to collect, over today / 7 / 30 / 90 days
and all time — as a new `Sales` tab and a home card. Figures are deliberately
split rather than summed: nothing in this system ever pays a seller, and the
prototype online methods move no money, so a single "received" total would be
partly fictional. Also fixed a listing-editor save that reported success as
failure when the page had been refreshed, and gave the form keyboard navigation.

Files: `core/sales_report.dart`, `controllers/sales_report_controller.dart`,
`views/seller/seller_sales_view.dart` (new); `order_service.dart`,
`constants.dart`, `router.dart`, `app_shell.dart`, `home_view.dart`,
`product_edit_view.dart`, `order_card.dart`; two new test files.

Checks: `flutter analyze` clean · `flutter test` 525 → **567** ·
`flutter build web` succeeds.

## 2026-08-24 17:20 (+06) — UI/UX pass: layout, contrast, and dead ends

Fixed usability and correctness defects the suite did not cover: two layout
overflows that hit at the default text size, error snackbars rendered at 1.70:1
contrast, and dead ends in the scanner, checkout, the Greenpreneur destinations
and Android back. Remaining leads, and the five areas the audit did not reach,
are in `UX_AUDIT_OUTSTANDING.md`.

Files: 22 modified, 3 added (`views/shared/app_snackbar.dart`,
`views/shared/unsaved_changes.dart`, `test/ux_hardening_test.dart`).

Also fixed a `ListTile` assertion caught on device: the appeal evidence card
wrapped its `CheckboxListTile` in an opaque `DecoratedBox`, hiding the tile's ink
splashes, so the confirmation an admin must tick gave no press feedback.

Checks: `flutter analyze` clean · `flutter test` 496 → **525** ·
`flutter build web` succeeds.

## 2026-08-24 12:52 (+06) — Internal audit of `5b1b779`: fixed seven defects

Read the whole trust boundary — `server/src`, `firestore.rules`, `lib/` —
looking for defects rather than working against someone else's list. The payout
path was sound: nothing found could mint points, escalate privilege, or let a
client write a balance. The one finding with a user-visible consequence was the
weekly claim quota, which always displayed as unused because the client parsed a
wire key the server has never sent. Full write-up in `AUDIT_2026-08-24.md`.

Files: `lib/services/claim_service.dart`, `lib/core/product_taxonomy.dart`,
`lib/core/validators.dart`, `server/src/award.js`, four views
(`seller_products`, `product_detail`, `admin_appeals`, `appeal_form`),
`seller_application_view`, `rejection_reason_dialog`, `checkout_view`,
plus `AUDIT_2026-08-24.md` and three test files.

Checks: `flutter analyze` clean · `flutter test` 482 → **496** ·
`npm test --prefix server` 279 · `rules_test` 222 · `flutter build web` succeeds.

---

## 2026-08-24 07:30 (+06) — Admin UX upgrade

Added the admin to-do list and today's review workload, reworked the appeals
review screen, and gave the points-policy editor its provenance. *(backfilled —
`5b1b779`)*

## 2026-08-23 21:05 (+06) — Polished app shell, authentication, marketplace discovery, filters, and product counts

*(backfilled — `745930a`)*

## 2026-08-23 14:13 (+06) — Implemented the prototype online payment system for orders and green-initiative donations

Simulation only: no credentials collected, no processor contacted, receipts
permanently labelled `SIM-`. *(backfilled — `222bceb`)*

## 2026-08-23 03:25 (+06) — Added an explicit QR layout boundary and accessibility

*(backfilled — `a7fccbb`)*

## 2026-08-23 03:11 (+06) — Improved navigation, responsive layouts, messaging, validation, pending-application handling, and account isolation; documentation updated

*(backfilled — `7335941`)*

## 2026-08-20 12:31 (+06) — Two iOS files updated

*(backfilled — `9b4feeb`)*
