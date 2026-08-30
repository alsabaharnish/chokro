/**
 * Chokro — self-reported eco-action claims (F6.1–F6.4).
 *
 * Reuses the disposal machinery almost entirely: the same photo pipeline, the
 * same queue shape, the same approve/reject-with-reason, and the same single
 * wallet-credit path in `award.js`. What it lacks is a bin, a geofence and a
 * distance check, because there is nothing objective to check against.
 *
 * CLAIMS ARE NEVER AUTO-APPROVED.
 * There is no `verifyClaim` counterpart to `verifyDisposal` and there should
 * not be one. The auto-approve lane exists only where mechanical checks can
 * pass; here the only evidence is a photograph and an assertion, so a person
 * decides every time.
 *
 * THE QUOTA IS THE SAFEGUARD.
 * Without a geofence, the rate limit is what stops the route being farmed —
 * which is why it is enforced here, inside the approval transaction, rather
 * than at submission time where a client could race it.
 */

const { db, admin, serverTimestamp } = require('./firebase');
const policyModule = require('./pointsPolicy');
const {
  creditWalletInTransaction,
  readNonNegativeCounter,
  SOURCES,
} = require('./award');
// Push on a decision (F7.1).
const pushModule = require('./push');
const { isTrustedImageReference } = require('./cloudinary');
const { normalizeRejectionReason } = require('./reviewReason');

/** The closed action vocabulary. Mirrors ClaimActionType in Dart. */
const ACTION_TYPES = Object.freeze([
  'treePlanting',
  'composting',
  'refusingSingleUsePlastic',
  'reusableBagOrBottle',
  'communityCleanup',
]);

function isValidActionType(value) {
  return ACTION_TYPES.includes(value);
}

/**
 * Approves a claim, credits the award and increments the weekly quota.
 *
 * THE COUNTER INCREMENTS ON APPROVAL, NOT SUBMISSION (§7.4).
 * Counting at submission would let a user exhaust their own week with rejected
 * junk — three bad photographs and their legitimate fourth claim is refused.
 * Counting at approval means the quota limits what actually pays out.
 */
async function approveClaim({ claimId, adminUid }) {
  if (!adminUid) throw new Error('A claim approval must record a 3ZERO Admin.');

  const firestore = db();
  const claimRef = firestore.collection('claims').doc(claimId);

  const result = await firestore.runTransaction(async (txn) => {
    // ---- every read first ----
    const claimSnap = await txn.get(claimRef);
    if (!claimSnap.exists) throw new Error('That claim no longer exists.');

    const claim = claimSnap.data();

    if (claim.status !== 'pending') {
      // Idempotence: two administrators pressing approve must not credit twice.
      throw new Error(`That claim has already been decided (${claim.status}).`);
    }

    if (typeof claim.userId !== 'string' || claim.userId.length === 0) {
      throw new Error('That claim no longer names a valid user.');
    }
    if (!isValidActionType(claim.actionType)) {
      throw new Error('That claim uses an action type the app does not support.');
    }

    // New evidence is stored below `claims/{uid}`. The disposal folder is
    // accepted only for claims submitted by older app versions, which shared
    // the disposal upload endpoint. In either case the URL/public id must name
    // the same original asset in this user's folder before a payout can occur.
    const photoTrusted = ['claims', 'disposals'].some((kind) =>
      isTrustedImageReference({
        url: claim.photoUrl,
        publicId: claim.photoPublicId,
        uid: claim.userId,
        kind,
      }),
    );
    if (!photoTrusted) {
      throw new Error(
        'This claim photo could not be verified as an upload by this user.',
      );
    }

    const uid = claim.userId;
    const walletRef = firestore.collection('wallets').doc(uid);
    const walletSnap = await txn.get(walletRef);
    if (!walletSnap.exists) throw new Error(`No wallet exists for user ${uid}.`);

    const configSnap = await txn.get(firestore.collection('config').doc('points'));
    const policy = policyModule.fromDoc(configSnap.exists ? configSnap.data() : null);

    const weekKey = policyModule.isoWeekKey(new Date());
    const quotaRef = firestore.collection('claimQuotas').doc(`${uid}_${weekKey}`);
    const quotaSnap = await txn.get(quotaRef);
    const approvedThisWeek = quotaSnap.exists
      ? readNonNegativeCounter(
          quotaSnap.data().count,
          `Claim quota ${uid}_${weekKey}`,
        )
      : 0;

    if (approvedThisWeek >= policy.claimQuotaPerWeek) {
      throw new Error(
        `This user has reached the weekly limit of ${policy.claimQuotaPerWeek} ` +
          'approved claims. It resets on Monday.',
      );
    }

    // ---- writes ----
    const award = policy.claimAward;

    const balanceAfter = creditWalletInTransaction(txn, {
      uid,
      delta: award,
      source: SOURCES.CLAIM,
      refId: claimId,
      currentBalance: walletSnap.data().balance,
    });

    txn.update(claimRef, {
      status: 'approved',
      pointsAwarded: award,
      reviewedBy: adminUid,
      reviewedAt: serverTimestamp(),
    });

    txn.set(
      quotaRef,
      {
        userId: uid,
        weekKey,
        count: admin.firestore.FieldValue.increment(1),
        updatedAt: serverTimestamp(),
      },
      { merge: true },
    );

    txn.set(
      firestore.collection('stats').doc('platform'),
      {
        claimsApproved: admin.firestore.FieldValue.increment(1),
        pointsIssued: admin.firestore.FieldValue.increment(award),
      },
      { merge: true },
    );

    return {
      claimId,
      userId: uid,
      status: 'approved',
      pointsAwarded: award,
      balanceAfter,
      approvedThisWeek: approvedThisWeek + 1,
      weeklyQuota: policy.claimQuotaPerWeek,
    };
  });

  // After the commit — see `approveDisposal` for why a send inside a transaction
  // can fire several times for one decision.
  await pushModule.notifyClaimApproved({
    userId: result.userId,
    pointsAwarded: result.pointsAwarded,
  });

  return result;
}

/**
 * Rejects a claim.
 *
 * No points, a mandatory reason recorded and shown, and — importantly — the
 * quota counter is left alone. A rejected claim must not consume the user's
 * week.
 */
async function rejectClaim({ claimId, adminUid, reason }) {
  const rejectionReason = normalizeRejectionReason(reason);

  const firestore = db();
  const claimRef = firestore.collection('claims').doc(claimId);

  // Captured inside the transaction: the returned shape is asserted exactly by
  // `server/test/server.test.js`, so it cannot grow a `userId`. Retry-safe, for
  // the same reason as `rejectDisposal`.
  let notifyUid = null;

  const result = await firestore.runTransaction(async (txn) => {
    const snap = await txn.get(claimRef);
    if (!snap.exists) throw new Error('That claim no longer exists.');

    const claim = snap.data();
    notifyUid = claim.userId;
    if (claim.status !== 'pending') {
      throw new Error(`That claim has already been decided (${claim.status}).`);
    }

    txn.update(claimRef, {
      status: 'rejected',
      rejectionReason,
      reviewedBy: adminUid,
      reviewedAt: serverTimestamp(),
      pointsAwarded: 0,
    });

    txn.set(
      firestore.collection('stats').doc('platform'),
      { claimsRejected: admin.firestore.FieldValue.increment(1) },
      { merge: true },
    );

    return { claimId, status: 'rejected', reason: rejectionReason };
  });

  await pushModule.notifyClaimRejected({
    userId: notifyUid,
    reason: result.reason,
  });

  return result;
}

/**
 * How many approved claims a user has this ISO week, and their limit.
 *
 * Read-only, for showing a user their remaining allowance before they compose
 * a claim rather than after.
 */
async function claimQuotaStatus(uid) {
  const firestore = db();
  const weekKey = policyModule.isoWeekKey(new Date());

  const [quotaSnap, configSnap] = await Promise.all([
    firestore.collection('claimQuotas').doc(`${uid}_${weekKey}`).get(),
    firestore.collection('config').doc('points').get(),
  ]);

  const policy = policyModule.fromDoc(configSnap.exists ? configSnap.data() : null);
  const used = quotaSnap.exists
    ? readNonNegativeCounter(
        quotaSnap.data().count,
        `Claim quota ${uid}_${weekKey}`,
      )
    : 0;

  return {
    weekKey,
    used,
    limit: policy.claimQuotaPerWeek,
    remaining: Math.max(0, policy.claimQuotaPerWeek - used),
    claimAward: policy.claimAward,
  };
}

module.exports = {
  ACTION_TYPES,
  isValidActionType,
  approveClaim,
  rejectClaim,
  claimQuotaStatus,
};
