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
const skuShortlist = require('./skuShortlist');
const eprPolicy = require('./eprPolicy');
const attribute = require('./attribute');
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
 * A scanned barcode, or null (EPR-18).
 *
 * Digits only, 8 to 14 of them — the GTIN-8, GTIN-12, GTIN-13 and GTIN-14
 * lengths. Anything else is null rather than an error: a misread barcode is a
 * common, harmless event at a bin, and failing a submission over one would make
 * scanning riskier than not scanning, which would defeat the whole point of
 * preferring the barcode path.
 *
 * The check digit is deliberately not verified. A GTIN that does not resolve to
 * a registered product is simply not an attribution, so an invalid one costs
 * nothing — and rejecting a valid barcode because of a check-digit
 * implementation disagreement would cost an accurate attribution.
 */
function normalizeGtin(value) {
  if (typeof value !== 'string') return null;
  const digits = value.replace(/\s/g, '');
  return /^\d{8,14}$/.test(digits) ? digits : null;
}

/**
 * Builds the recognition shortlist for one disposal (EPR-15, SEC-11).
 *
 * NEVER THROWS AND NEVER PARTIALLY SUCCEEDS. An empty shortlist makes the
 * prompt exactly the one this service sent before Phase C existed, so every
 * failure mode here is "no recognition this time" rather than "a different
 * disposal decision this time".
 *
 * THE SPEND CEILING'S DEGRADATION IS DEFINED HERE.
 * SEC-11 requires the recognition path to have a per-period spend ceiling with
 * a defined degradation, and states the direction: "fall back to no
 * attribution, never to invented attribution". Above the ceiling the shortlist
 * is empty, the model is not asked the second question, nothing is attributed,
 * and the disposal is decided on exactly the evidence it would have had anyway.
 */
async function buildRecognitionShortlist({ disposal, bin }) {
  try {
    if (!skuShortlist.couldContainRegisteredProduct(disposal.itemType)) {
      // Glass, metal, paper, e-waste and organic cannot contain a registered
      // plastic product, so there is nothing to ask about and no reason to
      // spend the tokens.
      return [];
    }

    const policy = await eprPolicy.readPolicy();

    return await skuShortlist.buildShortlist({
      declaredItemType: disposal.itemType,
      district: bin?.district || null,
      binId: disposal.binId || null,
      cap: policy.skuShortlistCap,
    });
  } catch (err) {
    console.error('[verify] shortlist build failed:', err.message);
    return [];
  }
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
 * Returns the idempotent response for a decided or already-verified document.
 * A pending document with no server evidence returns null so verification can
 * continue.
 */
async function existingVerificationOutcome(disposalId, disposal) {
  if (disposal.status !== 'pending') {
    return {
      disposalId,
      status: disposal.status,
      alreadyDecided: true,
      pointsAwarded: disposal.pointsAwarded ?? 0,
      flags: disposal.flags ?? [],
    };
  }

  if (!hasCompletedVerification(disposal)) return null;

  const storedFlags = Array.isArray(disposal.flags) ? disposal.flags : [];

  // Recovery for submissions caught by the old two-write auto-approval path:
  // evidence was committed first, then the award failed. They are pending,
  // verified and flagless. Re-enter the authoritative transaction so the
  // daily cap, active-bin state, wallet and ledger are checked again.
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

/**
 * Persists review evidence only while this exact submission is still pending
 * and unverified.
 *
 * Hashing plus vision screening can take tens of seconds. During that time an
 * administrator can reject the submission, or a duplicate verify request can
 * finish first. A blind `DocumentReference.update()` after those calls used to
 * overwrite the winner's flags/evidence and return `status: pending` even after
 * a rejection had committed. The transaction turns the final state check and
 * evidence write into one conditional operation.
 */
async function persistReviewEvidence({
  firestore,
  disposalRef,
  callerUid,
  evidence,
}) {
  return firestore.runTransaction(async (txn) => {
    const latestSnap = await txn.get(disposalRef);
    if (!latestSnap.exists) {
      throw new Error('That submission no longer exists.');
    }

    const latest = latestSnap.data();
    if (latest.userId !== callerUid) {
      throw new Error('That submission belongs to someone else.');
    }

    if (latest.status !== 'pending') {
      return { state: 'decided', disposal: latest };
    }
    if (hasCompletedVerification(latest)) {
      return { state: 'verified', disposal: latest };
    }

    txn.update(disposalRef, evidence);
    return { state: 'stored', disposal: null };
  });
}

/**
 * Reads the winner after an automatic-award transaction loses a race.
 *
 * Only a genuinely committed decision or a flagged review result is returned.
 * A still-untouched pending document returns null so the original award error
 * (daily cap, closed bin, missing wallet, and so on) remains authoritative.
 */
async function committedVerificationOutcome({
  disposalId,
  callerUid,
  disposalRef,
}) {
  const latestSnap = await disposalRef.get();
  if (!latestSnap.exists) return null;

  const latest = latestSnap.data();
  if (latest.userId !== callerUid) return null;

  if (latest.status !== 'pending') {
    return existingVerificationOutcome(disposalId, latest);
  }

  const storedFlags = Array.isArray(latest.flags) ? latest.flags : [];
  if (hasCompletedVerification(latest) && storedFlags.length > 0) {
    return existingVerificationOutcome(disposalId, latest);
  }

  return null;
}

/**
 * Verifies a pending submission and either credits it or routes it to review.
 *
 * @param {object} args
 * @param {string} args.disposalId
 * @param {string} args.callerUid  must own the submission
 * @returns {Promise<object>} the outcome, safe to return to the client
 */
async function verifyDisposal({ disposalId, callerUid, scannedGtin = null }) {
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

  // Idempotence. A retry after a timeout must not re-credit or repeat the paid
  // screening call. Pending submissions with stored evidence are already in the
  // review queue even though their status has not changed yet.
  const existing = await existingVerificationOutcome(disposalId, disposal);
  if (existing) return existing;

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
  //
  // The SKU shortlist rides along on the call that already happens (EPR-15,
  // NFR-E-7): "Attribution adds one model call per approved disposal (or
  // extends the existing one)". Extending it is the cheaper half of that
  // choice, and it is also the only one that works for a manual approval — a
  // disposal routed to review carries its recognition evidence forward, so an
  // Admin approving three days later attributes against what was screened at
  // the time rather than re-screening a bin that has since been emptied.
  //
  // Every failure in the builder yields an empty shortlist, which makes the
  // prompt byte-identical to the one this service sent before this phase
  // existed. A registry outage therefore degrades attribution and leaves the
  // disposal decision untouched (EPR-16).
  const shortlist = attribute.isEnabled()
    ? await buildRecognitionShortlist({ disposal, bin })
    : [];

  const screening = photoTrusted && declarationValid
    ? await screenImage({
        imageUrl: disposal.photoUrl,
        declaredItemType: disposal.itemType,
        declaredItemCount: disposal.declaredItemCount,
        shortlist,
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
        // The two that decide whether the waste reached the bin. Stored so a
        // reviewer can see the machine's answer beside the photograph, and so
        // a disputed award can be audited against what was actually screened.
        screenBinVisible: screening.binVisible ?? null,
        screenWasteInBin: screening.wasteInBin ?? null,
        screenNotes: screening.notes ?? null,
        // The recognition block (EPR-15). `undefined` is not a Firestore value,
        // so an absent block is stored as null — and null is a *different fact*
        // from an empty array: null means recognition did not run, empty means
        // it ran and recognised nothing. The attribution path treats them
        // differently, so the distinction has to survive the write (EPR-19).
        skuMatches: screening.skuMatches ?? null,
      }
    : {
        screenConfidence: null,
        screenItemCount: null,
        screenBinVisible: null,
        screenWasteInBin: null,
        screenNotes: null,
        skuMatches: null,
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
      // Validated at the trust boundary, then stored server-side. A GTIN is
      // one step from a mass, so an unvalidated one must never reach the
      // registry lookup (EPR-18).
      scannedGtin: normalizeGtin(scannedGtin),
    };

    let result;
    try {
      result = await approveDisposal({
        disposalId,
        adminUid: null,
        flags: [],
        verificationEvidence,
      });
    } catch (error) {
      // A duplicate request or an administrator may have committed while this
      // request was screening the photo. Return that committed truth instead
      // of a 409 that tells the submitter verification failed when it did not.
      // If this read itself fails, preserve the original, more useful error.
      try {
        const committed = await committedVerificationOutcome({
          disposalId,
          callerUid,
          disposalRef,
        });
        if (committed) return committed;
      } catch (_) {
        // Preserve [error] below.
      }
      throw error;
    }

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
  const evidence = {
    photoHash,
    distanceMeters,
    verificationCompleted: true,
    flags: outcome.flags,
    ...screeningFields,
    scannedGtin: normalizeGtin(scannedGtin),
  };

  const persistence = await persistReviewEvidence({
    firestore,
    disposalRef,
    callerUid,
    evidence,
  });

  if (persistence.state !== 'stored') {
    // Another verifier or an administrator won while the network checks were in
    // flight. Return the committed truth; never overwrite it with stale evidence
    // or claim this request left the document pending.
    const latest = await existingVerificationOutcome(
      disposalId,
      persistence.disposal,
    );
    if (latest) return latest;
    throw new Error('That submission changed while it was being verified.');
  }

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
  existingVerificationOutcome,
  persistReviewEvidence,
  committedVerificationOutcome,
  verifyDisposal,
};
