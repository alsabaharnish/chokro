# Outstanding UI/UX findings — updated 2026-08-26

## What happened to the previous version of this file

The 2026-08-24 edition listed 44 findings from six of eleven planned areas of
`lib/`, and opened by admitting that **its verification stage never ran** —
every entry was a lead with a file and a line, not a confirmed defect, and it
estimated that roughly one in ten would dissolve on contact with the code.

That stage has now run, and the file has been rewritten around the result.

**All 44 leads were read against the real source.** 43 were confirmed or partly
confirmed and are fixed; 1 dissolved (`market-buyer-9` — the catalogue search
field's Search key does work). Two of the doc's own *suggested fixes* were also
wrong and would have shipped new bugs had they been applied as written:

- comparing bins by `BinModel.id` to decide whether to restart a disposal draft
  — `id` is null for an unwritten bin, so null-to-null compares equal and the
  reset is skipped in exactly the case that needs it;
- clearing the cached photo upload on the `clearPhoto` flag — the retake path
  sets `photoBytes` *without* that flag, so a stale upload receipt would have
  survived a retake and attached the previous photograph's URL to the new
  declaration.

Both corrections are recorded in comments at the sites where they were made.

**The five areas that had never been audited at all** — `admin-queues`,
`admin-config`, `wallet-donations`, `seller` and the cross-cutting
`shared-core` sweep — have now been. They produced 75 findings, which is worse
than the six areas that had already been looked at: **15 high severity**, 39
medium, 21 low.

All 15 high-severity findings are fixed. See `commits_m.md` for what they were;
the ones worth knowing about are a sign-out that could not complete offline, an
appeal review gate that leaked between appeals, a listing save that wrote stale
stock over the server's decrements, a donation retry that could debit twice, and
a redemption ratio the app accepted but would not honour.

## What is left

Everything below is a **medium or low severity finding that has been verified
against the code but not yet fixed**. Unlike the previous edition of this file,
these are not unread leads: each was produced by a pass that opened the named
file and quoted the code it is about. They are ordered by severity, then by
file.

Three areas of the audit did not complete and are still owed: the
`firestore-cost`, `render-cost` and `state-lifecycle` performance lanes hit a
usage limit before running. A performance pass was done by hand instead and is
described in `commits_m.md` (image decode bounds, list virtualisation, hoisted
per-build work), but it was not the systematic sweep those lanes would have
been. Anything they would have found is still unfound.

## Medium severity

### The dashboard's Accounts section renders confident zeros while the account stream is loading or has failed

**lib/controllers/dashboard_controller.dart:50** · bug

On every cold open of the dashboard the Accounts section shows "Accounts 0 / Counted live, not a counter", "3ZERO Greenpreneurs 0", "0 Champions, 0 3ZERO Admins", "Cannot act 0" until the users stream arrives — and if that stream errors, those zeros are permanent with no error message and no retry. The tile's own subtitle asserts the figure is counted live, and `_ProvenanceNote` (395-406) repeats the claim, so an operator has every reason to believe the platform has no accounts and nobody is suspended. Nothing on screen distinguishes "zero" from "not loaded", which is exactly the distinction `_rate` (240-243) was written to preserve for the other counters.

*Suggested:* Change `accountTotalsProvider` to `Provider.autoDispose<AsyncValue<AccountTotals>>` (or expose `allUsersProvider`'s AsyncValue alongside it) and render the Accounts `_StatGrid` through `.when`: `ContentLoading(label: 'Counting accounts…')` while loading and `ErrorRetry(error: e, title: 'Account totals', onRetry: () => ref.invalidate(allUsersProvider))` on failure — the same treatment the counters above already get.

### Notification permission is asked for with no context and has no denial path anywhere in the app

**lib/controllers/push_controller.dart:100** · ux

The prompt appears the instant the home screen loads, before the user has seen anything that would justify it — the most likely moment to reflexively decline. After that, F7.1 decision notifications silently never arrive, forever, with nothing in the app that says notifications are off or offers a way to turn them on. The user concludes the app doesn't notify.

*Suggested:* The codebase already has both halves of the pattern: `LocationService.openSettings()` (location_service.dart:155) for the permanently-denied case, and `NoticeCard` with a `NoticeAction` for stating a condition plus its one remedy. Expose the outcome as a provider (`pushPermissionProvider`) set by `_sync`, and render `NoticeCard(tone: NoticeTone.info, icon: Icons.notifications_off_outlined, message: 'Decision notifications are turned off for Chokro. Your history still shows every outcome.', action: NoticeAction(label: 'Open settings', onPressed: …))` on the profile screen.

### "Log another eco-action" silently navigates to Home for every Admin and Greenpreneur

**lib/routing/router.dart:358** · ux

A visible, enabled, primary control does nothing except move the user to Home with no message. The user cannot discover that the fix is to switch workspace, because nothing says so.

*Suggested:* Follow app_shell.dart:178-188's rule — 'Say why, rather than bouncing'. In `ClaimHistoryView`, watch `activeAccountProfileProvider` and when it is not `champion` replace the button's action with `showAccountProfilePicker(context, ref)` under a label naming the requirement ('Switch to 3ZERO Champion to log an action'), the same switcher app_shell.dart:280 already opens.

### The fulfilment queue silently drops the oldest orders past 40, and the open-orders banner undercounts with them

**lib/services/order_service.dart:65** · bug

The cap discards the *oldest* orders, which are exactly the ones a seller has not fulfilled. Past 40 orders, an unshipped order silently leaves the queue for good: it is not in the list, it is not in the banner count, and there is no control anywhere that can reach it. A Champion's order is never shipped and the seller has no way to discover it exists — while the sales report, two taps away, goes out of its way to warn about a truncation that costs nobody anything.

*Suggested:* Give the fulfilment list the same honesty the report already has. Read one past the cap and carry the fact, mirroring `watchSellerOrdersForReport` (order_service.dart:88-102): return a `SellerOrderPage`, and render a `_Caveat`-style note at the top of `seller_orders_view` when `truncated` — "Showing your 40 most recent orders. Older ones are not listed." Better still for this screen, sort open orders ahead of closed ones before applying the cap client-side, so the cap can only ever drop orders with nothing left to do.

### The ledger stops at 50 entries with no disclosure and no way to load older ones

**lib/services/transaction_service.dart:25** · ux

An active Champion - disposals at 50 points each, eco-action claims, purchases, redemptions, donations - passes 50 ledger entries within months. From then on the wallet silently shows only the newest 50 with no indication anything is missing and no route to older history, which is precisely the NFR-4 property the screen's own header comment claims to make visible ('the balance is reconstructable from history'). The '+N earned across the entries below' line (wallet_ledger_view.dart:124-126) also becomes a partial figure presented without qualification.

*Suggested:* Mirror the approved-claims idiom. Add `class LedgerLimit extends Notifier<int> { int build() => QueryLimits.ledger; void loadOlder() => state += QueryLimits.ledger; }` in ledger_controller.dart, have ledgerProvider watch it and pass it as the service limit, and append an `OutlinedButton.icon(icon: Icon(Icons.expand_more), label: Text('Load older activity'))` to the ListView children when `entries.length >= limit` - the same shape as admin_claims_view.dart:238-247. Also point TransactionService at QueryLimits.ledger instead of the literal 50.

### The account list is capped at 200 unordered documents, and both the count and the search silently lie about it

**lib/services/user_service.dart:84** · bug

Past 200 accounts, an admin who searches for the user they were asked to suspend gets "No accounts match." for an account that exists and is perfectly readable — with nothing on screen suggesting the list is partial. The header confidently reads "200 of 200", and the dashboard reports the platform has exactly 200 accounts. Because there is no ordering, which 200 survive is arbitrary and changes as documents are added. This codebase already treats silent truncation as a defect: `QueryLimits.salesReport` carries a `SellerSalesReport.truncated` flag so "the figures are never quietly partial" (constants.dart:92-94), and the admin nav badges render `50+` for capped queues (app_shell.dart:481-491).

*Suggested:* Add `orderBy('name')` so the cap is deterministic, and carry the cap to the screen: expose `truncated: docs.length >= QueryLimits.accounts` the way `SellerSalesReport.truncated` does, then have `_FilterBar` read `'$visibleCount of 200+'` and render a note above the list when truncated. Since search is the operation that actually breaks, back the search field with a server-side `where('email', isEqualTo: query)` lookup when the list is truncated and the query looks like an address, rather than filtering a partial snapshot.

### The appeal queue's notice states a capped count as a total

**lib/views/admin/admin_appeals_view.dart:449** · copy

With more than 50 pending appeals the notice asserts "50 waiting, oldest first" while the Appeals icon in the same shell shows "50+". The admin works through ten appeals and the count stays at 50, which reads as a stuck screen rather than a deep backlog. The disposal queue is the same shape with no count at all, so its truncation is entirely invisible.

*Suggested:* Pass the cap through and word it honestly: `_QueueNotice(count: appeals.length, atCap: appeals.length >= QueryLimits.reviewQueue)` rendering `'At least $count waiting, oldest first.'` when capped. Do the same for the disposal queue, which today shows no count, and for the claims tab badge (`_TabLabel(count: pending.value?.length)`, admin_claims_view.dart:59).

### The appeal queue builds all 50 cards and all 50 full-size evidence photos eagerly

**lib/views/admin/admin_appeals_view.dart:50** · perf

Opening Appeals with a full queue fires 50 concurrent Firestore document reads and 50 concurrent downloads of full-resolution evidence photographs, decoding each at up to 1600 px — on the order of half a gigabyte of image cache. On a mid-range Android handset that is a multi-second freeze on open followed by stutter or an out-of-memory kill; on the web build it is 50 parallel requests before the first card is readable. The disposal queue with the same content opens instantly because it builds lazily.

*Suggested:* Move the `Center`/`ConstrainedBox` inside the item builder and use `ListView.builder` with `itemCount: appeals.length + 1` (index 0 rendering `_QueueNotice`), exactly as admin_disposals_view.dart:83-95 does. That also fixes the widget-identity problem in the first finding when combined with `key: ValueKey(appeal.id)`.

### Bin form skips the range checks that already exist, so bad coordinates and radii cost a 90-second round trip to discover

**lib/views/admin/admin_bins_view.dart:164** · bug

An admin correcting a bin from a desk types a longitude of 190, or a radius of 0, or 5000 m for an open compound. The button says 'Registering…', the SlowServerNote appears after five seconds, and up to ninety seconds later — because this call inherits `ApiConfig.coldStartTimeout` — they finally get 'Longitude is out of range.' It is the same sentence `BinModel.validate()` would have produced instantly. On a cold Render instance that is a minute and a half per typo, on a screen the brief describes as used standing at a bin.

*Suggested:* Build the candidate and validate it locally before the request, keeping the existing `_problems` rendering: after parsing, `final candidate = BinModel(label: _label.text.trim(), lat: lat ?? 0, lng: lng ?? 0, radiusMeters: radius ?? 0, qrPayload: 'pending', createdBy: 'pending', active: true); local.addAll(candidate.validate().where((p) => !p.startsWith('QR payload') && !p.startsWith('Creating')));` — or lift the five geometry checks out of `BinModel.validate()` into a shared helper both call. Add the one rule the client copy is missing, `if (_label.text.trim().length > 120) 'Bin label may not exceed 120 characters.'`, so client and server agree exactly.

### Close/Reopen on a bin card has no in-flight state: no feedback for up to 90 seconds, and rapid taps race

**lib/views/admin/admin_bins_view.dart:686** · bug

The admin taps 'Close' on a bin. The label still says 'Close', the icon is unchanged, no spinner appears, nothing at all happens for up to ninety seconds on a cold Render instance. They tap again, and again, firing three POSTs. If they conclude it is broken and tap 'Reopen' after the row finally flips, the two in-flight requests land in an order the client does not control, so the bin's final state can be the opposite of the last button they pressed — and a bin left open when the admin believes they closed it keeps accepting scans and paying out.

*Suggested:* Track the in-flight bin id in the state (`String? _togglingBinId;`), set it in `_toggle` before the await and clear it in a `finally`, then pass it down: `_BinCard(..., busy: _togglingBinId == bin.id, ...)` and render `TextButton(onPressed: busy ? null : onToggle, child: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : Text(bin.active ? 'Close' : 'Reopen'))`, matching the register button's pattern two hundred lines above.

### Bins list error branch has no retry, stranding the screen on a stream failure

**lib/views/admin/admin_bins_view.dart:428** · ux

When the bins stream errors — a stale token producing permission-denied, a dropped connection, a missing index — the admin gets a sentence telling them to 'try again' and no control that tries again. The 'Print all labels' button also disappears (it is gated on `bins != null`), so the entire lower half of the screen is dead. The only recovery is to navigate away and back, and the message does not say so. The wording is also fixed text that never reflects the actual cause, so permission-denied reads as a connection problem.

*Suggested:* Swap in the shared widget: `error: (error, _) => ErrorRetry(title: 'Bins', error: error, onRetry: () => ref.invalidate(allBinsProvider))`, and add the import. It routes the message through `friendlyErrorMessage`, which distinguishes permission-denied from unavailable. While there, the `loading:` branch above it is a bare `CircularProgressIndicator` — `ContentLoading(label: 'Loading bins…')` is the idiom.

### Latitude and longitude inputs are too narrow to show a coordinate at 320 dp, because the radius box is a fixed 110 px

**lib/views/admin/admin_bins_view.dart:520** · responsive

On a 320 dp handset at the default text size — and on any phone once the OS text size is raised — the admin cannot see the coordinate they captured or typed: the latitude field shows about four characters of '23.78080' and scrolls the rest out of view, so there is no way to eyeball a mistyped digit before registering a geofence that every future disposal at that bin is measured against. At 2.0× the 'Radius' label alone (~100 dp at 32 sp) exceeds the 78 dp of usable width inside its fixed box and is clipped.

*Suggested:* Stop competing for one line below a breakpoint. Wrap the row in `LayoutBuilder` and, when `constraints.maxWidth < 420` (or when `MediaQuery.textScalerOf(context).scale(16) > 20`), emit the three fields stacked with `AppTheme.gapSm` between them — the enclosing widget is already a `Column(crossAxisAlignment: CrossAxisAlignment.stretch)`, so it is a straight swap of children. Otherwise keep the row but give the radius `Expanded(flex: 1)` against `flex: 2` for each coordinate instead of the hard-coded `SizedBox(width: 110)`.

### A bin-registration timeout tells the admin to retry without warning that the bin may already exist

**lib/views/admin/admin_bins_view.dart:208** · ux

The admin's registration times out, the message invites them to retry, they retry, and a second bin is created at the same coordinates with a different QR payload. Two labels get printed and attached, `resolveByPayload` resolves each to a different document, and the daily cap and per-bin lockout (`lockouts/{uid}_{binId}`) are keyed per bin — so a resident can scan one code, get locked out of that bin, walk one step and scan the other for a second award from the same spot.

*Suggested:* Distinguish the timeout in the catch and point the admin at the live list already on the screen: `final timedOut = error.problems.isEmpty && error.message == slowServerMessage; _problems = timedOut ? [error.message, 'The bin may still have been created. Check "Registered bins" below before registering it again.'] : (error.problems.isEmpty ? [error.message] : error.problems);` — `allBinsProvider` is a live stream, so a bin created after the deadline appears there without a refresh. Import `slowServerMessage` from `core/network_errors.dart`.

### The eco-action queue reports failures in the same neutral snackbar as successes

**lib/views/admin/admin_claims_view.dart:34** · ux

The 409 messages the server writes for an administrator are surfaced verbatim — "That submission has already been decided (approved).", "This user has reached their weekly limit of 2 approved eco-actions." (server/src/index.js:456-460). Presented in the same neutral pill as "Approved — 50 points credited.", with no icon and no colour, a statement about a quota reads as information rather than as "your approval did not happen." The admin moves to the next card believing the claim was decided when it is still pending.

*Suggested:* Replace the listener body with the disposal queue's: `final notify = AppSnackBar.of(context); if (next.error != null) { notify.failure(next.error!); } else if (next.lastMessage != null) { notify.success(next.lastMessage!); }`, keeping the existing `clearMessages()` call.

### "Verification is still running" is a permanent dead end that the admin cannot clear

**lib/views/admin/admin_disposals_view.dart:254** · ux

A stranded submission sits at the top of the oldest-first queue forever, showing a spinner for a process that is not running and copy promising evidence that will never arrive. The admin cannot approve it and cannot retry it; the only exit is rejecting a submission that may be entirely legitimate, which costs the user their points and their bin lockout. Every subsequent visit to the queue shows the same row still "running", so the queue never reaches zero.

*Suggested:* Distinguish the two states using `disposal.createdAt`, which the card already reads at line 204. Within a couple of minutes of submission keep the current copy. Beyond that, drop the `CircularProgressIndicator`, say what is true — "Verification never completed. Only the submitter can retry it from their history, so this cannot be approved." — and keep Reject available. Better still, add an admin-callable re-verify: `verifyDisposal` already takes `callerUid`, so allow `callerUid === disposal.userId || isAdmin` in server/src/verify.js and surface a "Run verification" `OutlinedButton` on the card.

### The dashboard to-do list renders capped queue counts as exact totals, ignoring the `badgeLabel` written for it

**lib/views/admin/admin_todo_list.dart:186** · bug

With a 300-item disposal backlog the home card says "50 waiting" and the header says "150 remaining", while the nav rail six inches away shows "50+" on the same queue — two contradictory numbers for the same thing on one screen. The count never falls as the admin works through the first 50, so the card reads as broken, and there is no hint that older work exists behind the cap.

*Suggested:* Use the accessor that already exists: `label: '${progress.badgeLabel} waiting'`, and the same in the Semantics string with words rather than a `+` glyph (`'${progress.atCap ? "at least " : ""}${progress.pending} waiting'`), matching `_DestinationIcon`'s handling at app_shell.dart:483-491. For the header pill, render `'${workload.pendingTotal}+ remaining'` when any queue is at cap.

### Account actions report failure in a neutral snackbar, using copy written for a read failure

**lib/views/admin/admin_users_view.dart:186** · ux

A suspension that the rules refuse — an account whose stored `name` is shorter than two characters, or whose `profilePhotoUrl` does not match the strict per-uid Cloudinary pattern `validUser` re-checks — produces a neutral grey bar telling the admin they lack permission to *view* something. Nothing has been suspended, nothing says so, and the advice offered (sign out and back in) does not touch the actual cause. Combined with the missing in-flight state above, the admin has no reliable signal at all about whether the action landed.

*Suggested:* Use `AppSnackBar.of(context)` captured before the await, `notify.failure('$name was not suspended. ${friendlyErrorMessage(error)}')` in the catch and `notify.success(message.toString())` on the clean path (keeping `notify.failure` for the partial-sweep case, which is a failure the current code shows as a success). Separately, `friendlyErrorMessage`'s `permission-denied` copy should not say "view" when the caller is a write path — either add a `verb` parameter or make the wording neutral ("That change was refused.").

### The suspension dialog never says it will hide the seller's entire catalogue or revoke another admin's access

**lib/views/admin/admin_users_view.dart:77** · ux

An admin picking "7 days" to pause a user for a disputed submission takes a Greenpreneur's entire shop offline for a week without being told in advance — a consequence for the seller's customers, not just the seller. Suspending a colleague's admin account, which the list permits and styles no differently from suspending a Champion, locks them out of every queue and the accounts screen itself with no warning at the moment of decision.

*Suggested:* Make the dialog state the consequences it is confirming: when `user.isSeller`, add a line "Their listings will be hidden from the shop while this lasts, and restored when you reinstate them."; when `user.isAdmin`, add "This is a 3ZERO Admin. Suspending them revokes every administrative privilege until reinstated." Both read from `user` which `_suspend` already holds. Add an explicit `SimpleDialogOption('Cancel')` so the dialog has a labelled exit rather than only the barrier.

### Points policy editor discards unsaved edits on back with no prompt, while the guard for exactly this already exists

**lib/views/admin/points_policy_view.dart:158** · ux

An admin retunes several policy numbers, gets pulled away, and back-swipes or taps the app-bar back arrow out of reflex. Every edit is gone with no dialog, no snackbar and no draft — and because the values look plausible either way, they may not notice which of their changes survived. The pending-changes panel that was on screen a moment ago is the only record, and it is gone too.

*Suggested:* Wrap the returned `AppShell` in the existing guard: `return UnsavedChangesGuard(hasChanges: changes.isNotEmpty || parseErrors.isNotEmpty, child: AppShell(...))`. Because `changes`/`parseErrors` are computed inside `_buildForm`, either hoist that computation into `build` or arm the guard from a small `bool get _isDirty => _loaded != null && policyFields.any((f) => (_controllers[f.key]?.text.trim() ?? '') != '${f.read(_loaded!)}');` so it stays disarmed on an untouched form.

### Policy save can sit on "Saving…" for ninety seconds with no explanation, while the sibling screen explains the same wait

**lib/views/admin/points_policy_view.dart:282** · ux

The admin confirms an economy change and the button says 'Saving…'. On a cold Render instance it says that for up to ninety seconds with no further signal. Believing it hung, they back out of the screen — losing the edit, since the form is not guarded — or force-quit, without ever learning whether the write landed.

*Suggested:* Add the existing inline note directly under the button row, exactly as the bin screen does: `if (_saving) const SlowServerNote(),` after the `Row` at line 293. `SlowServerNote` renders nothing for the first five seconds, so a fast save is unaffected.

### A Champion with fewer than 10 points gets a screen with every control dead and no explanation

**lib/views/donations/donation_view.dart:437** · ux

A brand-new Champion, whose wallet is created holding zero (firestore.rules:430-444), taps 'Support green initiatives' on the home screen and lands on a page where the chips, the button and effectively the form are all greyed out with no sentence explaining why or what to do about it. It reads as broken rather than as 'earn some points first'.

*Suggested:* In _PointEditor's data branch, when `balance < _DonationViewState._minimum`, return a ContentEmpty instead of the editor - the shape already used one branch above for the wallet-load failure (370-377): `ContentEmpty(icon: Icons.stars_outlined, title: 'Not enough points yet', message: 'Point donations start at 10 points and you have $balance. Dispose verified waste or log an eco-action to earn some.', actionLabel: 'Dispose waste', onAction: ...)` routing to /dispose/scan.

### The prototype payment reference is shown once, cannot be copied, and is unreachable afterwards

**lib/views/donations/donation_view.dart:658** · ux

The app presents the Champion with a reference number, implying it matters, and then makes it impossible to copy, re-read, or look up. A user who wants to note it has to retype it from the screen before navigating, and one back gesture destroys it.

*Suggested:* Give _SuccessLayout an optional trailing widget slot and pass the reference through it as a SelectableText next to an IconButton(tooltip: 'Copy reference', onPressed: () => Clipboard.setData(ClipboardData(text: outcome.paymentReference))) - the exact pattern at admin_bins_view.dart:795-825. Then say plainly on the same screen that a prototype donation is not recorded in the wallet, so the reference is the only record.

### Save is not disabled during a photo upload, so the listing publishes without the photo

**lib/views/seller/product_edit_view.dart:397** · bug

The seller picks a photograph, sees the small spinner in the 110 dp tile, and taps "Publish listing" while it is still going. The listing is written with `imageUrls: []`, the editor pops, and the upload lands on an unmounted widget. The photograph is in Cloudinary, paid for, referenced by nothing — the file's own header calls this out as the abandoned-form trade — and the published listing has no picture. The seller has to reopen the editor and add it again, never having been told why it was missing.

*Suggested:* Make the button agree with the field that already got it right: `onPressed: _saving || _uploading ? null : () => _save(existing)`, and give the label the reason so a disabled button is not a mystery — `label: Text(_uploading ? 'Waiting for the photo…' : _saving ? 'Saving…' : _isNew ? 'Publish listing' : 'Save changes')`.

### The photo upload has the same unexplained cold-start wait, in a 110 dp tile

**lib/views/seller/product_edit_view.dart:653** · ux

The seller picks their first photograph after a quiet period and watches a tiny spinner in a thumbnail slot for up to a minute. Nothing distinguishes it from a hung upload. They tap around, leave the form — and the guard's own message warns that an abandoned listing leaves the photograph uploaded and orphaned, which is precisely what happens.

*Suggested:* `_PhotoStrip` already ends in a column of explanatory captions; add `if (uploading) const SlowServerNote()` after the existing caption at line 690-695. It renders nothing until the wait becomes surprising, and its default text is the standard `ContentLoading.serverWakingHint`.

### Price and stock validation errors are cut off mid-sentence on a normal phone

**lib/views/seller/product_edit_view.dart:318** · a11y

On the most common Android width, at the default text size, a seller who leaves the price blank is told "Enter a price in whole ta…". The Stock helper — 'Zero is allowed', the one line that stops a seller deleting a listing rather than setting it to nothing — reads as "Zero is allow…" from about 1.4× text scale. The form's whole premise, stated in its header comment, is that a seller is told what is wrong rather than being handed a permission denial; here it tells them most of it.

*Suggested:* Set both on the shared theme so every side-by-side field in the app is covered at once: add `errorMaxLines: 2, helperMaxLines: 2` to the `InputDecorationTheme` at `lib/core/theme.dart:176`. If a narrower change is preferred, add the same two arguments to the two `InputDecoration`s at lines 316 and 338.

### The order advance button waits up to 90 seconds on a cold-start host with no explanation

**lib/views/seller/seller_orders_view.dart:172** · ux

The first fulfilment of the day hits a sleeping server. "Updating…" sits there for a minute with nothing else on screen. Long before it returns, the seller concludes the app is broken, force-closes it or navigates away — and never learns whether the order was marked shipped, because the only way to check is the same screen they abandoned.

*Suggested:* Render the shared note under the button while `_busy`, exactly as `declare_view.dart:294` does: wrap the `FilledButton.icon` in a `Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [button, if (_busy) const SlowServerNote()])`. It draws nothing for the first five seconds, so a fast response is unaffected.

### A failed delist or relist tells the seller they lack permission to *view* the listing

**lib/views/seller/seller_products_view.dart:213** · copy

When a suspension lands while the console is open — the rules resolve status per request, so the write can be refused a moment before the router redirects — the seller taps "Take off the shop" and is told they cannot view their own listing and should sign out and back in. Signing out and back in changes nothing, because the cause is the account status, which is the one thing the message never mentions. The right sentence already exists thirty lines away in another file.

*Suggested:* Reuse the interpretation the editor already wrote. Lift `_saveFailureMessage` out of `_ProductEditViewState` into a small top-level helper (it takes only an `Object error`) and call it from both sites, so a rules refusal on a product write says the same thing wherever the seller triggers it. Route the result through `AppSnackBar.of(context).failure(...)` while you are there, so the two branches of `_setActive` stop being visually identical.

### The sales period chips are clipped and sit below the minimum touch target

**lib/views/seller/seller_sales_view.dart:165** · a11y

At the default text size the period selector — the control the whole report hangs off — is a 44 dp row on a phone, under the 48 dp target the rest of the app guarantees, so it is easy to miss. From roughly 1.8× text scale upward the chips' bottom edge and part of their label are cut off by the ListView clip, so a seller who has enlarged text reads "Last 3 mont" with the border sliced through it.

*Suggested:* Drop the fixed box and let the chips size themselves, using the reasoning already written into `_SettlementGrid`: replace the `SizedBox`/`ListView.separated` with `Wrap(spacing: AppTheme.gapSm, runSpacing: AppTheme.gapSm, children: [for (final period in SalesPeriod.values) ChoiceChip(label: Text(period.label), selected: period == selected, onSelected: (_) => select(period))])`. Five short labels wrap onto two rows on a 320 dp phone and grow with the text scale instead of being clipped.

### Every submission failure is reported as a connection problem, including "already pending"

**lib/views/seller_application/seller_application_view.dart:54** · copy

An applicant whose second submission is refused because one is already under review is told their connection is at fault. They retry on a different network, retry on mobile data, and keep getting the same sentence — while the real answer ("you already have one in the queue") was raised, caught and thrown away. The same wrong sentence covers a rules refusal and an expired session.

*Suggested:* Interpret the error rather than guessing: `snack.failure(friendlyErrorMessage(error))` — `StateError.toString()` starts with "Bad state: ", so give the controller a small `SellerApplicationException` carrying the message (the pattern `ProductException`/`OrderException`/`ClaimException` already follow, all of which `friendlyErrorMessage` passes through verbatim at network_errors.dart:97-104), and keep the connection wording only for the branches that really are transport failures.

### The Greenpreneur application has no unsaved-changes guard, though it is one of the three forms the guard was written for

**lib/views/seller_application/seller_application_view.dart:195** · ux

The applicant writes a business name and a description with a 20-character minimum — the one substantial piece of prose a Champion writes in this app — then swipes back or hits browser back by reflex. The State is disposed, both controllers go with it, and there is no draft anywhere. They must retype the whole thing, and nothing warned them.

*Suggested:* Wrap the returned `AppShell` in `UnsavedChangesGuard` the way `product_edit_view._scaffold` does: rebuild the guard on keystrokes with `ListenableBuilder(listenable: Listenable.merge([_businessNameController, _descriptionController]), builder: (context, shell) => UnsavedChangesGuard(hasChanges: _businessNameController.text.trim().isNotEmpty || _descriptionController.text.trim().isNotEmpty, title: 'Discard this application?', message: 'What you have written has not been sent, and leaving now loses it.', child: shell!), child: <the AppShell>)`. Arm it only while the form branch is showing, so the "under review" state does not interrogate anyone.

### Android back exits the app from screens reached with go() that aren't nav destinations

**lib/views/shared/app_shell.dart:244** · ux

A Champion who has just paid taps 'View my orders' and then swipes back — Chokro closes. Same after filing an appeal. The AppBar's 'Back to home' leading (app_shell.dart:264-269) covers the on-screen case, so the app is not strandable, but the platform back gesture violates the Android convention the surrounding code deliberately implements everywhere else.

*Suggested:* Drop the conjunct: `final interceptBack = location != '/home' && !canPop;`. A pushed screen still has something to pop (`canPop` true) and is unaffected; `/home` still exits, as intended.

### Both review dialogs put a multi-line autofocused TextField in a non-scrollable AlertDialog

**lib/views/shared/rejection_reason_dialog.dart:95** · responsive

This is the dialog every rejection in the app passes through — disposals, eco-action claims and seller applications. On a phone with the keyboard up, and on any device above roughly 1.3x text scale, the content overflows its bounded box: the helper text that counts down the remaining characters, and in the appeals dialog the Uphold/Decline buttons' explanation, are clipped off-screen with no way to scroll to them. The admin sees a disabled submit button and the one line that explains why is the line that got cut.

*Suggested:* Wrap both dialogs' `content` in a `SingleChildScrollView`, matching admin_bins_view.dart:761. Consider dropping `autofocus: true` on small viewports, or set `scrollable: true` on the `AlertDialog` itself, which does the same job for the title and actions too.

### The wallet balance header is an unbounded Row and overflows at large text scale

**lib/views/wallet/wallet_ledger_view.dart:102** · responsive

A Champion using Android's largest font size, or iOS accessibility text sizes, opens the Wallet tab and the headline balance - the single number the screen exists to show - is cut off by the yellow-and-black overflow banner. The screen has no other copy of the figure except the per-row 'balance NNNN' labels.

*Suggested:* Wrap the number so it can shrink: `Flexible(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(...)))`, or switch the Row to a Wrap with `crossAxisAlignment: WrapCrossAlignment.end` so 'points' drops to a second line. Both cart_view.dart:255 and admin_claims_view.dart:188 already branch on `MediaQuery.textScalerOf(context).scale(1) > 1.3` for this class of reflow.


## Low severity

### The submitter's prior record goes stale after a decision, on the rows where it just changed

**lib/controllers/admin_review_controller.dart:42** · bug

A user with three pending submissions produces three cards sharing one cached record. The admin rejects the first for a bad photograph; the second and third still read the pre-decision summary (e.g. "12 approved, 0 rejected") — precisely the context that just changed, on precisely the decisions where it matters most. The record is wrong exactly when the doc says it must be right.

*Suggested:* Invalidate the family entry after each decision. Capture the submitter uid in the controller's `approve`/`reject` (or pass it from the card) and call `ref.invalidate(submitterRecordProvider(uid))` in the success branch, so the remaining cards for that user refetch.

### "Completed today" reads the earliest 250 reviews of the day platform-wide, then filters by admin

**lib/services/admin_workload_service.dart:54** · bug

Once the platform passes 250 decisions in a local day — plausible with several admins working parallel queues — every later decision falls outside the window. The admin's "done today" pill freezes mid-shift and stops counting their work, and `AdminTodoList._summary` reports a number that contradicts what they just did. With multiple admins the number is a share of a global cap rather than their own total, so it can be low from the start of the afternoon.

*Suggested:* Filter server-side rather than client-side: add `.where('reviewedBy', isEqualTo: adminUid)` and accept the four composite indexes, so the 250 cap applies to this admin's own decisions. If the indexes are genuinely unwanted, `.orderBy('reviewedAt', descending: true)` at least keeps the most recent work in the window instead of dropping it.

### Pressing Decline on an appeal shows the progress spinner on the Uphold button

**lib/views/admin/admin_appeals_view.dart:513** · ux

The admin taps Decline, and the button that starts spinning is the one they deliberately did not press. For the two or three seconds the Firestore write takes — longer on a poor connection — the screen reads as "Uphold in progress", which is the opposite decision from the one being recorded. Once the appeal resolves it leaves the queue, so there is no confirmation on screen to correct the impression beyond the snackbar.

*Suggested:* Track which outcome is in flight (`bool? _busyUphold`) and put the spinner on the pressed button: give the Decline button the same conditional icon keyed on `_busyUphold == false`, and the Uphold button on `_busyUphold == true`, disabling both while either is set.

### Bin form loses a typed label and a captured GPS fix on back, with no prompt

**lib/views/admin/admin_bins_view.dart:292** · ux

An admin standing at a bin taps 'Use my location', waits up to twenty seconds for a fix good enough to pass the accuracy check, types the label — then back-swipes by accident or to check something. Everything is gone, including the fix, and re-capturing means waiting for the GPS again on the street. The file's own header calls this flow mobile-first precisely because the fix is taken on site.

*Suggested:* Wrap the returned shell: `return UnsavedChangesGuard(hasChanges: _label.text.trim().isNotEmpty || _lat.text.trim().isNotEmpty || _lng.text.trim().isNotEmpty || _fix != null, child: AppShell(title: 'Bins', child: ...))`. The guard disarms itself on an untouched form, so opening the screen to browse the bin list is unaffected.

### "Copy payload" reports success without checking whether the copy happened

**lib/views/admin/admin_bins_view.dart:822** · bug

The admin copies a bin's payload to paste into a support ticket or a spreadsheet, reads 'Payload copied.', switches app, and pastes whatever was on the clipboard before. Because the confirmation was explicit, they have no reason to check, and the payload is the identifier support needs to trace a code that will not scan.

*Suggested:* Await it and report honestly, using the same `_run` helper the dialog already has for print and share: `onPressed: _busy ? null : () => _run(() async { await Clipboard.setData(ClipboardData(text: bin.qrPayload)); if (mounted) ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(const SnackBar(content: Text('Payload copied.'))); }, 'The payload could not be copied.')`. The `SelectableText` of the payload above (line 795) remains the manual fallback.

### Every bin row exposes an identically-labelled "Close" button to a screen reader

**lib/views/admin/admin_bins_view.dart:687** · a11y

A TalkBack or VoiceOver user swiping through a list of fifteen bins hears 'Close, button' fifteen times with the bin name announced as an unrelated earlier node, and cannot tell which bin the focused control belongs to. 'Close' also reads as dismiss-this-screen rather than take-this-bin-out-of-service, so the destructive reading of the control is the more natural one.

*Suggested:* Name the target on the control: `Semantics(button: true, label: bin.active ? 'Close ${bin.label}' : 'Reopen ${bin.label}', child: ExcludeSemantics(child: TextButton(onPressed: onToggle, child: Text(bin.active ? 'Close' : 'Reopen'))))`. Give the QR button the same treatment — `tooltip: 'Show and print QR code for ${bin.label}'`.

### "Print all labels" silently prints only some of the labels

**lib/views/admin/admin_bins_view.dart:416** · copy

An admin with eighteen bins, three of them closed, taps 'Print all labels', gets fifteen labels across four sheets and has no way to know whether three failed to render or were deliberately skipped. They count against the list, find the discrepancy, and re-check the print output. If they had wanted a replacement label for a bin they are about to reopen, the button gives them no path to it and never says why.

*Suggested:* State the rule in the control and the count in the outcome: label the button `'Print labels (${bins.where((b) => b.active).length})'` and add a `Tooltip(message: 'Open bins only. A label on a closed bin sends people on a wasted trip.')` around it, or put that sentence in the section subhead next to 'Registered bins'. The per-bin QR dialog already reachable from every row remains the way to print a single closed bin's label.

### Dashboard provenance note reads "an 3ZERO Admin"

**lib/views/admin/admin_dashboard_view.dart:401** · copy

The wrong article appears on a fresh deployment — which is exactly the state a first-run demo or a viva walkthrough is in — on the one paragraph on the dashboard whose job is to establish that the numbers are trustworthy. Two copies of the same sentence disagreeing is the kind of detail that undermines the claim it is making.

*Suggested:* Change `'an '` to `'a '` on line 400 so both branches read "a 3ZERO Admin included."

### An approve or reject can sit on a 90-second cold start with nothing but an unlabelled spinner

**lib/views/admin/admin_disposals_view.dart:265** · ux

The first decision of a shift routinely takes 30-60 seconds. The admin sees a silent spinner where the buttons were, with no indication whether the request is progressing, whether the app is frozen, or how long to wait. If the queue has been scrolled, the spinner is off-screen entirely and there is no indication anything is happening at all. The predictable response is to leave the screen or reload, at which point they have no idea whether the decision was recorded.

*Suggested:* Render `SlowServerNote()` beside the busy spinner on both cards so the "server is waking" line appears automatically after 5 seconds, and label the spinner ("Recording the decision…"). This is the same treatment the submission flow already gives its cold-start calls.

### The account list's empty result offers no way to undo the search or filter that produced it

**lib/views/admin/admin_users_view.dart:237** · ux

An admin filters to "Suspended", sees nothing, and is left with one unstyled sentence, a filter chip they may not connect to the result, and a search box with no clear button — on mobile they have to tap into the field and hold backspace. The screen gives no hint that the emptiness is caused by their own filters rather than by there being no such accounts.

*Suggested:* Replace with `ContentEmpty(icon: Icons.person_search_outlined, title: 'No accounts match', message: 'No account matches this search and filter.', actionLabel: 'Clear search and filter', onAction: () => setState(() { _search.clear(); _filter = _Filter.all; }))`, and add a `suffixIcon` clear button to the search field.

### Photocard export buttons are disabled with no stated reason until the anonymity checkbox is ticked

**lib/views/admin/eco_action_photocard_dialog.dart:366** · a11y

For an anonymous eco-action the admin arrives at three greyed-out buttons at the bottom of the dialog with no message explaining what to do. On a phone the checkbox may be scrolled out of view above the preview. A screen-reader user hears 'Save PNG, button, dimmed' with nothing saying which control unblocks it, and the only recourse is to explore the whole dialog again.

*Suggested:* Say it where the buttons are. Above the action `Wrap`, add `if (!privacyReady) Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 4), child: Text('Confirm the privacy check above to export this anonymous card.', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)))`, or use the shared `NoticeCard(icon: Icons.visibility_off_outlined, tone: NoticeTone.warning, message: ...)` from lib/views/shared/notice_card.dart, which is the idiom for a blocking condition with a stated remedy.

### Server rejection stays on screen after the admin has fixed the values that caused it

**lib/views/admin/points_policy_view.dart:255** · ux

After a rejected save, the admin corrects the offending number. The client-side 'These values are not allowed' block correctly disappears, but the red 'The server refused the write' block underneath it stays, listing the old complaint about the value they just changed. Three problem panels can be on screen at once with no way to tell which describe the current form, so the admin cannot tell whether it is safe to press Save.

*Suggested:* Clear it whenever the form changes. In `_PolicyInput`'s callback, `onChanged: () => setState(() { _serverProblems = const []; })`, and do the same in the Revert and 'Load section 7.3 defaults' handlers — the same three places that already `setState` on this screen.

### Failures across admin config are shown with the neutral SnackBar, indistinguishable from successes

**lib/views/admin/points_policy_view.dart:148** · ux

A policy write that the server refused and one that succeeded produce the same grey pill in the same place for the same four seconds. An admin who glances away reads any pill as confirmation. On the bins screen the same is true of a bin that failed to close — the row does not move either, so the neutral pill is the only signal and it looks exactly like the success pill.

*Suggested:* Replace the four raw call sites with the shared helper: capture `final notify = AppSnackBar.of(context);` before the await, then `notify.failure(error.message)` / `notify.success('Points policy updated.')` and, in admin_bins_view, `notify.info('${bin.label} closed.')` for the state change the user can already see and `notify.failure(...)` for the two failures. It also hides any queued bar, which the current calls do not.

### A too-large policy number is reported as "must be a whole number" when the admin plainly typed one

**lib/views/admin/points_policy_view.dart:81** · copy

An admin who leans on the keypad or pastes a stray figure into 'Disposal award' sees 'Disposal award must be a whole number.' next to a field containing nothing but digits. The message contradicts what is on screen and names no remedy, and Save stays disabled with no other explanation. An empty field produces the same sentence, which is also not what it means.

*Suggested:* Split the two cases and cap the input. Add `LengthLimitingTextInputFormatter(9)` alongside `digitsOnly` in `_PolicyInput`, and in `_readForm` distinguish them: `if (raw.isEmpty) { errors.add('${field.label} is required.'); continue; } final value = int.tryParse(raw); if (value == null) { errors.add('${field.label} is too large.'); continue; }`.

### Donation failures are never announced to a screen reader

**lib/views/donations/donation_view.dart:594** · a11y

A screen-reader user submits a donation, waits out the 90-second timeout, and hears nothing when it fails. The only change in the accessibility tree is the button label flipping from 'Donating...' back to 'Review donation' - which is indistinguishable from success - while the error text sits silently below the field.

*Suggested:* Wrap _DonationError's Container in `Semantics(liveRegion: true, container: true, child: ...)`, matching ContentLoading (content_state.dart:74-76), so the failure is spoken when it appears.

### Every listing's action menu announces itself identically to a screen reader

**lib/views/seller/seller_products_view.dart:166** · a11y

A seller using TalkBack or VoiceOver on a console of twenty listings hears "Listing actions, button" twenty times, with no way to tell which product each one belongs to except by swiping back to the title and counting. Delisting is destructive from the buyer's point of view, and this is the control that does it.

*Suggested:* Name the subject in the tooltip, which is what both the tooltip and the semantics label read from: `tooltip: 'Actions for ${product.title}'`. The `IconButton` in `_PhotoStrip` already follows this pattern with `tooltip: 'Remove photo'`; this one just needs the product.

### A Greenpreneur with no sales sees a wall of zeros instead of an empty state

**lib/views/seller/seller_sales_view.dart:45** · ux

A newly approved Greenpreneur opens Sales and gets a ৳0 headline, "Earned from 0 orders, after points discounts", four ৳0 tiles, a Volume block of zeros and a status list of zeros — a dense, confident-looking report of nothing. It reads as a broken screen rather than as "you have not sold anything yet", and offers no route to the thing that would change that.

*Suggested:* Branch on the underlying page rather than the period, so the selector is not hidden from a seller whose "Today" is merely empty: in `SellerSalesView.build`, when `ref.watch(sellerReportOrdersProvider).asData?.value.orders.isEmpty == true`, return `ContentEmpty(icon: Icons.query_stats_outlined, title: 'No sales yet', message: 'When a 3ZERO Champion buys one of your products, the order and its value appear here.', actionLabel: 'Go to your listings', onAction: () => context.go('/seller/products'))`.

### The application screen's loading branch renders nothing, so the form appears to be missing

**lib/views/seller_application/seller_application_view.dart:179** · ux

While `userApplicationsProvider` resolves — a first Firestore read on a cold connection — the screen shows the marketing card, the three benefit lines and then nothing. There is no form, no "under review" card and no spinner. A user who arrives during that window sees a page advertising Greenpreneur status with no way to apply for it, and no indication that anything is coming.

*Suggested:* Give the gate a visible state: replace the `SizedBox.shrink()` at lines 179-180 with `const Padding(padding: EdgeInsets.symmetric(vertical: AppTheme.gapXl), child: ContentLoading(label: 'Checking your applications…'))`, and drop the now-redundant blank `loading:` branch at line 135 so only one spinner appears.

### Pull-to-refresh on the wallet does nothing when the ledger is short, and is absent when it has failed

**lib/views/wallet/wallet_ledger_view.dart:48** · ux

A Champion whose disposal was just approved opens Wallet, sees 'Your wallet is ready', and pulls down repeatedly with nothing happening. The list is a live Firestore stream so the data is not actually stale - but an affordance that visibly does nothing reads as a broken screen.

*Suggested:* Add `physics: const AlwaysScrollableScrollPhysics(),` to the ListView at line 48 so a short list still accepts the overscroll. The ErrorRetry branch already carries its own retry button, so it needs no change.

