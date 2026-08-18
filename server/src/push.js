/**
 * Chokro — push notification on a decision (F7.1).
 *
 * THE SEND SIDE IS SERVER-ONLY.
 * §5.1 puts "push sends" on the server side of the trust boundary for the same
 * reason wallet writes are there: a device that could push to other users could
 * tell someone their submission was approved when it was not. The client's only
 * role is to register its own token; every message originates here, from the
 * same process that decided the payout.
 *
 * A PUSH MUST NEVER COST AN AWARD.
 * Every function in this module swallows its own failures and returns a summary
 * instead of throwing. A dead token, an FCM outage, a user who never granted
 * permission — none of them may turn a committed transaction into a failed
 * request. The wallet is credited and the ledger written before anything here
 * runs, and if it all fails the user still sees the award in their history and
 * their balance. The notification is a courtesy layered on top of a system that
 * is already correct without it.
 *
 * This is the same "fail toward the safe outcome" discipline as screen.js, which
 * returns null rather than throwing so the pipeline can route to review. Here the
 * safe outcome is "the award stands, the phone stayed quiet".
 *
 * CALLED AFTER THE TRANSACTION, NEVER INSIDE IT.
 * Firestore retries a transaction body on contention. A send inside one would
 * fire once per attempt, so a user could receive three copies of "50 points
 * added" for a single approval. Every call site here sits after `runTransaction`
 * has resolved.
 */

const { db, messaging } = require('./firebase');

/**
 * How many of a user's devices to notify.
 *
 * Ordered by most recently seen. Someone who has signed in on a phone, a spare
 * phone and a borrowed tablet gets the message on all of them; someone with a
 * long tail of stale tokens from reinstalls does not cost us a 500-token
 * multicast. Dead tokens are pruned on send (see `pruneDeadTokens`), so this
 * limit is a safety net rather than the primary cleanup.
 */
const DEVICE_LIMIT = 10;

/**
 * Ceiling on a single FCM round trip.
 *
 * The admin SDK has no per-call timeout, and this runs inside the request that
 * an administrator is waiting on after pressing approve. Without a bound, an FCM
 * hang would hold the review response open until the client's own 90-second
 * cold-start timeout fired, and the administrator would conclude the approval
 * had failed when it had already committed.
 */
const SEND_TIMEOUT_MS = 8000;

/** Body text longer than this is cut. FCM accepts more; a lock screen does not. */
const MAX_BODY_CHARS = 180;

/**
 * FCM error codes that mean "this token will never work again".
 *
 * Anything else — a network blip, a quota error, an internal FCM fault — is
 * transient and the token is left alone. Deleting on a transient failure would
 * silently unsubscribe a working device.
 */
const DEAD_TOKEN_CODES = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
  'messaging/invalid-argument',
]);

// ---------------------------------------------------------------------------
// Message composition — pure, no Firebase, unit-tested in server/test/push.test.js
// ---------------------------------------------------------------------------

/** Trims a reason to something a notification shade can actually show. */
function truncate(text, max = MAX_BODY_CHARS) {
  const clean = String(text ?? '').trim().replace(/\s+/g, ' ');
  if (clean.length <= max) return clean;
  return `${clean.slice(0, max - 1).trimEnd()}…`;
}

/**
 * The message for a credited disposal.
 *
 * The two approved states stay distinguishable in the copy, deliberately. §6.1
 * keeps `autoApproved` and `manualApproved` as separate states so the system can
 * answer "was this checked by a person?", and a user who is told "manually
 * verified" has been given that same answer. Collapsing both into "approved"
 * would throw it away at exactly the moment it is most useful to them.
 */
function disposalApprovedMessage({ pointsAwarded, status }) {
  const manual = status === 'manualApproved';
  return {
    title: manual ? 'Verified — points added' : 'Points added',
    body: manual
      ? `An administrator verified your disposal. ${pointsAwarded} points added.`
      : `Your disposal was approved automatically. ${pointsAwarded} points added.`,
    data: {
      kind: 'disposalDecision',
      status,
      pointsAwarded: String(pointsAwarded),
      route: '/history',
    },
  };
}

/**
 * The message for a rejected disposal.
 *
 * The reason travels in the body. §6.1 makes a reason mandatory on rejection and
 * §7.4 requires it to be shown, and a notification that says only "not approved"
 * would send the user into the app to find out why — which is the whole thing
 * the notification was supposed to save them.
 *
 * `screenNotes` is never included. It is admin-only for a reason: it describes
 * what the screen looked for, and showing it would teach a user how to defeat it.
 */
function disposalRejectedMessage({ reason }) {
  return {
    title: 'Submission not approved',
    body: truncate(reason),
    data: {
      kind: 'disposalDecision',
      status: 'rejected',
      pointsAwarded: '0',
      route: '/history',
    },
  };
}

function claimApprovedMessage({ pointsAwarded }) {
  return {
    title: 'Eco-action approved',
    body: `An administrator approved your eco-action. ${pointsAwarded} points added.`,
    data: {
      kind: 'claimDecision',
      status: 'approved',
      pointsAwarded: String(pointsAwarded),
      // Claims do not appear in the disposal history screen, so the ledger is
      // the honest destination — it is where the credit is visible. See the
      // integration notes: mounting the existing ClaimHistoryList on a /claims
      // route would give this a better home.
      route: '/wallet',
    },
  };
}

/**
 * A rejected eco-action.
 *
 * Routed to `/claims/new`, NOT to `/wallet` like the approval above. A rejection
 * credits nothing, so there is no ledger entry for it — a tap landing on the
 * wallet would show a screen with nothing whatsoever about the decision on it.
 * `/claims/new` carries the `Your eco-actions` list, which shows each claim's
 * status and its rejection reason, and offers a re-submission.
 *
 * The proper destination would be a claims history route of its own; `/history`
 * lists disposals only. Noted as a follow-on rather than built here.
 */
function claimRejectedMessage({ reason }) {
  return {
    title: 'Eco-action not approved',
    body: truncate(reason),
    data: {
      kind: 'claimDecision',
      status: 'rejected',
      pointsAwarded: '0',
      route: '/claims/new',
    },
  };
}

// ---------------------------------------------------------------------------
// Token storage
// ---------------------------------------------------------------------------

/** `users/{uid}/devices` — one document per registered device. */
function devicesRef(uid) {
  return db().collection('users').doc(uid).collection('devices');
}

/**
 * The tokens to notify for [uid], most recently seen first.
 *
 * Returns an empty array rather than throwing on any read failure. A user with
 * no devices — never granted permission, signed in only on the web build — is
 * the normal case, not an error.
 */
async function tokensFor(uid) {
  try {
    const snap = await devicesRef(uid)
      .orderBy('updatedAt', 'desc')
      .limit(DEVICE_LIMIT)
      .get();

    return snap.docs
      .map((doc) => doc.id)
      .filter((token) => typeof token === 'string' && token.length > 0);
  } catch (err) {
    console.error(`[push] Could not read devices for ${uid}:`, err.message);
    return [];
  }
}

/**
 * Removes tokens FCM has told us are permanently dead.
 *
 * Uninstalling the app, clearing its data, or a token rotation the device never
 * reported all leave a document behind that will never deliver again. Left
 * alone these accumulate and every future send wastes a slot on them, so the
 * response to a send is also the cleanup signal.
 */
async function pruneDeadTokens(uid, tokens) {
  if (tokens.length === 0) return;

  try {
    const batch = db().batch();
    for (const token of tokens) batch.delete(devicesRef(uid).doc(token));
    await batch.commit();
    console.log(`[push] Pruned ${tokens.length} dead token(s) for ${uid}.`);
  } catch (err) {
    // Cleanup failing is not worth reporting upward. The tokens stay, the next
    // send tries them again, and nothing the user sees is affected.
    console.error(`[push] Prune failed for ${uid}:`, err.message);
  }
}

// ---------------------------------------------------------------------------
// Sending
// ---------------------------------------------------------------------------

/** Rejects after [ms], so a hung FCM call cannot hold a request open. */
function timeout(ms) {
  return new Promise((_, reject) =>
    setTimeout(() => reject(new Error(`FCM send exceeded ${ms}ms`)), ms),
  );
}

/**
 * Sends one composed message to every device [uid] has registered.
 *
 * NEVER THROWS. Returns `{sent, failed, skipped}` so a caller can log it, and
 * so the tests can assert on it, but no return value here is load-bearing —
 * every call site ignores it.
 *
 * The message carries both a `notification` block and a `data` block on purpose.
 * The notification block is what Android renders in the tray when the app is
 * backgrounded or dead, with no code of ours running. The data block is what the
 * Dart side reads to decide where to navigate when the notification is tapped,
 * and what it renders as an in-app banner when the app is already open — a case
 * where Android deliberately does not show a tray notification at all.
 *
 * @param {object} args
 * @param {string} args.uid
 * @param {{title: string, body: string, data: Record<string,string>}} args.message
 */
async function sendToUser({ uid, message }) {
  if (!uid) return { sent: 0, failed: 0, skipped: true };

  const tokens = await tokensFor(uid);
  if (tokens.length === 0) {
    // Not a failure. Most users on the web build will never have a token, and a
    // user who declined the permission prompt has made a choice we respect.
    return { sent: 0, failed: 0, skipped: true };
  }

  let response;
  try {
    response = await Promise.race([
      messaging().sendEachForMulticast({
        tokens,
        notification: { title: message.title, body: message.body },
        // Every value in a data payload must be a string. FCM rejects the whole
        // message otherwise, which is why the composers above stringify their
        // numbers rather than leaving that to a caller.
        data: message.data,
        android: {
          priority: 'high',
          notification: {
            // Tapping opens the app rather than doing nothing. The Dart side
            // reads data.route from getInitialMessage / onMessageOpenedApp.
            clickAction: 'FLUTTER_NOTIFICATION_CLICK',
          },
        },
      }),
      timeout(SEND_TIMEOUT_MS),
    ]);
  } catch (err) {
    // Swallowed deliberately — see the module header. The award has already
    // committed; this is the only place that knows the push did not land, and
    // the log line is the whole remedy.
    console.error(`[push] Send to ${uid} failed:`, err.message);
    return { sent: 0, failed: tokens.length, skipped: false };
  }

  const dead = [];
  response.responses.forEach((result, index) => {
    if (result.success) return;
    const code = result.error && result.error.code;
    if (DEAD_TOKEN_CODES.has(code)) dead.push(tokens[index]);
    else console.warn(`[push] Transient failure for ${uid}: ${code}`);
  });

  await pruneDeadTokens(uid, dead);

  return {
    sent: response.successCount,
    failed: response.failureCount,
    skipped: false,
  };
}

// ---------------------------------------------------------------------------
// The four decision hooks
// ---------------------------------------------------------------------------

/**
 * Notifies a user that their disposal was approved.
 *
 * @param {object} args
 * @param {string} args.userId
 * @param {number} args.pointsAwarded
 * @param {'autoApproved'|'manualApproved'} args.status
 */
function notifyDisposalApproved({ userId, pointsAwarded, status }) {
  return sendToUser({
    uid: userId,
    message: disposalApprovedMessage({ pointsAwarded, status }),
  });
}

function notifyDisposalRejected({ userId, reason }) {
  return sendToUser({
    uid: userId,
    message: disposalRejectedMessage({ reason }),
  });
}

function notifyClaimApproved({ userId, pointsAwarded }) {
  return sendToUser({
    uid: userId,
    message: claimApprovedMessage({ pointsAwarded }),
  });
}

function notifyClaimRejected({ userId, reason }) {
  return sendToUser({
    uid: userId,
    message: claimRejectedMessage({ reason }),
  });
}

module.exports = {
  DEVICE_LIMIT,
  SEND_TIMEOUT_MS,
  MAX_BODY_CHARS,
  DEAD_TOKEN_CODES,
  truncate,
  disposalApprovedMessage,
  disposalRejectedMessage,
  claimApprovedMessage,
  claimRejectedMessage,
  tokensFor,
  sendToUser,
  notifyDisposalApproved,
  notifyDisposalRejected,
  notifyClaimApproved,
  notifyClaimRejected,
};
