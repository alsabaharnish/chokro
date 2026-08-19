/**
 * The one place in the system that writes a wallet balance.
 *
 * Every award — a disposal approved automatically, a disposal approved by an
 * administrator, a self-reported claim, a completed purchase — passes through
 * `creditWallet`. There is exactly one function that moves points, and it always
 * writes a matching ledger entry in the same transaction.
 *
 * That single-path property is what makes NFR-4 true: every balance change has a
 * corresponding `transactions` document, so a balance is always reconstructable
 * from history. Two code paths that credit a balance would mean two places to
 * forget the ledger write.
 *
 * Nothing here is reachable from a client. `firestore.rules` denies every client
 * write to `wallets` and `transactions`, including an administrator's — proven
 * by the tests in `rules_test/m2.rules.test.js`.
 */

const { db, admin, serverTimestamp } = require('./firebase');
const policyModule = require('./pointsPolicy');
const { hasCompletedVerification } = require('./decide');
// Push on a decision (F7.1). No cycle: award.js -> push.js -> firebase.js, and
// push.js requires nothing else.
const pushModule = require('./push');

/** Valid `source` values for a ledger entry (§6). */
const SOURCES = Object.freeze({
  DISPOSAL: 'disposal',
  CLAIM: 'claim',
  PURCHASE: 'purchase',
  REDEMPTION: 'redemption',
});

/**
 * Credits or debits a wallet inside an existing transaction.
 *
 * Must be called with a transaction that has already performed all of its reads
 * — Firestore requires every read in a transaction to precede every write.
 *
 * @param {FirebaseFirestore.Transaction} txn
 * @param {object} args
 * @param {string} args.uid
 * @param {number} args.delta       positive to credit, negative to debit
 * @param {string} args.source      one of SOURCES
 * @param {string} args.refId       the disposal, claim or order this relates to
 * @param {number} args.currentBalance  balance read earlier in this transaction
 * @returns {number} the resulting balance
 */
function creditWalletInTransaction(
  txn,
  { uid, delta, source, refId, currentBalance },
) {
  if (!Object.values(SOURCES).includes(source)) {
    throw new Error(`Unknown ledger source: ${source}`);
  }
  if (!Number.isInteger(delta) || delta === 0) {
    throw new Error(`Ledger delta must be a non-zero integer, got: ${delta}`);
  }

  const balanceAfter = currentBalance + delta;

  if (balanceAfter < 0) {
    // A debit that would overdraw. Refusing here rather than clamping means a
    // bug in a caller surfaces as a failed request instead of silently losing
    // points, which would be far harder to notice.
    throw new Error(
      `Refusing to overdraw wallet ${uid}: balance ${currentBalance}, delta ${delta}`,
    );
  }

  txn.update(db().collection('wallets').doc(uid), {
    balance: balanceAfter,
    updatedAt: serverTimestamp(),
  });

  // Ledger entry in the same transaction. Never one without the other.
  txn.set(db().collection('transactions').doc(), {
    userId: uid,
    delta,
    source,
    refId,
    balanceAfter,
    createdAt: serverTimestamp(),
  });

  return balanceAfter;
}

/**
 * Approves a pending disposal and credits the award.
 *
 * @param {object} args
 * @param {string} args.disposalId
 * @param {string|null} args.adminUid  null for an automatic approval
 * @param {string[]|null} args.flags   why it went to review; null preserves the
 *                                     flags already on the document
 * @returns {Promise<object>} outcome summary
 *
 * The award is read from the live policy and **snapshotted onto the disposal**.
 * An administrator lowering the disposal award later must not rewrite what past
 * submissions were worth (§6.2).
 */
async function approveDisposal({ disposalId, adminUid = null, flags = null }) {
  const firestore = db();
  const disposalRef = firestore.collection('disposals').doc(disposalId);

  const result = await firestore.runTransaction(async (txn) => {
    // ---- reads first, all of them ----
    const disposalSnap = await txn.get(disposalRef);
    if (!disposalSnap.exists) {
      throw new Error('That submission no longer exists.');
    }

    const disposal = disposalSnap.data();

    if (disposal.status !== 'pending') {
      // Idempotence guard. Two administrators pressing approve on the same
      // queue item must not credit twice.
      throw new Error(
        `That submission has already been decided (${disposal.status}).`,
      );
    }

    // A client-created pending document appears in the admin stream before the
    // submitting device's verification request can finish. Without this guard,
    // a fast reviewer could approve during that window using the client-reported
    // distance and empty flags, bypassing every server check.
    //
    // The key is server-owned (rules reject it on create). The field-presence
    // fallback keeps submissions verified by the previous server release
    // reviewable: that release wrote these three evidence keys but not the
    // explicit marker.
    if (!hasCompletedVerification(disposal)) {
      throw new Error(
        'Verification is still running. Wait for its evidence before approving.',
      );
    }

    const uid = disposal.userId;
    const walletRef = firestore.collection('wallets').doc(uid);
    const walletSnap = await txn.get(walletRef);

    if (!walletSnap.exists) {
      throw new Error(`No wallet exists for user ${uid}.`);
    }

    const configSnap = await txn.get(
      firestore.collection('config').doc('points'),
    );
    const policy = policyModule.fromDoc(
      configSnap.exists ? configSnap.data() : null,
    );

    // Daily cap (§7.3): a second line of defence against multi-bin farming that
    // the per-bin lockout cannot catch on its own.
    const startOfDay = new Date();
    startOfDay.setUTCHours(0, 0, 0, 0);

    const approvedTodaySnap = await txn.get(
      firestore
        .collection('disposals')
        .where('userId', '==', uid)
        .where('createdAt', '>=', startOfDay),
    );

    const approvedToday = approvedTodaySnap.docs.filter((d) => {
      const status = d.data().status;
      return status === 'autoApproved' || status === 'manualApproved';
    }).length;

    if (approvedToday >= policy.dailyDisposalCap) {
      throw new Error(
        `This user has reached the daily limit of ${policy.dailyDisposalCap} ` +
          'approved disposals.',
      );
    }

    // ---- writes ----
    const award = policy.disposalAward;
    const balanceAfter = creditWalletInTransaction(txn, {
      uid,
      delta: award,
      source: SOURCES.DISPOSAL,
      refId: disposalId,
      currentBalance: walletSnap.data().balance || 0,
    });

    txn.update(disposalRef, {
      status: adminUid ? 'manualApproved' : 'autoApproved',
      pointsAwarded: award,
      // `flags ?? existing`, never a bare `flags`.
      //
      // The default used to be `[]`, and the review route passes none — so every
      // manual decision overwrote the flags with an empty array and destroyed the
      // record of why the submission reached the queue, at the exact moment a
      // human acted on it. Reviewing the reviewer became impossible: the queue
      // showed "outsideRadius, lowConfidence" and the approved document showed
      // nothing.
      //
      // Preserving is the default now, so a caller that omits flags cannot erase
      // them. `verifyDisposal` passes its own explicitly and still overwrites,
      // which is correct — it is the pass that computed them.
      flags: flags ?? disposal.flags ?? [],
      reviewedBy: adminUid,
      reviewedAt: adminUid ? serverTimestamp() : null,
    });

    // Open the per-bin lockout window (F2.6). Rules read this document to refuse
    // a repeat submission at the same bin.
    //
    // `disposalId` is recorded so a later rejection can tell whether it owns this
    // window — see the release in `rejectDisposal`. The document key is
    // `{uid}_{binId}` and cannot carry it, because the rules have to be able to
    // compose the key from those two values alone.
    const lockoutId = `${uid}_${disposal.binId}`;
    txn.set(firestore.collection('lockouts').doc(lockoutId), {
      expiresAt: policyModule.lockoutExpiry(policy, new Date()),
      userId: uid,
      binId: disposal.binId,
      disposalId,
    });

    // Dashboard counters, incremented here rather than by counting collections
    // later (§6.3).
    txn.set(
      firestore.collection('stats').doc('platform'),
      {
        disposalsApproved: admin.firestore.FieldValue.increment(1),
        pointsIssued: admin.firestore.FieldValue.increment(award),
      },
      { merge: true },
    );

    return {
      disposalId,
      userId: uid,
      pointsAwarded: award,
      balanceAfter,
      status: adminUid ? 'manualApproved' : 'autoApproved',
    };
  });

  // AFTER the commit, never inside it.
  //
  // Firestore retries a transaction body on contention, so a send inside one
  // fires once per attempt — three copies of "50 points added" for one approval.
  // The wallet write survives that because Firestore commits only one attempt;
  // an HTTP call to FCM does not.
  //
  // The hook lives here rather than in the route handler because auto-approval
  // reaches this function through `verifyDisposal`, so covering the decision
  // function covers both paths and makes "one decision, one notification" an
  // invariant of the thing that decides. `notifyDisposalApproved` swallows its
  // own failures: by this line the balance is credited and the ledger written,
  // and a dead token must not undo either.
  await pushModule.notifyDisposalApproved({
    userId: result.userId,
    pointsAwarded: result.pointsAwarded,
    status: result.status,
  });

  return result;
}

/**
 * Rejects a pending disposal.
 *
 * No points, a mandatory reason recorded and shown to the user, and the bin
 * lockout released so a legitimate retry is possible (§7.4).
 */
async function rejectDisposal({ disposalId, adminUid, reason, flags = null }) {
  if (!reason || !reason.trim()) {
    throw new Error('A rejection must record a reason.');
  }

  const firestore = db();
  const disposalRef = firestore.collection('disposals').doc(disposalId);

  // Captured from inside the transaction because the returned object cannot
  // carry it: `server/test/server.test.js` compares that shape exactly, so
  // adding `userId` to it would fail an existing test for a cosmetic gain.
  //
  // Retry-safe. A retried body reassigns this, and the value left standing
  // belongs to the attempt Firestore actually committed.
  let notifyUid = null;

  const result = await firestore.runTransaction(async (txn) => {
    const snap = await txn.get(disposalRef);
    if (!snap.exists) {
      throw new Error('That submission no longer exists.');
    }

    const disposal = snap.data();
    notifyUid = disposal.userId;

    if (disposal.status !== 'pending') {
      throw new Error(
        `That submission has already been decided (${disposal.status}).`,
      );
    }

    // Read before any write — Firestore requires every read in a transaction to
    // precede every write.
    const lockoutRef = firestore
      .collection('lockouts')
      .doc(`${disposal.userId}_${disposal.binId}`);
    const lockoutSnap = await txn.get(lockoutRef);

    txn.update(disposalRef, {
      status: 'rejected',
      rejectionReason: reason.trim(),
      // Preserved, not cleared — see the note in `approveDisposal`. A rejection
      // is precisely the decision whose justification most needs to survive.
      flags: flags ?? disposal.flags ?? [],
      reviewedBy: adminUid,
      reviewedAt: serverTimestamp(),
      pointsAwarded: 0,
    });

    // Release the lockout, but ONLY if this submission is the one that opened it.
    //
    // The key is `{uid}_{binId}` with no disposal in it, so an unconditional
    // delete released whatever window happened to be there. That is reachable:
    // nothing opens a lockout at submission time, so a user can have two pending
    // submissions at one bin — and then approving A opens the window while
    // rejecting B deletes it, reopening the bin hours early and handing back a
    // free submission that the approval was supposed to have spent.
    //
    // A rejected submission still should not cost six hours at that bin, which
    // is why the release exists at all; it just must not release somebody else's.
    if (lockoutSnap.exists && lockoutSnap.data().disposalId === disposalId) {
      txn.delete(lockoutRef);
    }

    txn.set(
      firestore.collection('stats').doc('platform'),
      { disposalsRejected: admin.firestore.FieldValue.increment(1) },
      { merge: true },
    );

    return { disposalId, status: 'rejected', reason: reason.trim() };
  });

  // §7.4 requires the reason to reach the user, and this is the only channel
  // that reaches them without them opening the app. Sent after the commit for
  // the same reasons as the approval above.
  await pushModule.notifyDisposalRejected({
    userId: notifyUid,
    reason: result.reason,
  });

  return result;
}

module.exports = {
  SOURCES,
  creditWalletInTransaction,
  approveDisposal,
  rejectDisposal,
};
