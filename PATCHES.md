# F7.1 — edits to existing files

Six existing files change. Each edit is small and shown in full context.

---

## 1. `firestore.rules` — add the devices subcollection

Insert this block **immediately after** the closing brace of `match /users/{uid} { … }`
and before the `wallets` block.

`match /users/{uid}` does **not** cover subcollections under `rules_version = '2'`,
so this is purely additive. The `users` rule itself — including the
`hasOnly(['name'])` self-update that stops a user promoting themselves — is not
touched.

```javascript
    // -------------------------------------------------------------------------
    // users/{uid}/devices — push tokens (F7.1)
    // -------------------------------------------------------------------------
    //
    // A subcollection rather than a field on the user document, and deliberately
    // so. The self-update rule above is `affectedKeys().hasOnly(['name'])` — the
    // tightest rule in this file and the one that stops a user writing their own
    // role. Adding `fcmTokens` to that list to hold an array would widen exactly
    // the rule that must never widen. A subcollection is invisible to it.
    //
    // The document ID is the FCM token itself, which makes registration
    // idempotent: app start and onTokenRefresh both write, and the same token
    // lands on the same document rather than accumulating duplicates.
    //
    // NOT gated on isActive(). A suspended user must still receive the
    // notification that tells them a submission was rejected — that message is
    // the one they most need, and withholding it would leave them refreshing a
    // screen for an answer that had already been decided.
    //
    // The server prunes dead tokens through the Admin SDK, which bypasses this
    // block entirely.
    match /users/{uid}/devices/{token} {
      // Only the owner. An administrator has no reason to enumerate someone's
      // devices, and a token is a capability — least privilege applies.
      allow read: if isSelf(uid);

      // Exact key set, same discipline as `disposals` and `claims`. There is no
      // server-owned field here to protect, but an unbounded document under a
      // user's own control is a place for one to appear later.
      allow create, update: if isSelf(uid)
        && request.resource.data.keys().hasOnly(['platform', 'updatedAt'])
        && request.resource.data.keys().hasAll(['platform', 'updatedAt'])
        && request.resource.data.platform in ['android', 'ios', 'web']
        // Server timestamp only, matching every other timestamp in this file.
        && request.resource.data.updatedAt == request.time;

      // A user retires their own token at sign-out. This must happen *before*
      // signOut completes — afterwards isSelf(uid) is false and the delete is
      // refused, stranding the token so the next decision for this account would
      // notify whoever signs in on the phone next.
      allow delete: if isSelf(uid);
    }
```

---

## 2. `server/src/firebase.js` — expose messaging

Add the accessor next to `db()`, `auth()` and `bucket()`:

```javascript
/**
 * Firebase Cloud Messaging (F7.1).
 *
 * The send side is server-only (§5.1): a device that could push to other users
 * could tell someone their submission was approved when it was not.
 */
function messaging() {
  initFirebase();
  return admin.messaging();
}
```

And add it to the export list:

```javascript
module.exports = {
  admin,
  initFirebase,
  db,
  auth,
  bucket,
  messaging,      // ← new
  serverTimestamp,
  increment,
};
```

> `push.js` reaches messaging through `admin.messaging()` directly, so this
> export is for symmetry and for tests that want to stub it. Both work.

---

## 3. `server/src/award.js` — notify after each decision

### 3a. Add the require

```javascript
const { db, admin, serverTimestamp } = require('./firebase');
const policyModule = require('./pointsPolicy');
const pushModule = require('./push');          // ← new
```

### 3b. `approveDisposal` — wrap the transaction

**Before:**

```javascript
async function approveDisposal({ disposalId, adminUid = null, flags = [] }) {
  const firestore = db();
  const disposalRef = firestore.collection('disposals').doc(disposalId);

  return firestore.runTransaction(async (txn) => {
    // … unchanged …
  });
}
```

**After** — the transaction body is untouched; only the wrapper changes:

```javascript
async function approveDisposal({ disposalId, adminUid = null, flags = [] }) {
  const firestore = db();
  const disposalRef = firestore.collection('disposals').doc(disposalId);

  const result = await firestore.runTransaction(async (txn) => {
    // … unchanged, still returns { disposalId, userId, pointsAwarded,
    //     balanceAfter, status } …
  });

  // F7.1 — after the transaction, never inside it.
  //
  // Firestore retries a transaction body on contention. A send inside one would
  // fire once per attempt, so a user could receive three copies of "50 points
  // added" for a single approval. By this line the wallet is credited and the
  // ledger written, so a push that fails costs nothing: the award stands and the
  // user still sees it in their history and their balance.
  //
  // notifyDisposalApproved never throws — see the header of push.js.
  await pushModule.notifyDisposalApproved({
    userId: result.userId,
    pointsAwarded: result.pointsAwarded,
    status: result.status,
  });

  return result;
}
```

### 3c. `rejectDisposal` — same shape, plus capturing the uid

The existing return value is `{ disposalId, status, reason }` and carries no
`userId`. Rather than change that shape — `server/test/server.test.js` asserts on
it — the uid is captured into an outer variable.

```javascript
async function rejectDisposal({ disposalId, adminUid, reason, flags = [] }) {
  if (!reason || !reason.trim()) {
    throw new Error('A rejection must record a reason.');
  }

  const firestore = db();
  const disposalRef = firestore.collection('disposals').doc(disposalId);

  // Captured inside the transaction, read after it commits.
  //
  // Retry-safe: a retried transaction body reassigns this, and the value left
  // standing belongs to the attempt that actually committed. Adding `userId` to
  // the return instead would have been cleaner, but the existing tests compare
  // that object exactly.
  let notifyUserId = null;

  const result = await firestore.runTransaction(async (txn) => {
    const snap = await txn.get(disposalRef);
    if (!snap.exists) {
      throw new Error('That submission no longer exists.');
    }

    const disposal = snap.data();
    if (disposal.status !== 'pending') {
      throw new Error(
        `That submission has already been decided (${disposal.status}).`,
      );
    }

    notifyUserId = disposal.userId;        // ← new, one line

    // … the rest of the body is unchanged …
  });

  await pushModule.notifyDisposalRejected({
    userId: notifyUserId,
    reason: result.reason,
  });

  return result;
}
```

> **Why here and not in `index.js`.** There are four decision paths: auto-approve
> (`verify.js`), manual approve, manual reject (both `index.js`), and the two
> claim paths. Putting the hook inside the decision functions means every path
> notifies — including `verifyDisposal`, which calls `approveDisposal` and so
> needs no edit of its own — and "one decision, one notification" becomes an
> invariant of the function that makes the decision rather than a convention
> route handlers have to remember.

---

## 4. `server/src/claims.js` — the same two hooks

### 4a. Add the require

```javascript
const { creditWalletInTransaction, SOURCES } = require('./award');
const pushModule = require('./push');          // ← new
```

### 4b. `approveClaim`

```javascript
  const result = await firestore.runTransaction(async (txn) => {
    // … unchanged, still returns { claimId, userId, status, pointsAwarded, … } …
  });

  await pushModule.notifyClaimApproved({
    userId: result.userId,
    pointsAwarded: result.pointsAwarded,
  });

  return result;
```

### 4c. `rejectClaim`

Same outer-variable pattern — `rejectClaim` returns `{ claimId, status, reason }`
with no uid:

```javascript
  let notifyUserId = null;

  const result = await firestore.runTransaction(async (txn) => {
    const snap = await txn.get(claimRef);
    if (!snap.exists) throw new Error('That claim no longer exists.');

    const claim = snap.data();
    if (claim.status !== 'pending') {
      throw new Error(`That claim has already been decided (${claim.status}).`);
    }

    notifyUserId = claim.userId;          // ← new

    // … unchanged …
  });

  await pushModule.notifyClaimRejected({
    userId: notifyUserId,
    reason: result.reason,
  });

  return result;
```

---

## 5. `lib/controllers/auth_controller.dart` — retire the token before sign-out

Two changes.

### 5a. Add the import

```dart
import '../services/auth_service.dart';
import '../services/user_service.dart';
import 'push_controller.dart' show pushServiceProvider;   // ← new
```

### 5b. Replace `signOut`

**Before:**

```dart
  Future<void> signOut() async {
    await _guard(() async {
      await ref.read(authServiceProvider).signOut();
    });
  }
```

**After:**

```dart
  Future<void> signOut() async {
    await _guard(() async {
      // Retire this device's push token BEFORE the session ends (F7.1).
      //
      // Ordering is the whole point. Once signOut completes, `isSelf(uid)` in
      // the rules is false and the delete is refused — the token document
      // survives, and the next decision for *this* account arrives on the phone
      // of whoever signs in next, carrying a rejection reason written for
      // somebody else. Shared and borrowed phones are normal in this setting,
      // so that is a real disclosure rather than a hypothetical one.
      //
      // unregisterDevice swallows its own failures, so a cleanup that cannot
      // reach Firestore does not trap the user in a session they asked to leave.
      final uid = ref.read(authServiceProvider).currentUser?.uid;
      if (uid != null) {
        await ref.read(pushServiceProvider).unregisterDevice(uid);
      }

      await ref.read(authServiceProvider).signOut();
    });
  }
```

---

## 6. `android/app/src/main/AndroidManifest.xml` — the Android 13 permission

Add one line beside the existing permissions:

```xml
    <uses-permission android:name="android.permission.INTERNET"/>
    <uses-permission android:name="android.permission.CAMERA"/>
    <uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
    <uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION"/>
    <!-- Android 13+ requires a runtime grant to post notifications (F7.1).
         Raised by PushService.requestPermission(); below API 33 notifications
         are granted at install and the prompt never appears. -->
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

Nothing else is needed. The `firebase_messaging` plugin contributes its own
service and receiver declarations through manifest merging, and `minSdk 23`
already satisfies it.

**Deliberately not added: a named notification channel.** Declaring
`com.google.firebase.messaging.default_notification_channel_id` only helps if a
channel with that ID already exists, and creating one from Dart needs
`flutter_local_notifications` — a dependency whose only other use here would be
duplicating foreground messages the app already renders as a banner. Without it,
FCM groups notifications under its own fallback channel, labelled
"Miscellaneous" in Android's settings. Cosmetic, and noted in the integration
notes as the one thing that dependency would buy.

---

## 7. `pubspec.yaml` — the dependency

Do **not** hand-write the version. Run:

```bash
flutter pub add firebase_messaging
```

so pub resolves the release that matches the installed `firebase_core 4.12.1`
rather than a number guessed from outside the project. The result will look like:

```yaml
  mobile_scanner: ^7.4.0
  http: ^1.6.0
  qr_flutter: ^4.1.0
  pdf: ^3.12.0
  printing: ^5.14.3
  firebase_messaging: ^16.0.5      # ← whatever pub resolves
```

Then, once:

```bash
cd server && npm test          # 87 existing tests + the new push suite
cd .. && dart analyze lib/
```

`firebase-admin ^13.0.2` already includes messaging. **No server dependency
changes.**
