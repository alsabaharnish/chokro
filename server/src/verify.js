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
const { haversineDistance, isPlausibleCoordinate } = require('./geo');
const policyModule = require('./pointsPolicy');
const { findDuplicate, hashImage } = require('./phash');
const { decide, hasCompletedVerification } = require('./decide');
const { screenImage, isValidItemType } = require('./screen');
const { isTrustedImageReference } = require('./cloudinary');
const { approveDisposal, readNonNegativeCounter } = require('./award');

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

/**
 * Approvals credited to this user today, read from the server-written counter.
 *
 * Reads the same `dailyCaps/{uid}_{dayKey}` document that `approveDisposal`
 * increments, rather than re-querying `disposals`. The query it replaces counted
 * submissions *created* today instead of approvals *performed* today, which the
 * client could sidestep by deferring verification to the next day — see the note
 * in `award.js`.
 *
 * This read is advisory: it only decides whether to raise the `dailyCapReached`
 * flag before the decision. The authoritative check runs inside the approval
 * transaction, where the same counter is read again under contention control.
 */
async function approvedTodayCount(uid) {
  const snap = await db()
    .collection('dailyCaps')
    .doc(`${uid}_${policyModule.dayKey(new Date())}`)
    .get();

  return snap.exists
    ? readNonNegativeCounter(snap.data().count, 'Daily approval counter')
    : 0;
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

  // A submission that has ALREADY been verified and routed to review is done
  // with this function, even though it is still `pending`.
  //
  // The status check above only catches a *decided* submission. Anything flagged
  // for review stays pending until an administrator acts, which can be hours —
  // and every repeat call in that window re-ran the entire pipeline: a Cloudinary
  // fetch, a fifty-document history query, and a **billed Groq vision call**. One
  // authenticated account could drive that at request rate against a single
  // pending document. Nothing was credited twice, so this was a cost and
  // availability hole rather than a payout hole, but on a free tier those are the
  // same thing.
  //
  // Returning the stored evidence rather than recomputing it is also the more
  // honest answer: the flags on the document are what the reviewer is looking at.
  if (hasCompletedVerification(disposal)) {
    const storedFlags = Array.isArray(disposal.flags) ? disposal.flags : [];

    // Recovery for submissions caught by the old two-write auto-approval path:
    // evidence was committed first, then the award failed. They are pending,
    // verified and flagless. Re-enter the authoritative transaction so the
    // daily cap, wallet and ledger are checked again and committed together.
    if (storedFlags.length === 0) {
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
        flags: [],
        distanceMeters: disposal.distanceMeters ?? null,
      };
    }

    return {
      disposalId,
      status: disposal.status,
      alreadyVerified: true,
      pointsAwarded: disposal.pointsAwarded ?? 0,
      flags: storedFlags,
      distanceMeters: disposal.distanceMeters ?? null,
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
  const locationValid = isPlausibleCoordinate(
    disposal.capturedLat,
    disposal.capturedLng,
  );
  const distanceMeters = locationValid
    ? haversineDistance(
        disposal.capturedLat,
        disposal.capturedLng,
        bin.lat,
        bin.lng,
      )
    : Number.NaN;

  // The upload response passes through a client-created Firestore document, so
  // bind it back to this user and this purpose before any external screening or
  // hashing. A malformed legacy document stays reviewable but never auto-pays.
  const photoTrusted = isTrustedImageReference({
    url: disposal.photoUrl,
    publicId: disposal.photoPublicId,
    uid: disposal.userId,
    kind: 'disposals',
  });

  const declarationValid =
    isValidItemType(disposal.itemType) &&
    Number.isInteger(disposal.declaredItemCount) &&
    disposal.declaredItemCount >= 1 &&
    disposal.declaredItemCount <= 100;

  // ---- 2. Perceptual hash and duplicate check ----
  //
  // `duplicateChecked` is tracked separately from `duplicate.isDuplicate`,
  // because "no match found" and "could not look" are different answers and
  // treating them alike is what let this pipeline pay out on an unchecked
  // photograph.
  let photoHash = null;
  let duplicate = { isDuplicate: false, distance: null };
  let duplicateChecked = false;

  if (photoTrusted) {
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
  const screening = photoTrusted && declarationValid
    ? await screenImage({
        imageUrl: disposal.photoUrl,
        declaredItemType: disposal.itemType,
        declaredItemCount: disposal.declaredItemCount,
      })
    : null;

  // ---- 4. Daily cap ----
  const approvedToday = await approvedTodayCount(disposal.userId);

  // ---- 5. Decide ----
  const outcome = decide({
    distanceMeters,
    radiusMeters: bin.radiusMeters,
    isDuplicate: duplicate.isDuplicate,
    duplicateChecked,
    photoTrusted,
    declarationValid,
    locationValid,
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
    // Evidence and credit commit together inside approveDisposal. A separate
    // evidence write used to create a crash window: if the award then failed,
    // retries saw verificationCompleted and never attempted the award again.
    const verificationEvidence = {
      photoHash,
      distanceMeters,
      verificationCompleted: true,
      ...screeningFields,
    };

    const result = await approveDisposal({
      disposalId,
      adminUid: null,
      flags: [],
      verificationEvidence,
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
    verificationCompleted: true,
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
