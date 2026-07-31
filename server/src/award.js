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
 * @param {string[]} args.flags        why it went to review, if it did
 * @returns {Promise<object>} outcome summary
 *
 * The award is read from the live policy and **snapshotted onto the disposal**.
 * An administrator lowering the disposal award later must not rewrite what past
 * submissions were worth (§6.2).
 */
async function approveDisposal({ disposalId, adminUid = null, flags = [] }) {
  const firestore = db();
  const disposalRef = firestore.collection('disposals').doc(disposalId);

  return firestore.runTransaction(async (txn) => {
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
      flags,
      reviewedBy: adminUid,
      reviewedAt: adminUid ? serverTimestamp() : null,
    });

    // Open the per-bin lockout window (F2.6). Rules read this document to refuse
    // a repeat submission at the same bin.
    const lockoutId = `${uid}_${disposal.binId}`;
    txn.set(firestore.collection('lockouts').doc(lockoutId), {
      expiresAt: policyModule.lockoutExpiry(policy, new Date()),
      userId: uid,
      binId: disposal.binId,
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
}

/**
 * Rejects a pending disposal.
 *
 * No points, a mandatory reason recorded and shown to the user, and the bin
 * lockout released so a legitimate retry is possible (§7.4).
 */
async function rejectDisposal({ disposalId, adminUid, reason, flags = [] }) {
  if (!reason || !reason.trim()) {
    throw new Error('A rejection must record a reason.');
  }

  const firestore = db();
  const disposalRef = firestore.collection('disposals').doc(disposalId);

  return firestore.runTransaction(async (txn) => {
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

    txn.update(disposalRef, {
      status: 'rejected',
      rejectionReason: reason.trim(),
      flags,
      reviewedBy: adminUid,
      reviewedAt: serverTimestamp(),
      pointsAwarded: 0,
    });

    // Release the lockout: a rejected submission should not also cost the user
    // six hours at that bin.
    const lockoutId = `${disposal.userId}_${disposal.binId}`;
    txn.delete(firestore.collection('lockouts').doc(lockoutId));

    txn.set(
      firestore.collection('stats').doc('platform'),
      { disposalsRejected: admin.firestore.FieldValue.increment(1) },
      { merge: true },
    );

    return { disposalId, status: 'rejected', reason: reason.trim() };
  });
}

module.exports = {
  SOURCES,
  creditWalletInTransaction,
  approveDisposal,
  rejectDisposal,
};
