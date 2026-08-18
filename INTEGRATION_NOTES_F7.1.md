# Integration notes — F7.1, push notification on a decision

Per §9 of the brief: files added or changed, wiring required, import assumptions,
the surface exposed, and what went wrong while building it. Written to be
defensible under questioning.

---

## What F7.1 actually requires

> **F7.1** | Push notification on a decision (FCM) | Mobile | M2

And the M2 exit criterion it sits inside:

> scan a printed QR → declare count → photo → GPS → submit → auto-approved →
> balance increases → ledger shows a `disposal`-sourced entry → **push received**

So: four decision points must notify — a disposal auto-approved, a disposal
approved by an administrator, a disposal rejected, and the two claim outcomes.
Five in total.

---

## Files

**Added (5)**

| File | Purpose |
|---|---|
| `server/src/push.js` | Message composition, token lookup, send, dead-token pruning |
| `server/test/push.test.js` | 18 pure unit tests over the composers |
| `lib/services/push_service.dart` | Permission, token registration, incoming streams |
| `lib/controllers/push_controller.dart` | Keeps the token in step with the session |
| `rules_test/devices.rules.test.js` | 15 rules tests over the new subcollection |

**Changed (7)**

| File | Change |
|---|---|
| `firestore.rules` | New `users/{uid}/devices/{token}` block. Nothing existing modified |
| `server/src/firebase.js` | `messaging()` accessor + export |
| `server/src/award.js` | Notify after `approveDisposal` / `rejectDisposal` commit |
| `server/src/claims.js` | Notify after `approveClaim` / `rejectClaim` commit |
| `lib/main.dart` | Background handler, messenger key, foreground banner, tap routing |
| `lib/controllers/auth_controller.dart` | Retire the token before `signOut` |
| `android/app/src/main/AndroidManifest.xml` | `POST_NOTIFICATIONS` |
| `pubspec.yaml` | `firebase_messaging` |

No server dependency changes — `firebase-admin ^13.0.2` already ships messaging.

---

## The three decisions worth defending

### 1. Tokens live in a subcollection, not a field on the user document

`users/{uid}/devices/{token}`.

The obvious alternative was `fcmTokens: []` on the user document. It would have
meant widening this rule:

```javascript
allow update: if (isSelf(uid)
    && request.resource.data.diff(resource.data).affectedKeys().hasOnly(['name']))
```

That `hasOnly(['name'])` is the tightest rule in the file and the one that stops
a user writing their own `role`. Adding a second permitted key to it to store a
push token is a poor trade — the rule's value comes from being exactly one key
long.

A subcollection sidesteps it entirely: under `rules_version = '2'`,
`match /users/{uid}` does **not** cover subcollections, so the new block is
purely additive and the `users` rule is byte-for-byte unchanged.

It is also the better data shape. One person has several devices; the token
rotates; FCM reports dead tokens individually and they have to be deleted
individually. All one-document operations in a subcollection, all array surgery
on a field.

**The token is the document ID.** Registration is therefore idempotent — app
start and `onTokenRefresh` both write, and the same token lands on the same
document instead of accumulating a duplicate on every launch.

### 2. The send fires *after* the transaction, never inside it

```javascript
const result = await firestore.runTransaction(async (txn) => { … });
await pushModule.notifyDisposalApproved({ … });
return result;
```

Two separate reasons, both load-bearing.

**Firestore retries a transaction body on contention.** A send inside one fires
once per attempt, so a user could receive three copies of "50 points added" for
a single approval. The wallet write is idempotent under retry because Firestore
only commits one attempt; an HTTP call to FCM is not.

**A push must never cost an award.** By the time the notify line runs, the
balance is credited and the ledger entry written. If FCM is down, the token is
dead, or the user declined the permission prompt, the award still stands and the
submission history (F7.2) still shows it. Every function in `push.js` swallows
its own failures and returns a summary rather than throwing — the same
"fail toward the safe outcome" discipline as `screen.js`, which returns `null`
so the pipeline can route to review. Here the safe outcome is *the award stands,
the phone stayed quiet.*

**The hook lives in the decision functions, not the route handlers.** There are
five decision paths across three files. Putting the call inside
`approveDisposal` / `rejectDisposal` / `approveClaim` / `rejectClaim` covers all
of them — including auto-approval, which reaches `approveDisposal` through
`verifyDisposal` and so needs no edit in `verify.js` at all — and makes
"one decision, one notification" an invariant of the function that decides,
rather than a convention four route handlers have to remember.

### 3. Foreground messages are an in-app banner, not a tray notification

Android deliberately does not raise a tray notification for a message carrying a
`notification` block while the app is in the foreground. That is correct
behaviour — a system notification for something the user is already looking at
is noise — but it means *nothing appears at all* unless the app draws it.

The usual answer is `flutter_local_notifications`. That would be a whole
dependency whose only job here is to duplicate, in the tray, a message the user
can already see on screen. A `SnackBar` with a **View** action is the right
weight, costs nothing, and is better UX.

The messenger key lives on `MaterialApp.router` rather than inside `AppShell`
because the four disposal step screens build a bare `Scaffold` and sit outside
the shell — so there is no single subtree that covers every screen a
notification could land on.

---

## Wiring and import assumptions

- `push_controller.dart` imports `firebaseAuthStateProvider` from
  `auth_controller.dart`, and `auth_controller.dart` imports
  `pushServiceProvider` from `push_controller.dart`. **Dart permits this cycle**
  (unlike a cycle in `part` files), and both imports are `show`-scoped so the
  intent is visible. If you would rather avoid it, move `pushServiceProvider`
  into its own two-line file.
- `main.dart` now imports `controllers/push_controller.dart` and
  `services/push_service.dart`. It also gains `firebase_messaging` for the
  background-handler signature.
- `push.js` requires `./firebase` only. No cycle: `award.js → push.js → firebase.js`.
- **No `dart:io` was added.** `push_service.dart` uses `kIsWeb` and
  `defaultTargetPlatform` from `package:flutter/foundation.dart`. Given that
  twelve existing files already break the web build with unconditional
  `dart:io`, adding a thirteenth would have been careless.

---

## Surface exposed

**Dart**

| Symbol | Kind |
|---|---|
| `pushServiceProvider` | `Provider<PushService>` |
| `pushRegistrarProvider` | `Provider<PushRegistrar>` — read once in `main` for its effect |
| `pushMessageProvider` | `StreamProvider<RemoteMessage>` — foreground |
| `pushOpenedProvider` | `StreamProvider<RemoteMessage>` — tray tap |
| `routeForMessage(RemoteMessage)` | `String?`, allow-listed |
| `bannerTextFor(RemoteMessage)` | `String` |
| `PushService.isSupported` | `static bool` |

**Node** — `notifyDisposalApproved`, `notifyDisposalRejected`,
`notifyClaimApproved`, `notifyClaimRejected`, plus the pure composers for tests.
None of them throw.

**Firestore** — `users/{uid}/devices/{token}` → `{ platform, updatedAt }`.

**Message data payload** — `kind`, `status`, `pointsAwarded`, `route`. All
strings; FCM rejects the entire message otherwise, and it fails at send time on a
real device rather than in a test.

---

## Bugs and traps found while building this

**1. Deregistration cannot be driven by the uid going null.** My first version
had the registrar delete the token when the auth stream emitted null. It fails
silently: by then the session is gone, `isSelf(uid)` is false, and the rules
refuse the delete. The token survives on the device, and the next decision for
the *previous* account arrives on the phone of whoever signs in next — carrying a
rejection reason written for somebody else. Shared and borrowed phones are normal
in this project's setting, so that is a real disclosure. It has to happen
*before* `signOut`, which is why `AuthController.signOut` calls it directly.

**2. `hasOnly` bites the same way it bit `updateName`.** The reflex on a write
like this is to include a device name or an app version for debugging. With
`hasOnly(['platform', 'updatedAt'])` that fails with permission-denied, and the
failure reads like a rules misconfiguration rather than an extra key. Exactly the
trap already documented on `UserService.updateName`.

**3. `@pragma('vm:entry-point')` is not optional.** Without it the background
handler works in debug and is tree-shaken out of the release APK. The failure
mode is background notifications silently not arriving on the demo device — and
only on the release build.

**4. `rejectDisposal` and `rejectClaim` return no `userId`.** Adding one would
have been cleaner but `server/test/server.test.js` compares those objects
exactly, so the uid is captured into an outer variable inside the transaction
instead. Retry-safe: a retried body reassigns it, and the value left standing
belongs to the attempt that committed.

**5. Permission timing is a one-shot.** Android only ever raises the
`POST_NOTIFICATIONS` prompt once. Asking on first launch — before the user knows
what the app does — is the version most likely to be dismissed, and a reflexive
"no thanks" on the splash screen costs the feature permanently. It is raised on
first sign-in instead.

**6. A suspended user must still be notified.** Gating the devices rule on
`isActive()` was the reflex and it is wrong: the message a suspended user most
needs is the one explaining why something was rejected, and the appeal path
(F5.4) depends on them knowing a decision happened. There is an explicit test
named for this.

---

## Known limitations — state these in the term paper

1. **iOS is not configured.** FCM on iOS needs an APNs authentication key
   uploaded to the Firebase console. The `ios/` target exists but is not a
   delivery target for this project, and `PushService.isSupported` covers iOS
   only so the code is ready if that changes.
2. **Web push is not implemented.** It needs a VAPID key pair and a service
   worker. F7.1 is a Mobile-only row in §7, and the flow that generates most
   notifications is mobile-only anyway.
3. **No named notification channel.** Android groups these under FCM's fallback
   channel, labelled "Miscellaneous" in system settings. A named channel needs
   `flutter_local_notifications` — see decision 3 above for why that was not
   worth it. Cosmetic only.
4. **FCM delivery is best-effort, not guaranteed.** Google makes no delivery
   promise, especially to a dozing device. The submission history screen (F7.2)
   remains the source of truth and shows every decision regardless — which is
   why F7.1 being absent was survivable and why it must not now become the only
   way a user learns an outcome.
5. **An emulator without Google Play services yields no token.** `registerDevice`
   returns null and logs. Test on the physical device, the same lesson as §8's
   camera and GPS warning.
6. **At most 10 devices per user are notified**, most-recently-seen first. FCM's
   multicast ceiling is 500; 10 is a bound on stale tokens from reinstalls, and
   dead ones are pruned on send anyway.
7. **The push shares the review request's latency.** It is awaited (with an 8 s
   internal cap) rather than fired and forgotten, so a sleeping Render instance
   makes the administrator's approve button slower, not just the push. Warming
   `/health` before the demo covers this — it is already on the checklist for
   other reasons.
8. **Permission denial is final on Android.** A user who declines gets no
   notifications for the life of the install unless they change it in system
   settings. The app does not nag.

---

## Verification

```bash
# 1. Dependency
flutter pub add firebase_messaging

# 2. Pure logic — no emulator, no network
cd server && npm test          # 87 existing + 18 new = 105

# 3. Rules — emulator required
firebase emulators:start --only firestore
cd rules_test && npx jest devices.rules.test.js     # 15 new

# 4. Analyzer, clean before any device test
cd .. && dart analyze lib/

# 5. Deploy the rules — the client write fails until this lands
firebase deploy --only firestore:rules
```

**Then, on the physical device** — this is the part an emulator cannot prove:

1. Sign in. Confirm the `POST_NOTIFICATIONS` prompt appears (Android 13+), and
   that `users/{uid}/devices/{token}` exists in the console afterwards.
2. Submit a clean disposal. Expect **"Points added — Your disposal was approved
   automatically. 50 points added."** — this is the M2 exit criterion.
3. Background the app and have an administrator approve a queued submission from
   the web build. Expect a tray notification reading **"Verified — points
   added"**, and confirm tapping it opens `/history`.
4. Reject one with a reason. Confirm the reason is the notification body.
5. With the app open on the home screen, have an administrator decide something.
   Expect the in-app SnackBar with a **View** action, and **no** tray
   notification — that absence is correct, not a bug.
6. Sign out, sign in as a different user on the same phone, and have a decision
   made for the *first* account. Expect nothing to arrive. This is trap 1 above
   and it is the single most important manual check here.

---

## One follow-on worth doing

`ClaimHistoryList` already exists in `claim_submit_view.dart`, fully built, and
is never instantiated anywhere. Mounting it on a `/claims` route would take about
ten minutes and would give claim notifications a proper destination — right now
they route to `/wallet`, which shows the credit but not the decision or its
reason. It would also close the smaller gap that "My submissions" lists disposals
only.
