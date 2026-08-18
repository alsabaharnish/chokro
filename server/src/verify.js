/**
 * Chokro — disposal verification (F2.5, F2.11, F2.12).
 *
 * The client writes a `pending` document and calls this. Everything that
 * follows is server-side, because every input to it is something a client could
 * lie about.
 *
 * The order matters. Cheap local checks run before anything that costs a
 * network call, so an obviously-out-of-radius submission never spends a
 * screening request.
 *
 * SCREENING IS OPTIONAL BY DESIGN.
 * With no Groq key configured, `screenImage` returns null, `decide` raises
 * `screeningUnavailable`, and the submission routes to review. The pipeline is
 * fully functional without a key — it just never uses the auto-approve lane.
 * That is the same path a rate limit or an outage takes (§7.4), so the
 * unconfigured case is not a special case.
 */

const { db } = require('./firebase');
const { haversineDistance } = require('./geo');
const policyModule = require('./pointsPolicy');
const { findDuplicate, hashImage } = require('./phash');
const { decide } = require('./decide');
const { screenImage } = require('./screen');
const { approveDisposal } = require('./award');

/**
 * How many of a user's previous hashes to compare against.
 *
 * Bounded because this is a Firestore read on every submission. Someone
 * recycling a photograph will do it recently; a hash from four months ago
 * matters less than the cost of fetching every one ever written.
 */
const HASH_HISTORY_LIMIT = 50;

/** Perceptual hashes from this user's earlier submissions. */
async function previousHashes(uid, excludeId) {
  const snap = await db()
    .collection('disposals')
    .where('userId', '==', uid)
    .orderBy('createdAt', 'desc')
    .limit(HASH_HISTORY_LIMIT)
    .get();

  return snap.docs
    .filter((doc) => doc.id !== excludeId)
    .map((doc) => doc.data().photoHash)
    .filter((hash) => typeof hash === 'string' && hash.length > 0);
}

/** Approved disposals for this user since UTC midnight. */
async function approvedTodayCount(uid) {
  const startOfDay = new Date();
  startOfDay.setUTCHours(0, 0, 0, 0);

  const snap = await db()
    .collection('disposals')
    .where('userId', '==', uid)
    .where('createdAt', '>=', startOfDay)
    .get();

  return snap.docs.filter((doc) => {
    const status = doc.data().status;
    return status === 'autoApproved' || status === 'manualApproved';
  }).length;
}

/**
 * Verifies a pending submission and either credits it or routes it to review.
 *
 * @param {object} args
 * @param {string} args.disposalId
 * @param {string} args.callerUid  must own the submission
 * @returns {Promise<object>} the outcome, safe to return to the client
 */
async function verifyDisposal({ disposalId, callerUid }) {
  const firestore = db();
  const disposalRef = firestore.collection('disposals').doc(disposalId);
  const snap = await disposalRef.get();

  if (!snap.exists) throw new Error('That submission no longer exists.');
  const disposal = snap.data();

  // A user may only verify their own submission. Without this, any signed-in
  // account could trigger verification on anyone else's.
  if (disposal.userId !== callerUid) {
    throw new Error('That submission belongs to someone else.');
  }

  // Idempotence. A retry after a timeout must not re-credit — the client
  // cannot tell a lost response from a lost request, so it will retry.
  if (disposal.status !== 'pending') {
    return {
      disposalId,
      status: disposal.status,
      alreadyDecided: true,
      pointsAwarded: disposal.pointsAwarded ?? 0,
      flags: disposal.flags ?? [],
    };
  }

  const binSnap = await firestore.collection('bins').doc(disposal.binId).get();
  if (!binSnap.exists) throw new Error('That bin is no longer registered.');
  const bin = binSnap.data();

  // `active` is checked here, not only in the rules.
  //
  // Bins are never deleted — past disposals reference them, so `setBinActive`
  // is the soft-delete substitute and `admin_bins_view` presents Close/Reopen as
  // taking a bin out of service. Nothing on the server read the field, so a
  // submission at a closed bin still auto-approved against its stale
  // coordinates: the administrator's control changed a boolean the payout path
  // ignored.
  //
  // `binIsOpen()` in the rules refuses the *create*, so this is the second line
  // rather than the only one — but a submission created while the bin was open
  // and verified after it closed reaches exactly here, and that is the case the
  // rules cannot see.
  if (bin.active === false) {
    throw new Error('That bin is no longer in service.');
  }

  const configSnap = await firestore.collection('config').doc('points').get();
  const policy = policyModule.fromDoc(
    configSnap.exists ? configSnap.data() : null,
  );

  // ---- 1. Distance, recomputed from stored coordinates ----
  //
  // The client sent a `distanceMeters` too. It is display only. A modified app
  // can put any number there, so nothing is trusted because the app calculated
  // it (§7.1, F2.5).
  const distanceMeters = haversineDistance(
    disposal.capturedLat,
    disposal.capturedLng,
    bin.lat,
    bin.lng,
  );

  // ---- 2. Perceptual hash and duplicate check ----
  //
  // `duplicateChecked` is tracked separately from `duplicate.isDuplicate`,
  // because "no match found" and "could not look" are different answers and
  // treating them alike is what let this pipeline pay out on an unchecked
  // photograph.
  let photoHash = null;
  let duplicate = { isDuplicate: false, distance: null };
  let duplicateChecked = false;

  if (disposal.photoPublicId) {
    try {
      photoHash = await hashImage(disposal.photoPublicId);
      const history = await previousHashes(disposal.userId, disposalId);
      duplicate = findDuplicate(photoHash, history);

      // Set last, and only here. `hashImage` can succeed and `previousHashes`
      // still throw, which would leave a hash in hand and no comparison behind
      // it — so `photoHash !== null` is not the same question.
      duplicateChecked = true;
    } catch (err) {
      // Left false on purpose. `hashImage` throws on a missing cloud name, a
      // non-200 from Cloudinary, an unexpected bit depth, an unknown scanline
      // filter and any zlib failure; before `hashUnavailable` existed, every one
      // of those produced a flagless submission that went straight down the
      // auto-approve lane with the duplicate defence never having run.
      console.error(`Hashing ${disposalId} failed:`, err.message);
    }
  }
  // An empty `photoPublicId` skips the block entirely and lands here the same
  // way: not checked, so flagged rather than assumed clean.

  // ---- 3. Screening ----
  const screening = await screenImage({
    imageUrl: disposal.photoUrl,
    declaredItemType: disposal.itemType,
    declaredItemCount: disposal.declaredItemCount,
  });

  // ---- 4. Daily cap ----
  const approvedToday = await approvedTodayCount(disposal.userId);

  // ---- 5. Decide ----
  const outcome = decide({
    distanceMeters,
    radiusMeters: bin.radiusMeters,
    isDuplicate: duplicate.isDuplicate,
    duplicateChecked,
    declaredItemCount: disposal.declaredItemCount,
    screening,
    approvedToday,
    dailyCap: policy.dailyDisposalCap,
  });

  // Screening output is recorded whatever the decision, so an administrator
  // reviewing the item can see what the machine thought. `screenNotes` is
  // admin-only: showing it to users would teach them how to game the screen.
  const screeningFields = screening
    ? {
        screenConfidence: screening.confidence ?? null,
        screenItemCount: screening.itemCount ?? null,
        screenNotes: screening.notes ?? null,
      }
    : {
        screenConfidence: null,
        screenItemCount: null,
        screenNotes: null,
      };

  if (outcome.decision === 'autoApprove') {
    // Write the evidence before crediting, so an approved submission always
    // carries the hash and distance that justified it.
    await disposalRef.update({
      photoHash,
      distanceMeters,
      ...screeningFields,
    });

    const result = await approveDisposal({
      disposalId,
      adminUid: null,
      flags: [],
    });

    return {
      disposalId,
      status: 'autoApproved',
      pointsAwarded: result.pointsAwarded,
      balanceAfter: result.balanceAfter,
      distanceMeters,
      flags: [],
    };
  }

  // Route to review. The document stays `pending` — the wallet is untouched
  // and the user's history shows the submission as awaiting a decision.
  await disposalRef.update({
    photoHash,
    distanceMeters,
    flags: outcome.flags,
    ...screeningFields,
  });

  return {
    disposalId,
    status: 'pending',
    pointsAwarded: 0,
    distanceMeters,
    flags: outcome.flags,
    reasons: outcome.reasons,
  };
}

module.exports = {
  HASH_HISTORY_LIMIT,
  previousHashes,
  approvedTodayCount,
  verifyDisposal,
};
