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

## 2026-09-08 17:25 (+06) — One bin QR now reaches the app or a browser submission

New bin labels encode an HTTPS `/b/{opaque-token}` entry instead of a token-only
barcode. Android and iOS are configured to claim that path after the hosted
association is verified; without the app, Firebase Hosting serves the same
Flutter flow. A first-time visitor is sent straight to the existing
name/email/password registration form, the auth gate retains the exact bin URL,
and successful registration returns to a resolved-bin screen rather than asking
for a second scan. Existing token-only labels remain readable inside the app.

Firestore continues to store the opaque token only, the QR URL exposes no
coordinates or user data, and web submissions use the same authenticated upload,
live-location radius, lockout, daily cap, duplicate detection, automated screen,
human-review fallback and server-only wallet mutation. Native forces a new camera
capture; web uses a file chooser and cannot prove that the chosen file was freshly
captured, so the interface and documentation state that assurance difference
plainly. Malformed tokens and lookalike hosts are rejected; closed and locked-out
bins cannot start a draft. PDF labels, the Admin QR dialog, copy text and
explanatory copy now agree on the public link.

Native association files are included for `chokro-30887.web.app`. The iOS file
uses the project's existing Team ID and bundle ID. Android authorises the local
debug certificate for device testing, and the current Gradle release is
debug-signed for local demos only. Play builds must list the Play App Signing
certificate—not the upload key—while directly distributed APKs need a production
signing key and its SHA-256. The Apple App ID and distribution profile must carry
Associated Domains. An unlisted Android build still receives the browser
fallback, so this limitation fails to a working website rather than a dead QR.

The project brief is now v3.3 with F2.13 and NFR-14, the README carries build and
release instructions, a dedicated integration note records the data and signing
boundaries, and the business brief is now v2.2 with the app/browser path in its
plain-language product explanation.

The web client opts into Flutter path routing so Firebase Hosting can preserve a
clean `/b/...` QR address, while startup migrates older `/#/...` bookmarks.
Cold native app-link URIs are normalized to an internal route before the auth
handoff, so first-time Android and iOS launches also retain the exact bin through
registration instead of falling back to the generic sign-in destination.
Production rollout still requires the Hosting deploy, the Hosting origin in the
trusted service's `ALLOWED_ORIGINS`, confirmed production Cloudinary credentials
and an authenticated upload smoke test, production native signing/provisioning,
and replacement of any token-only physical labels. Browser users see the
immediate decision or history; system push remains mobile-only.

Files: `lib/core/bin_link.dart`, `lib/services/bin_service.dart`,
`lib/controllers/scan_controller.dart`, `lib/core/bin_label_pdf.dart`,
`lib/views/admin/admin_bins_view.dart`,
`lib/views/disposal/bin_entry_view.dart`, `lib/routing/router.dart`,
`lib/main.dart`, `pubspec.yaml`, `lib/services/push_service.dart`,
`android/app/src/main/AndroidManifest.xml`, `ios/Runner/Runner.entitlements`,
`ios/Runner/Info.plist`, `ios/Runner.xcodeproj/project.pbxproj`,
`web/assetlinks.json`,
`web/apple-app-site-association`, `firebase.json`, QR/routing/native
configuration tests, `web/index.html`, `Chokro_Mobile_Project_Brief v3.md`, `README.md`,
`INTEGRATION_NOTES_QR_WEB_FALLBACK.md`, `INTEGRATION_NOTES_F7.1.md`,
`business/What-Chokro-Is.docx`.
Checks: `flutter analyze lib test` clean · `flutter test` 705 pass ·
`flutter build web` succeeds with both association files copied · final 24-page
business brief render visually inspected · Hosting emulator returns HTTP 200 for
the clean bin route and both `/.well-known` proofs with JSON content types.

## 2026-09-08 01:21 (+06) — SDG impact dashboard with honest reporting boundaries

The Admin dashboard now opens with a dedicated SDG impact view and retains the
operational platform data as a second tab, without adding another cramped mobile
navigation destination. It maps Chokro's recorded activity to SDG targets 8.3,
11.6, 12.5 and 13.3 while stating the important limit plainly: these are
operational signals, not official UN indicators or proof of environmental or
economic outcomes. Overlapping goal cards are therefore not summed, and the UI
does not invent kilograms diverted, emissions avoided, jobs or income.

The reporting path now distinguishes server-confirmed data from cached data and
labels the paginated account total as a bounded minimum when appropriate. A
missing stats document in a cold cache no longer flashes a false zero; stats and
account failures are isolated so one cannot hide the other or disable admin
shortcuts; temporary suspension totals expire on time without waiting for a
Firestore update; negative or malformed counters are clamped to zero; all
counters participate in activity detection; and the ambiguous `Sales value`
label is now `Order value placed`. Responsive card sizing, large-text behavior,
contrast, hover feedback and methodology disclosure were hardened as part of the
same pass.

The product brief is now v3.2 with feature F5.5 and NFR-13, the README documents
the two-tab flow, a field-level SDG integration note records provenance and claim
boundaries, and the business brief is now v2.1 with the same plain-language
methodology. No Firestore schema, rule or index migration is required.

Files: `lib/models/sdg_impact_model.dart`, `lib/models/stats_model.dart`,
`lib/core/label_format.dart`, `lib/services/stats_service.dart`,
`lib/services/user_service.dart`, `lib/controllers/dashboard_controller.dart`,
`lib/views/admin/admin_dashboard_view.dart`,
`lib/views/admin/sdg_dashboard.dart`, dashboard/model/format tests,
`Chokro_Mobile_Project_Brief v3.md`, `README.md`,
`INTEGRATION_NOTES_SDG_DASHBOARD.md`, `business/What-Chokro-Is.docx`.
Checks: `flutter analyze lib test` clean · `flutter test` 687 pass ·
`npm test --prefix server -- --runInBand` 308 pass · `flutter build web`
succeeds · final 24-page business brief render visually inspected.

## 2026-09-05 18:41 (+06) — iOS push notifications restored after an Xcode capability toggle

`aps-environment` had been stripped from `ios/Runner/Runner.entitlements` and
`com.apple.Push` from the target's `SystemCapabilities`, staged and ready to
commit. Without the entitlement the app cannot register with APNs, so
`firebase_messaging` never receives an APNS token, `getToken()` returns nothing,
and every path in F7.1 — award, rejection reason, appeal outcome — goes silently
undelivered on iOS while `push_service.dart`, `push_controller.dart` and
`server/src/push.js` all continue to behave as though it worked.

Read as accidental rather than intended, because the removal is exactly two
lines wide. `4081f7a` had turned iOS push on as one coordinated change —
entitlements file, `CODE_SIGN_ENTITLEMENTS` across all three configurations,
`APS_ENVIRONMENT` per configuration, `remote-notification` in `Info.plist`,
both capabilities, deployment target 15.0 — and added
`test/native_release_config_test.dart` in the same commit to hold every one of
them. What was removed is the pair Xcode itself deletes when the Push
Notifications capability is switched off in Signing & Capabilities, and nothing
else: the three `APS_ENVIRONMENT` settings now expanded into nothing,
`CODE_SIGN_ENTITLEMENTS` still pointed at an empty plist, `remote-notification`
was still declared, and the tripwire written alongside the capability was left
in place, failing. A decision to drop iOS push would have taken those with it.

Both lines restored; the files now match `4081f7a` exactly. Note for whoever
hits this again: the Push Notifications capability needs a paid Apple Developer
Program membership, and a personal team gets an automatic-signing fix-it
offering to disable it. That toggle is fine to make locally and must not be
staged — `native_release_config_test.dart` is what catches it.
Files: `ios/Runner/Runner.entitlements`, `ios/Runner.xcodeproj/project.pbxproj`.
Checks: `flutter test` 675 pass, 0 failures — clearing the pre-existing failure
recorded in the two entries below.

## 2026-09-05 18:27 (+06) — Registration could hang forever on a slow connection

`Create account` had no deadline on the half of registration that needs one.
Offline persistence is enabled app-wide, which makes `WriteBatch.commit()`
resolve on the server's acknowledgement rather than on the local write, so on a
connection that never delivers it neither returned nor threw. `signUp` awaits
it, so three things followed: the button spun indefinitely with no error; the
rollback in `signUp`'s `catch` never ran, leaving a Firebase account with no
profile; and `authControllerProvider` stayed `AsyncLoading`, which is the flag
`AppShell`, `StartupErrorView` and `AccountIncompleteView` all read to disable
their sign-out buttons — so a stalled registration locked every way out of the
account it had half-created. `push_service.dart` documents this exact trap for
an offline delete and bounds it; the registration path had been left unbounded.
The profile write and the rollback delete now both have deadlines, and a
timeout is reported as a message naming the step that timed out.

Separately, the router left `/register` the moment the Firebase account
existed — before the profile write it was waiting on. That disposed
`RegisterView`, taking the spinner and, in the failure branch, the `AppSnackBar`
that fires only `if (mounted)`: a slow registration that failed reported nothing
at all. Whether the user was then bounced to `/account-incomplete` or `/login`
depended on which of the listener and the write came back first. The gate now
distinguishes a profile that is missing because something broke from one that is
missing because it has not been written yet, and holds the form in place until
registration ends either way.
Files: `lib/services/user_service.dart`, `lib/controllers/auth_controller.dart`,
`lib/routing/router.dart`, `test/registration_stall_test.dart` (new).
Checks: `flutter analyze` clean · `flutter test` 674 pass, 1 pre-existing
failure in `native_release_config_test.dart` from the emptied
`Runner.entitlements` in the working tree (unrelated, as in the entry below).

## 2026-09-03 21:38 (+06) — Points no longer awarded for waste that never went in the bin

Screening now asks the two questions the disposal award actually rests on —
is a bin visible, and is the waste in it — and `decide()` flags `noBinVisible`
/ `wasteNotInBin` when the answer is not a clear yes, including when the model
does not answer at all. Previously a sharp photo of the declared waste held in
hand at the bin passed the geofence, the duplicate check, the type match and
the confidence threshold, so it auto-approved and paid out. Both flags are
advisory: an administrator can still approve a bin the model missed. Capture
guidance now asks for the photo the check requires, and the review queue shows
the screen's verdict beside the photograph.
Files: `server/src/screen.js`, `server/src/decide.js`, `server/src/verify.js`,
`server/src/award.js`, `lib/models/disposal_model.dart`,
`lib/views/disposal/photo_view.dart`, `lib/views/admin/admin_disposals_view.dart`,
server + Flutter tests.
Checks: `npm test --prefix server` 308 pass · `flutter analyze` clean ·
`flutter test` 666 pass, 1 pre-existing failure in
`native_release_config_test.dart` from the emptied `Runner.entitlements` in the
working tree (unrelated).

## 2026-09-01 21:30 (+06) — Listing images pinned to this project's Cloudinary account

`validProductImage` in `firestore.rules` matched the account segment of a
delivery URL as `[^/]+` — any Cloudinary account on the internet — while its own
comment claimed the URL "must name the authenticated seller's own upload folder
on the configured host". A seller could open a free Cloudinary account, upload
under the folder `chokro/products/<their own uid>/`, and publish a listing whose
bytes they kept control of: swappable after the listing had been seen, and
logging the address of every buyer who scrolled past it.

Nothing else caught this. A product document is written by the *client*
(`ProductService.create`), and unlike a disposal or claim photograph — which
`isTrustedImageReference` re-validates server-side, cloud name included, during
verification — the server never re-reads a listing's `imageUrls`. These rules
were the only check there was.

The account is now named once, in `cloudinaryCloud()`, and pinned in all three
provenance patterns (products, evidence, profile photos). The legitimate path is
unaffected: every URL the app stores comes from `photoUrl` in this service's own
upload response.

Release note: this couples the rules to one Cloudinary account, deliberately and
in a single place. It must equal the server's `CLOUDINARY_CLOUD_NAME`; if the two
disagree, listing photo writes fail with permission-denied while uploads keep
succeeding. Any historical listing whose images were served from a different
account would also become uneditable until its photographs are re-uploaded —
none exist today, since `.env` and the integration notes both name `ata3ir5d`.

Files: `firestore.rules`, `rules_test/*.js` (fixtures repointed)
Checks: 233 rules tests pass, up from 232 — the new one asserts a listing whose
image sits on `attacker-cloud` is refused, which the old pattern accepted.

## 2026-09-01 21:24 (+06) — The reward accent was invisible in the dark theme

`AppTheme.reward` was a single constant, `#E4A11B`, chosen against the balance
card's light-theme background. That card is painted with a `primary` ->
`lerp(primary, tertiary, .68)` gradient, and `primary` is a dark emerald
(`#156348`) in the light theme but a *light* mint (`#8dd5b3`) in the dark one —
so this is the one accent in the app whose backdrop gets lighter exactly where
every other surface gets darker. The amber measured 3.23:1 on the light theme's
emerald and **1.31:1** on the dark theme's mint: an effectively invisible
sparkle, sitting beside an `onPrimary` label that inverted correctly.

Now a brightness-aware `ColorScheme.reward`, alongside `success` and `warning`
in the same extension: `#F0B94A` light (4.04:1), `#6E4600` dark (4.84:1). The light
value is the `gold` the photocard export already uses, so the warm accent is one
tone across the product rather than two near-misses. The `AppTheme.reward`
constant stays for the photocard, which is fixed light paper and does not want a
theme-aware colour.

Files: `lib/core/theme.dart`, `lib/views/home/home_view.dart`,
`test/ux_hardening_test.dart`
Checks: 665 Flutter tests pass, up from 663. The two new ones measure the accent
against both gradient stops in both themes; reverting the constant fails the dark
case at the measured 1.31.

## 2026-09-01 21:12 (+06) — Rate limits on the eight endpoints that had none

`/whoami`, `/admin/ping`, `GET /claims/quota`, `GET /config/points`,
`POST /sellers/:uid/listings`, `POST /bins`, `POST /bins/:id/active` and
`POST /config/points` carried no limiter. Every authenticated request already
costs a `verifyIdToken(checkRevoked: true)` round trip to Google plus a
`users/{uid}` read before any handler runs, so an unlimited endpoint hands one
account an unbounded lever on this single free instance even where its own
handler is cheap — and `POST /sellers/:uid/listings` sweeps a seller's entire
catalogue.

The four writes take the existing `writeLimit`. The four reads take a new
`readLimit`
of 60/minute, set two orders of magnitude above what the app does: the policy is
fetched once per session and cached by `policySnapshotProvider`, and the claim
quota is read once before composing a claim. `/health` and `/photos/limits` stay
open — both are unauthenticated and constant-cost, and Render pings the former.

Files: `server/src/index.js`
Checks: 300 server tests pass.

Also added a `chokro-web-static` launch entry serving `build/web`, which is how
the release bundle was opened for the visual pass — `flutter run -d web-server`
never reaches first frame without the Dart Debug Extension, so it is not a usable
preview target here.

## 2026-09-01 21:04 (+06) — `unawaited_futures` was configured but never enabled

`analysis_options.yaml` promoted `unawaited_futures` to `warning` under
`analyzer: errors:`, with the comment "a dropped future is a silently swallowed
failure". That section only changes the severity of a diagnostic already being
produced, and the rule is in neither `flutter_lints` nor the
`lints/recommended.yaml` it includes — so the guard had never once fired. A probe
file with a plainly dropped future analysed clean.

Enabling it found four dropped futures, all deliberate: two
`SemanticsService.sendAnnouncement` calls that must not delay the auth call
behind them, and two `context.push` results neither caller uses. All four are now
`unawaited(...)`, which is what keeps the rule useful for the next one.

Files: `analysis_options.yaml`, `lib/views/auth/login_view.dart`,
`lib/views/auth/register_view.dart`, `lib/views/claims/claim_history_view.dart`,
`lib/views/seller/seller_products_view.dart`
Checks: `flutter analyze` clean with the rule live.

## 2026-08-26 11:47 (+06) — A launch config for the trusted service

Registering a bin failed with "Could not reach the server. It may be offline,
or it may be refusing requests from this address." The message was accurate and
the client code was correct: nothing was listening on `localhost:8787`, the
address the running web build was compiled against. `.claude/launch.json`
described only the hosting origin, so there was no configured way to start the
backend; it now carries a `chokro-server` entry running `npm run dev` from
`server/`. That script is the one that sets `ALLOW_LOOPBACK_ORIGINS=true`,
which matters because `flutter run -d chrome` takes a fresh random port each
launch and `ALLOWED_ORIGINS` names only `http://localhost:5000` — so a server
started with `npm start` would have refused the browser and produced the very
same sentence.

No application code changed.

Files: `.claude/launch.json`
Checks: `/health` 200; preflight `OPTIONS /bins` from the app's live origin
`http://localhost:64129` returns 204 with a matching
`Access-Control-Allow-Origin`; `POST /bins` reaches the handler and returns
401 `unauthenticated` instead of failing to connect.

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
