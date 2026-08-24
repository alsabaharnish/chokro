# Outstanding UI/UX findings — 2026-08-24

Reported by an audit of six of eleven planned areas of `lib/`. Everything here
was **read out of the code by the reporting pass but has not been independently
re-verified**, because the verification stage of that audit did not finish. Treat
each as a lead with a file and a line, not as a confirmed defect: the one finding
that *was* checked in detail and disproved is recorded at the bottom.

The findings that were confirmed and fixed are described in `commits_m.md`.

## Not audited at all

`admin-queues`, `admin-config`, `wallet-donations`, `seller`, and the
cross-cutting `shared-core` sweep never ran. That leaves the admin review
queues, the bins and points-policy consoles, the wallet ledger, the donation
screens and the Greenpreneur console without a pass.


## High severity as reported

### `claims-appeals-3` — Kept-alive draft strands the confirmation screen; /claims/new later opens with no form

**lib/controllers/claim_controller.dart:115** · bug

The primary path to logging an eco-action is broken for anyone who left the confirmation screen by the back button: it reports a stale claim as if it were just submitted and shows no form at all. It also pins the compressed photo bytes (`draft.photoBytes`) in memory for the rest of the session, since `keepAlive` prevents disposal.

*Suggested:* Do not let the terminal state persist across a route exit. In `ClaimSubmitView`, keep the same `keepAlive` for an in-progress draft but clear the completed one on the way out — the codebase's own idiom for this is a `reset()` call, so make `_ClaimSubmitted` a `ConsumerStatefulWidget` whose `dispose()` schedules `ref.read(claimDraftProvider.notifier).reset()`. Alternatively drop `submittedId` from `ClaimDraft` altogether and let local `_sent` state in a `ConsumerStatefulWidget` own the confirmation, the way `AppealFormView._sent` (appeal_form_view.dart:45) already does — that widget has exactly the same two-phase shape and does not suffer this bug.

### `market-buyer-3` — The checkout screen never consults unavailableCartItemsProvider — delisted lines vanish from the totals silently and short-stock lines are quoted, both refused by the server after payment is simulated

**lib/views/market/checkout_view.dart:48** · bug

The buyer commits to a total computed over a silently different basket, and — having already pressed "Simulate successful payment" — is rejected by the server with a message the checkout screen gives them no way to act on. In the all-delisted case the app contradicts itself outright: "Your cart is empty" beside a cart badge showing three items.

*Suggested:* Watch `unavailableCartItemsProvider` in `_CheckoutViewState.build` alongside the quote, and when it is non-empty render the block the cart screen already has instead of the body — reuse the same shape as `_ProblemsCard` (an `errorContainer` Card listing `problem.title — problem.reason`) with a `FilledButton` "Back to cart" via `context.go('/cart')`, and disable Place Order, mirroring the cart footer's `blocked ? null : ...`. Fix the `quote.isEmpty` copy at line 97 too: when the raw cart is non-empty but every line resolved away, it should say the listings were withdrawn, not "Your cart is empty".

### `home-profile-3` — Profile picker bottom sheet cannot scroll, clipping the third profile at large text

**lib/views/shared/account_profile_switcher.dart:129** · responsive

An admin or greenpreneur using accessibility text sizes cannot reach the last profile in the list, so they are locked out of the Champion workspace (shopping, donating, eco-actions) from either entry point. The picker is the only general way to switch.

*Suggested:* Wrap the `Column` in a `SingleChildScrollView` (or make it a `ListView(shrinkWrap: true)`), which is what `isScrollControlled: true` is there to enable; the theme's `bottomSheetTheme` already supplies the drag handle and rounded top.

### `home-profile-4` — Suspended Greenpreneur and Admin get dead navigation tabs that silently do nothing

**lib/views/shared/app_shell.dart:53** · ux

The most prominent control on the screen is inert with no explanation, directly contradicting the home cards that do explain themselves. The user taps repeatedly and concludes the app is broken rather than that their account is suspended.

*Suggested:* In `AppShell`, gate the destination list on the account state the same way home does — e.g. `final suspended = user != null && !user.isActive;` and fall back to the Champion destination set (all of which are `requireSignedIn`) when suspended, or keep the tabs and have `onSelect` show a SnackBar carrying the same "Unavailable while suspended." wording instead of a `go` that bounces.


## Medium severity as reported

### `claims-appeals-2` — "N claims left this week" counts approvals, but reads as submissions

**lib/services/claim_service.dart:238** · copy

On a submission form, "3 claims left this week" is read as "I may submit three more". The user submits five, is told each one is under review, and later receives two rejections they had no way to anticipate — the same surprise the class doc for `ClaimQuotaStatus.fromJson` (lines 206-217) says F6.4 exists to prevent.

*Suggested:* Say what the number actually counts, and name the reset the server already names. In `summary`, use `'$remaining more claim${remaining == 1 ? '' : 's'} can be approved this week.'` and, for the exhausted case, `'All $limit approved claims for this week are used. The count resets on Monday.'` Then drop the now-pointless `ref.invalidate(claimQuotaProvider)` at claim_controller.dart:218, or move it to where the quota can genuinely change.

### `claims-appeals-5` — A duplicate appeal is refused with a message that names the wrong two reasons

**lib/views/appeals/appeal_form_view.dart:190** · bug

The user is told they do not own their own rejected submission, or that it was not rejected — both false. They have no way to work out that the appeal already exists or where to read it, and the message gives no next step.

*Suggested:* Two changes. (a) Name the actual third condition in `_failureMessage`, since the rules enforce one appeal per subject: '...You can only appeal your own submissions, only ones that were rejected, and only once — if you already appealed this, the answer will appear on your appeals screen.' (b) Stop the button from lying while the stream is loading: change `appealedSubjectIdsProvider` to expose the loading state (e.g. a `Provider.autoDispose<Set<String>?>` returning `null` until `asData` is non-null) and, in `AppealButton`, render the `TextButton.icon` with `onPressed: null` while it is `null`, the same way the rest of the app declines to offer an action it cannot yet resolve.

### `claims-appeals-6` — A claim's rejection reason is joined into the subtitle with a middot, unlabelled

**lib/views/claims/claim_submit_view.dart:308** · ux

The single most important thing on that row — why it was refused and therefore what to change — is typographically indistinguishable from "3d ago". The same user reading the same information about a disposal gets a labelled, error-toned note. The claim also offers only "Appeal this decision" as a next step, while the appeal screen itself tells them the real remedy is to submit again (appeal_form_view.dart:109-112).

*Suggested:* Reuse what the disposal card already established. Drop the reason out of the joined subtitle (leave `userFacingStatus · formatAge` there) and render it below the `ListTile`, beside the existing `AppealButton` at lines 332-336, in the same shape as `submission_history_view.dart`'s `_Note`: an `Icons.info_outline` icon, `theme.colorScheme.error` tone, title "Why it was rejected", body `claim.rejectionReason!`. Add a second affordance next to the appeal button — an `OutlinedButton` "Log this again" that calls `ref.read(claimDraftProvider.notifier).reset()` then `context.push('/claims/new')` — so the remedy the appeal screen names is actually reachable from the rejection.

### `claims-appeals-8` — Quota banner can spin for 90 seconds unexplained, then dead-end with no retry

**lib/views/claims/claim_submit_view.dart:46** · ux

For a minute and a half the screen looks broken with no explanation, which the doc comment on `ContentLoading` (content_state.dart:17-22) identifies as the exact failure mode that scaffolding was written to fix. When it does fail, the user cannot re-check without leaving the screen and coming back, and a screen reader gets nothing at all from the unlabelled `LinearProgressIndicator`.

*Suggested:* Give the loading branch the standard slow-server treatment and the error branch a retry. Replace `loading: () => const LinearProgressIndicator()` with a `Column` holding the bar and `const SlowServerNote()`, and add to the error `_Notice` an inline `TextButton.icon(onPressed: () => ref.invalidate(claimQuotaProvider), icon: const Icon(Icons.refresh), label: const Text('Check again'))` — the same `ref.invalidate` retry this file already uses at line 281.

### `claims-appeals-10` — The "Sent for review" confirmation cannot scroll and overflows at large text sizes

**lib/views/claims/claim_submit_view.dart:220** · a11y

At accessibility text sizes the user who just submitted sees a yellow-and-black overflow stripe and, worse, the "Done" and "Log another" buttons are pushed off-screen with no way to scroll to them — the screen becomes unexitable except by the system back gesture, which is the very dead end the comment at lines 244-246 says this screen was fixed to avoid.

*Suggested:* Make the body scrollable the way the rest of the feature does. Wrap the `Center` in a `SingleChildScrollView` (or swap the whole hand-rolled column for the shared `ContentEmpty` from `views/shared/content_state.dart`, which already renders icon/title/message/action in the app's tokens — keeping "Done" as its `actionLabel`/`onAction` and putting "Log another" underneath). While there, replace the raw `EdgeInsets.all(32)` and `SizedBox(height: 16/8)` with `AppTheme.gapXl`/`gapMd`/`gapSm`, which the lower half of the same method already uses.

### `disposal-5` — Backing out to the scanner and tapping Continue silently discards a photo already taken for the same bin

**lib/views/disposal/scan_view.dart:76** · bug

A photo taken standing over a bin is destroyed with no warning and no undo, by a button labelled "Continue" that the user reasonably reads as "carry on where I was". They have to re-open the camera and re-shoot the same bag.

*Suggested:* Only restart the draft when the bin actually changed: `final current = ref.read(disposalDraftProvider).bin; if (current?.id != bin.id) { ref.read(disposalDraftProvider.notifier).startForBin(bin); }` before the push. That preserves the stated intent (a different bin clears the photo) without the collateral damage.

### `disposal-6` — Final submit shows a bare unlabelled spinner for up to 90 seconds, with no slow-server note

**lib/views/disposal/declare_view.dart:253** · ux

The single most important action in the app looks hung for a minute and a half, on the exact cold-start case the codebase documents as normal. The user who gives up and backs out loses the photo and the GPS fix and has to redo the flow at the bin.

*Suggested:* Match the two existing idioms: keep the `FilledButton.icon` mounted with `onPressed: draft.isSubmitting ? null : ...`, a 16 px `CircularProgressIndicator` as the icon and a `'Submitting…'` label while in flight, and add `if (draft.isSubmitting) const SlowServerNote()` directly beneath it.

### `disposal-7` — The "Checking your submission" screen offers no escape and no explanation for a 90-second wait

**lib/views/disposal/declare_view.dart:335** · ux

A screen the user cannot leave by any offered control, for a minute and a half, at the emotional peak of the flow. The one honest reassurance the system has ("it is saved either way — check your history") is written into `VerificationOutcome.pending`'s note but never shown during the wait.

*Suggested:* Add `const SlowServerNote(message: 'The server is taking a while. Your submission is already saved — you can check your history in a moment.')` to the `_verifying` branch, and offer a `TextButton` "See my submissions" during verification too (it calls `controller.reset()` and `context.go('/history')`, which is safe: the document already exists and the history stream shows the real outcome).

### `disposal-8` — A raw platform exception string is shown to the user in the location error card

**lib/services/location_service.dart:146** · ux

A resident standing at a bin is shown a Dart exception dump with no remedy, on a screen whose sibling failure modes all have carefully written sentences. Also a small information leak of internal plugin detail.

*Suggested:* Route it through the shared helper the flow already uses one screen earlier: `return LocationResult(outcome: LocationOutcome.error, message: friendlyErrorMessage(err));`, keeping the existing `text.toLowerCase().contains('time')` timeout reclassification above it. Import `../core/network_errors.dart`.

### `disposal-9` — Fix-accuracy warning uses a hardcoded 30 m instead of the codebase's radius-relative helper

**lib/services/location_service.dart:64** · bug

Case (a) sends users hunting for open sky when their fix is fine. Case (b) is the costly one: the user is told nothing is wrong, submits, and the reason their points did not arrive is invisible to them — the advice that would have prevented it was withheld by a threshold that ignores the bin.

*Suggested:* Judge it against the bin in `_FixResult`, using the tested helper: replace `lowAccuracy: location.isLowAccuracy` with `lowAccuracy: isFixTooRoughForRadius(accuracyMeters: location.accuracyMeters, radiusMeters: bin.radiusMeters)` (already in scope via the `core/geo.dart` import). Keep `LocationResult.isLowAccuracy` only if some radius-free caller needs it; nothing in `lib/` currently does.

### `disposal-10` — Item-count stepper is two unlabelled icon buttons around a bare number

**lib/views/disposal/declare_view.dart:130** · a11y

The one value the automated screen checks the photograph against — a count mismatch is `countMismatch`, which routes the submission to manual review — is set through controls that never say what they do. A misread here costs the user their auto-approval.

*Suggested:* Add `tooltip: 'One fewer item'` / `tooltip: 'One more item'` to the two `IconButton.filledTonal`s, and wrap the count in `Semantics(liveRegion: true, label: itemCount(draft.declaredItemCount), child: ExcludeSemantics(child: Text(...)))` — `itemCount` already exists in `core/label_format.dart` and yields "7 items".

### `market-buyer-4` — Cart quantity stepper's "+" stays enabled past CartItem.maxQty and then does nothing

**lib/views/market/cart_view.dart:220** · bug

An enabled control that reports no error and produces no change reads as a broken app rather than a limit, and the tooltip actively misinforms — it says "One more" at the exact point where one more is impossible. Each dead tap also costs a redundant Firestore write of the unchanged cart document.

*Suggested:* Clamp the ceiling handed to the stepper: `max: math.min(line.stock ?? line.qty, CartItem.maxQty)` (import `dart:math`, and `CartItem` from `models/cart_model.dart`). Then extend the tooltip so the disabled reason is truthful in both cases — `qty >= (line.stock ?? qty) ? 'No more in stock' : 'Most you can order is 20'`.

### `market-buyer-5` — A suspended Champion's cart offers a Checkout button that teleports them to Home and Remove buttons that fail as "you do not have permission to view this"

**lib/views/market/cart_view.dart:113** · ux

A suspended buyer gets two misleading dead ends on a screen that never mentions the one fact that explains both, while the product screen one tap away states it plainly.

*Suggested:* Watch `currentUserProvider` in `CartView.build` as `ProductDetailView` does, and when `!user.isActive` render the existing `_Notice` copy above the lines and pass `blocked: true` to `_CartFooter` with a label such as "Account suspended" — the footer already renders a disabled button with an explanatory label for the `blocked` case. Separately, since the cart is the only screen where a write denial is user-reachable, give `_runCartAction` a message fit for a write rather than falling through to the generic read wording.

### `market-buyer-6` — Every category tap and every debounced search blanks the whole catalogue to a full-page spinner

**lib/views/market/catalog_view.dart:118** · ux

Filtering feels like a page reload rather than a filter; on a slow connection the buyer loses their place and their scroll position on every refinement.

*Suggested:* Pass `skipLoadingOnReload: true` to the `catalogAsync.when(...)` call so the previous results stay on screen while the new query resolves, and put the in-flight signal somewhere non-destructive — the `TextField`'s existing suffix area, or a thin `LinearProgressIndicator` under the `Divider(height: 1)` at line 116.

### `auth-4` — The "New to Chokro?" / "Already a member?" footer Row overflows at large text

**lib/views/auth/login_view.dart:242** · responsive

The only link between the two auth screens is clipped and partially untappable for exactly the users who enlarge system text. A first-time user at Largest text cannot reliably reach registration from the sign-in screen — a dead end at the very first screen of the app.

*Suggested:* Swap the Row for the Wrap this file's own frame already uses: `Wrap(alignment: WrapAlignment.center, crossAxisAlignment: WrapCrossAlignment.center, children: [const Text('New to Chokro?'), TextButton(...)])`. Same change at register_view.dart:160.

### `auth-5` — Password validation error keeps saying "2 more characters" after the user types them

**lib/views/auth/register_view.dart:82** · ux

The form displays a factually wrong instruction about the text currently in the field, on the app's first-run screen. A user who follows it types two more characters than needed, or concludes the form is stuck and abandons registration. The helper text "At least six characters" (register_view.dart:128) is correct but is replaced by the stale error while it is showing.

*Suggested:* Add `autovalidateMode: AutovalidateMode.onUserInteraction` to the `Form` at register_view.dart:82 and login_view.dart:162. That re-runs the validators as the user types, but only after they have touched the field, so nothing turns red before the first submit.

### `auth-6` — The account-recovery screen's Try again and Sign out give no feedback and no error

**lib/views/shared/account_incomplete_view.dart:69** · ux

This is the app's designated escape hatch from a broken account — the screen written specifically so such a user is "not trapped". Both of its two buttons can fail silently, which returns the user to the trapped state the screen exists to end, with no evidence that anything was attempted. Repeated taps look like a frozen screen.

*Suggested:* Make both actions report. For retry, hold a local `_checking` flag and show `ContentLoading(label: 'Checking your account…')` (or swap the button label for a spinner) for a beat, then, if the gate has not moved on, show an errorContainer snackbar saying the profile is still missing — the same pattern lib/views/shared/error_retry.dart already encodes. For sign-out, `await` the call and, on `ref.read(authControllerProvider).error != null`, surface `friendlyErrorMessage(error)` in a snackbar. Apply the same to startup_error_view.dart:61-76.

### `auth-7` — The in-flight sign-in button announces nothing to a screen reader

**lib/views/auth/login_view.dart:231** · a11y

A blind user gets silence for the duration of the network call and cannot tell whether the tap registered. On a cold Render instance (network_errors.dart:38-40 documents 30–60 s wake times) that silence lasts up to a minute, and the natural response is to tap again.

*Suggested:* Give the in-flight state a name: `Semantics(label: 'Signing in…', liveRegion: true, child: const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)))`, and 'Creating your account…' at register_view.dart:151. Same idiom as `ContentLoading`'s `Semantics(liveRegion: true, label: widget.label, ...)`.

### `auth-8` — Sign-in uses the email autofill hint, so saved-password managers do not offer the stored login

**lib/views/auth/login_view.dart:171** · ux

The saving half works (registration hints correctly and calls `TextInput.finishAutofillContext()`), so the credential is in the manager — it just cannot be filled back in. Every returning sign-in becomes manual typing of an email and password on a phone, which is the single most common action in the app and the one most likely to produce the wrong-credentials error from auth-1.

*Suggested:* Hint the field as the credential's username, keeping the email keyboard: `autofillHints: const [AutofillHints.username, AutofillHints.email],` at login_view.dart:171. `keyboardType`, `textCapitalization` and `autocorrect` at lines 169-176 are already right and need no change.

### `auth-9` — "An account already exists — Sign in instead" gives the user no way to sign in

**lib/core/auth_errors.dart:58** · ux

The message states the remedy and withholds it. The user must dismiss the bar, scroll, find a small text link, and retype the email they just entered — and if they in fact forgot the password, the reset flow is another screen away. This is the single most common registration failure and the app's least-supported one.

*Suggested:* Attach the action the message promises: `SnackBar(..., action: SnackBarAction(label: 'Sign in', textColor: scheme.onErrorContainer, onPressed: () => context.go('/login')))` in register_view.dart's `_submit`, gated on `error is AuthFailure && error.code == 'email-already-in-use'` — `AuthFailure.code` is retained (auth_errors.dart:27-28) precisely so callers can branch without re-parsing the message.

### `home-profile-5` — Profile screen's "Become a 3ZERO Greenpreneur" stays enabled while suspended and throws the user off the screen

**lib/views/profile/profile_view.dart:228** · bug

The tap navigates to /home instead of the application form, so the user is silently ejected from the profile screen they were on, with no message saying why. Three controls on one screen disagree about the same suspension.

*Suggested:* Mirror the sibling donate button: `onPressed: user.isActive ? () => context.push('/apply-seller') : null`, and say why it is off — the home card's wording is "Unavailable while suspended."

### `home-profile-6` — A temporary suspension never lifts inside a running session

**lib/views/home/home_view.dart:52** · bug

A user whose timed suspension has expired is still locked out of every earning action, with the app telling them the suspension is still in force. Pull-to-refresh does not help, so the remedy is undiscoverable.

*Suggested:* Add a provider that re-evaluates on the boundary, mirroring the existing idiom in admin_workload_controller.dart:69-75: watch `currentUserProvider`, and when `suspendedUntil` is in the future do `final timer = Timer(until.difference(DateTime.now()), ref.invalidateSelf); ref.onDispose(timer.cancel);`. Have `HomeView` (and `ProfileView`) watch it so `user.isActive` is recomputed the moment the suspension lapses.

### `home-profile-7` — Profile screen's load error is a dead end with no retry

**lib/views/profile/profile_view.dart:107** · ux

The user is told to "try again" on a screen that provides no way to try again, and the real cause (say, permission-denied after a session change) is never surfaced.

*Suggested:* Replace the error branch with the shared widget: `error: (error, _) => ErrorRetry(error: error, title: 'Your profile', onRetry: () => ref.invalidate(currentUserProvider))` — the same call HomeView makes.

### `home-profile-8` — Greeting badge and points-balance label overflow at large text on a narrow phone

**lib/views/home/home_view.dart:478** · responsive

Overflow stripes across the top of the greeting hero and across the balance card — the two elements that set the tone of the screen — and the role label / "POINTS BALANCE" caption are clipped.

*Suggested:* Wrap the pill `Container` in `Flexible` and give the role `Text` `overflow: TextOverflow.ellipsis`; wrap the `'POINTS BALANCE'` `Text` in `Flexible` with the same overflow — matching what `_BalanceValue`'s number Row at line 692 already does.

### `shell-routing-3` — NavigationRail overflows and clips destinations on a phone held in landscape

**lib/views/shared/app_shell.dart:152** · responsive

Yellow-and-black overflow stripes in profile builds, a RenderFlex assertion in debug, and in release the bottom destinations ('Appeals', and part of 'Eco') are painted outside the rail and cannot be tapped. Rotating the phone loses navigation destinations. It bites hardest for the Admin, who has five destinations.

*Suggested:* Pass `scrollable: true` to the `NavigationRail` at app_shell.dart:245 — Flutter 3.44 supports it and it wraps the destination column in a `SingleChildScrollView`. Additionally make the breakpoint two-dimensional so a landscape phone keeps the bottom bar: `final isWide = constraints.maxWidth >= AppConstants.webBreakpoint && constraints.maxHeight >= 600;`, adding the height floor next to `webBreakpoint` in lib/core/constants.dart.

### `shell-routing-4` — Sign-out from the app bar shows no progress and never reports a failure

**lib/views/shared/app_shell.dart:341** · ux

The user confirms a deliberate, security-relevant action and gets zero acknowledgement. On a slow network they will tap the menu and confirm again (firing a second `signOut`); on a failure they are left believing they signed out on a device the codebase explicitly says is often shared or borrowed (push_service.dart:160-169).

*Suggested:* In `AppShell.build`, add `final isSigningOut = ref.watch(authControllerProvider).isLoading;` next to the other watches and disable the popup's sign-out entry while it is true, matching startup_error_view.dart:19. In `_confirmSignOut`, capture `final messenger = ScaffoldMessenger.of(context);` before the await and after it do `final error = ref.read(authControllerProvider).error; if (error != null) messenger.showSnackBar(SnackBar(content: Text('Could not sign out. $\{friendlyErrorMessage(error)}')));` — the same read-`.error`-after-await pattern login_view.dart:129 already uses. Apply the error half to startup_error_view.dart:71-75 and account_incomplete_view.dart:78-82 too.

### `shell-routing-5` — Admin nav badges silently cap at 50 and understate the real queue

**lib/views/shared/app_shell.dart:144** · ux

The badge is the admin's only at-a-glance measure of backlog and it is a hard-capped lie above 50. An admin working a 300-item queue sees the number never move, cannot tell whether they are making progress, and has no signal that items older than the fiftieth exist at all — which is precisely the denial-of-service scenario constants.dart:46-51 was written to make degrade visibly rather than invisibly.

*Suggested:* Have `AdminTaskProgress` carry the cap, e.g. add `final bool atCap;` set as `atCap: (pendingDisposals.value?.length ?? 0) >= QueryLimits.reviewQueue` in admin_workload_controller.dart, and in `_DestinationIcon` render `Badge(label: Text(atCap ? '$badge+' : '$badge'), child: Icon(icon))` instead of `Badge.count`. The queue screens should carry the same '+' or a one-line 'showing the oldest 50' note, in the idiom of admin_appeals_view.dart:429.


## Low severity as reported

### `claims-appeals-7` — Three different phrases for "waiting for a reviewer" across the Champion's own screens

**lib/models/claim_model.dart:221** · copy

Three labels for one state invites the reader to look for a distinction that does not exist — is "pending" a different stage from "awaiting"? — in exactly the flow where the user is already anxious about whether anything is happening.

*Suggested:* Pick the one that already reads best and is used on the most-visited screen, `'Waiting for review'`, and use it in all three: change `ClaimModel.userFacingStatus`'s `ClaimStatus.pending` case (claim_model.dart:221) and `AppealStatus.pending`'s `label` (appeal_model.dart:62) to match `status_chip.dart:32`. The two enums are the only definitions, so nothing else needs touching.

### `claims-appeals-9` — Server sends the per-claim award; the client parses it away and never tells the user what a claim is worth

**lib/services/claim_service.dart:219** · ux

The user is asked to photograph and submit something without being told what it earns, and "pays more" is a comparison against a figure they also do not have on this screen. `ClaimModel.creditedPoints` is only ever shown after approval (claim_submit_view.dart:319-325), so the number arrives days after the decision to bother.

*Suggested:* Add `final int claimAward;` to `ClaimQuotaStatus`, parse it in `fromJson` with `wireInt(json['claimAward']) ?? 0` (the same `wireInt` fallback the other two fields use), and surface it in the informational `_Notice` at claim_submit_view.dart:65-73: "An approved eco-action is worth ${q.claimAward} points. Every one is checked by a person, so points arrive after review…". Read it from the `data` branch only, leaving the existing wording as the fallback while the quota is loading or errored.

### `disposal-11` — Retrying a failed submit re-uploads the photograph, orphaning the first upload

**lib/controllers/disposal_controller.dart:365** · bug

Every retry leaves a permanently unreferenced image in the image host with no cleanup path, and burns one of the user's 40 hourly photo uploads. A user retrying through a flaky connection can trip their own rate limit and be told the photo could not be uploaded when nothing is wrong with it.

*Suggested:* Cache the successful upload on the draft and reuse it: add `final UploadedPhoto? uploadedPhoto;` to `DisposalDraft`, set it via `copyWith` immediately after `uploadDisposalPhoto` returns, and open `submit` with `final photo = draft.uploadedPhoto ?? await ref.read(photoUploadServiceProvider).uploadDisposalPhoto(photoBytes);`. Clear it wherever `clearPhoto` clears the byte fields, so a retake always re-uploads.

### `market-buyer-7` — The receipt never says the server applied fewer points than the buyer asked for — the helper written for it is called nowhere

**lib/views/market/checkout_view.dart:720** · ux

A buyer who redeemed the maximum sees a smaller discount than the screen quoted and is given no reason for it, contradicting a promise made three lines above the button.

*Suggested:* Keep the requested figure on the state — `int _pointsRequested = 0;` set in `_place` before the call — and pass it to `_Receipt`. Render a note under the "Points spent" row when `outcome.appliedLessThan(requested)`: something like "Prices changed while you were checking out, so fewer points could be spent than the ${requested} you chose. The rest are still in your balance." That gives `appliedLessThan` its one caller and makes the promise at line 244 true.

### `market-buyer-8` — "Empty your cart?" makes the destructive choice the visually primary button

**lib/views/market/cart_view.dart:140** · ux

Muscle memory for "the filled button is the safe one" empties a cart the buyer spent time building; nothing in the app can restore it.

*Suggested:* Style the confirm as destructive using the pattern already in `rejection_reason_dialog.dart`: `FilledButton(style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error, foregroundColor: Theme.of(context).colorScheme.onError), ...)`. Label it "Empty the cart" rather than "Empty" so the confirm button does not read identically to the app-bar button that opened the dialog.

### `market-buyer-9` — The catalogue search field's "Search" key does nothing

**lib/views/market/catalog_view.dart:206** · ux

The keyboard advertises an action that has no effect, and on a small phone the results the buyer just searched for stay hidden behind the keyboard.

*Suggested:* Thread an `onSubmitted` through `_SearchAndFilters` to the existing immediate path — `onSubmitted: (value) { _setQueryNow(value); FocusScope.of(context).unfocus(); }` on the state side, exposed on the widget as a `ValueChanged<String> onSubmitQuery` beside the `onQueryChanged` it already takes.

### `auth-10` — The wide-screen brand panel overflows vertically in a short browser window

**lib/views/shared/auth_frame.dart:192** · responsive

The deliberately-designed brand panel — the first impression on desktop — renders with a debug overflow stripe and its "Verified evidence / Auditable rewards / Circular marketplace" pills cut off, with no way to scroll to them. Cosmetic rather than blocking, since the form half still works, but it is the screen every desktop user sees first.

*Suggested:* Give the panel the same escape the form side has, using the tokens already in the file: wrap the Column in a `SingleChildScrollView` and replace the `Spacer` with `SizedBox(height: AppTheme.gapXl)` (a Spacer cannot live in a scrollable), or keep the Spacer and gate the panel on height as well as width — `final wide = constraints.maxWidth >= 900 && constraints.maxHeight >= 620;` at auth_frame.dart:30, which falls back to the already-scrollable phone layout.

### `auth-11` — validateEmail has no upper bound, but firestore.rules caps the stored email at 254

**lib/core/validators.dart:23** · bug

Rare in practice, but it is the exact failure mode validators.dart:45-60 was written to eliminate — a value the form accepts, the rules refuse, and a bare permission-denied that cannot name the field. It also leaves the client/rules contract that `TextLimits` documents incomplete, so the next person reading `TextLimits` believes every rules bound is mirrored there.

*Suggested:* Add `static const int emailMin = 3; static const int emailMax = 254;` to `TextLimits` with the same `users.email` doc line the other entries carry, and check it in `validateEmail`: after the pattern test, `if (email.length > TextLimits.emailMax) return 'Email addresses are limited to ${TextLimits.emailMax} characters';` — the same wording shape `validateName` already uses at validators.dart:90.

### `home-profile-9` — Suspension end shown as a bare date although the admin sets an exact time

**lib/views/home/home_view.dart:769** · copy

The notice reads as "you are free on the 26th" when the account is actually blocked until the evening, so the one number in the message is misleading on the day it matters.

*Suggested:* Use `formatDateTime(until)` in both notices, as `admin_users_view.dart:447` already does for the same field.

### `shell-routing-6` — PendingDestination drops the query string, so a restored /appeals/new loses its subject

**lib/routing/router.dart:344** · bug

The user is told their appeal was refused because it was not their own rejected submission, when in fact the app dropped the subject reference on reload. The stated reason sends them to check the wrong thing, and the real appeal is never filed.

*Suggested:* Remember the full location: `final location = state.matchedLocation;` stays for the `isSplash`/`isAuthRoute` comparisons, but the two `pending.remember(...)` calls at router.dart:369 and :376 should pass `state.uri.toString()`. `PendingDestination.consume()` already returns a location that goes back through GoRouter matching, so a query string round-trips safely. Separately, `AppealActions.raise` should reject an empty `subjectId` with an `AppealValidationException` rather than letting the rules answer for it.

### `shell-routing-7` — Signing out records the current screen, so the next person to sign in lands there

**lib/routing/router.dart:376** · bug

A new session opens on a screen the previous person chose rather than on Home, which is disorienting on a shared handset and contradicts the invariant the class doc claims to hold. No data crosses accounts — every provider is uid-scoped — but the app looks like it remembered the wrong user's place.

*Suggested:* Clear the pending destination when a session ends. The smallest change in this codebase's idiom is one line in `AuthController.signOut` (lib/controllers/auth_controller.dart:167), before `authService.signOut()`: `ref.read(pendingDestinationProvider).consume();`. Alternatively have `_AuthGateListenable` remember the previous gate and skip `pending.remember` in the `anonymous` branch when the previous gate was `signedIn`.

### `shell-routing-8` — The admin 'Eco' tab is a bare abbreviation, and the same concept has three names

**lib/views/shared/app_shell.dart:68** · copy

'Eco' is a one-word abbreviation with no established meaning in this product and is the only nav label that does not name what it opens. An admin cannot tell from the bar which queue it is, and the label-to-title jump ('Eco' → 'Claim review') makes it read like a mis-tap. The same concept appearing as 'Eco', 'Claim review' and 'Eco-actions' across three screens costs an admin the ability to talk about it consistently with a Champion.

*Suggested:* Rename the destination label to match the screen and the Champion-facing term: `ShellDestination('/admin/claims', Icons.eco_outlined, Icons.eco, 'Eco claims')`, and set admin_claims_view.dart:38 to `title: 'Eco-action claims'` so all three surfaces use the same noun. Consider the same for 'Disposals' → keep the label and retitle admin_disposals_view.dart:49 to 'Disposal review'.


## Disproved

`disposal-4` claimed the scanner had no app-lifecycle handling, so the camera
stayed live through steps 2–4 and did not resume after backgrounding. It does:
`mobile_scanner` 7.4.0's own `MobileScanner` widget is a `WidgetsBindingObserver`
with `useAppLifecycleState` defaulting to true, and it stops on `inactive` and
starts on `resumed`. Checked in
`~/.pub-cache/hosted/pub.dev/mobile_scanner-7.4.0/lib/src/mobile_scanner.dart:408`.

This is the reason the rest of the list is marked unverified — roughly one in ten
of these is likely to dissolve the same way on contact with the code.
