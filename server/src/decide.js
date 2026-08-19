/**
 * Chokro — the two-lane decision (F2.12).
 *
 * Every mechanical check produces flags. This module turns a set of flags into
 * one of two outcomes: credit it now, or put it in front of a person.
 *
 * THE RULE THAT GOVERNS EVERYTHING HERE
 * The system fails toward review, never toward payout. Any uncertainty — a low
 * confidence score, a count that disagrees with the photograph, a screening
 * service that could not be reached, an unrecognised anything — routes to an
 * administrator. Auto-approval requires every check to have run *and* passed.
 * "No flags" is not the same as "nothing was checked", and this module refuses
 * to confuse them.
 *
 * Deliberately pure: no Firebase, no network, no clock. The whole decision is a
 * function of its inputs, so every branch is unit-testable and the reasoning is
 * inspectable in one file.
 */

/**
 * The flag vocabulary (§6.1). Each carries a sentence for the reviewing
 * administrator, so the queue explains itself rather than presenting a
 * photograph with no context.
 */
const FLAGS = Object.freeze({
  OUTSIDE_RADIUS: 'outsideRadius',
  DUPLICATE_PHOTO: 'duplicatePhoto',
  COUNT_MISMATCH: 'countMismatch',
  LOW_CONFIDENCE: 'lowConfidence',
  ITEM_TYPE_MISMATCH: 'itemTypeMismatch',
  DAILY_CAP_REACHED: 'dailyCapReached',
  SCREENING_UNAVAILABLE: 'screeningUnavailable',
  HASH_UNAVAILABLE: 'hashUnavailable',
  PHOTO_UNTRUSTED: 'photoUntrusted',
  INVALID_DECLARATION: 'invalidDeclaration',
  INVALID_LOCATION: 'invalidLocation',
});

const FLAG_EXPLANATIONS = Object.freeze({
  [FLAGS.OUTSIDE_RADIUS]:
    'The phone was outside the bin\u2019s accepted radius when the photo was taken.',
  [FLAGS.DUPLICATE_PHOTO]:
    'This photograph closely matches one this user submitted before.',
  [FLAGS.COUNT_MISMATCH]:
    'The number of items declared does not match what the screen counted.',
  [FLAGS.LOW_CONFIDENCE]:
    'Automated screening was not confident about this photograph.',
  [FLAGS.ITEM_TYPE_MISMATCH]:
    'The declared waste type does not match what the screen identified.',
  [FLAGS.DAILY_CAP_REACHED]:
    'This user has already reached the daily limit of approved disposals.',
  [FLAGS.SCREENING_UNAVAILABLE]:
    'Automated screening could not be reached, so this was not checked.',
  [FLAGS.HASH_UNAVAILABLE]:
    'The photograph could not be fingerprinted, so it was not compared against ' +
    'earlier submissions.',
  [FLAGS.PHOTO_UNTRUSTED]:
    'The stored photograph does not match a trusted upload for this user.',
  [FLAGS.INVALID_DECLARATION]:
    'The submitted material type or item count is not valid.',
  [FLAGS.INVALID_LOCATION]:
    'The submitted coordinates are missing or outside valid latitude/longitude ranges.',
});

/**
 * Some flags mean "a person should look"; one means "this cannot be approved
 * at all". The daily cap is the latter — approving past it would breach the
 * policy no matter who pressed the button, so `award.js` throws on it.
 */
const BLOCKING_FLAGS = Object.freeze([FLAGS.DAILY_CAP_REACHED]);

/** Below this, the screen's verdict is not trusted enough to auto-approve. */
const CONFIDENCE_THRESHOLD = 0.75;

/**
 * Decides what happens to a submission.
 *
 * @param {object} input
 * @param {number} input.distanceMeters      recomputed server-side, never trusted from the client
 * @param {number} input.radiusMeters        from the bin document
 * @param {boolean} input.isDuplicate        from findDuplicate
 * @param {boolean} input.duplicateChecked   false when the hash could not be computed
 * @param {boolean} input.photoTrusted       true only for this user's trusted upload
 * @param {boolean} input.declarationValid   closed item vocabulary and plausible count
 * @param {boolean} input.locationValid      plausible latitude and longitude
 * @param {number} input.declaredItemCount
 * @param {object|null} input.screening      null when screening did not run
 * @param {number} input.screening.confidence      0-1
 * @param {number|null} input.screening.itemCount  null if the screen could not count
 * @param {boolean} input.screening.itemTypeMatches
 * @param {number} input.approvedToday
 * @param {number} input.dailyCap
 * @returns {{decision: 'autoApprove'|'review', flags: string[], reasons: string[]}}
 */
function decide({
  distanceMeters,
  radiusMeters,
  isDuplicate = false,
  // Defaults to false — "the check did not run" — which is the fail-closed
  // reading. A caller that forgets to pass this gets a review, not a silent
  // auto-approve. Mirrors `screening = null` above it.
  duplicateChecked = false,
  photoTrusted = false,
  declarationValid = false,
  locationValid = false,
  declaredItemCount,
  screening = null,
  approvedToday = 0,
  dailyCap = 3,
}) {
  const flags = [];

  // These checks validate the provenance and shape of the inputs before
  // interpreting their values. Defaults are false so a newly added caller that
  // forgets them routes to review instead of silently widening auto-approval.
  if (!photoTrusted) flags.push(FLAGS.PHOTO_UNTRUSTED);
  if (!declarationValid) flags.push(FLAGS.INVALID_DECLARATION);
  if (!locationValid) flags.push(FLAGS.INVALID_LOCATION);

  // 1. Geofence. The authoritative check, recomputed from stored coordinates.
  if (
    typeof distanceMeters !== 'number' ||
    Number.isNaN(distanceMeters) ||
    typeof radiusMeters !== 'number' ||
    distanceMeters > radiusMeters
  ) {
    flags.push(FLAGS.OUTSIDE_RADIUS);
  }

  // 2. Duplicate photograph, within this user's own history.
  //
  // Three states, not two, and conflating the first two is what made this
  // pipeline pay out on unchecked photographs. `isDuplicate: false` means
  // "compared against the user's history and found nothing"; it does NOT mean
  // "could not compare". `hashImage` throws on a missing cloud name, a non-200
  // from Cloudinary, an unexpected bit depth or a zlib error, and every one of
  // those used to arrive here indistinguishable from a clean result — no flag,
  // `flags.length === 0`, straight down the auto-approve lane with the duplicate
  // defence never having run.
  //
  // Exactly the reasoning already applied to `screening === null` below, and the
  // same danger.
  if (!duplicateChecked) {
    flags.push(FLAGS.HASH_UNAVAILABLE);
  } else if (isDuplicate) {
    flags.push(FLAGS.DUPLICATE_PHOTO);
  }

  // 3. Daily cap.
  if (approvedToday >= dailyCap) {
    flags.push(FLAGS.DAILY_CAP_REACHED);
  }

  // 4. Screening.
  if (screening === null) {
    // Not "no problems found" — not checked at all. Without this flag an
    // outage would silently auto-approve everything, which is the single most
    // dangerous failure mode this pipeline has.
    flags.push(FLAGS.SCREENING_UNAVAILABLE);
  } else {
    const confidence =
      typeof screening.confidence === 'number' ? screening.confidence : 0;

    if (confidence < CONFIDENCE_THRESHOLD) {
      flags.push(FLAGS.LOW_CONFIDENCE);
    }

    if (screening.itemTypeMatches === false) {
      flags.push(FLAGS.ITEM_TYPE_MISMATCH);
    }

    // Counting objects in a photograph is unreliable, so a mismatch flags for
    // review rather than rejecting. Auto-rejection on this signal would fire
    // constantly on honest users (§7.4).
    if (
      typeof screening.itemCount === 'number' &&
      typeof declaredItemCount === 'number' &&
      screening.itemCount !== declaredItemCount
    ) {
      flags.push(FLAGS.COUNT_MISMATCH);
    }
  }

  return {
    decision: flags.length === 0 ? 'autoApprove' : 'review',
    flags,
    reasons: flags.map((f) => FLAG_EXPLANATIONS[f] || f),
  };
}

/**
 * Whether an administrator can approve despite these flags.
 *
 * Most flags are advisory — a person looked, and a person may decide the
 * photograph is fine. The daily cap is not: approving past it breaches the
 * policy regardless of who is asking.
 */
function isApprovable(flags = []) {
  return !flags.some((flag) => BLOCKING_FLAGS.includes(flag));
}

/**
 * Whether a pending document carries trusted-service verification evidence.
 *
 * Field presence—not truthiness—matters because an unavailable hash/screen is
 * deliberately recorded as null. The fallback is for documents verified by
 * the release before `verificationCompleted` was added.
 */
function hasCompletedVerification(disposal) {
  if (!disposal || typeof disposal !== 'object') return false;
  return (
    disposal.verificationCompleted === true ||
    (Object.hasOwn(disposal, 'photoHash') &&
      Object.hasOwn(disposal, 'screenConfidence') &&
      Object.hasOwn(disposal, 'screenItemCount'))
  );
}

/** The sentence shown beside a flag in the review queue. */
function explain(flag) {
  return FLAG_EXPLANATIONS[flag] || flag;
}

module.exports = {
  FLAGS,
  FLAG_EXPLANATIONS,
  BLOCKING_FLAGS,
  CONFIDENCE_THRESHOLD,
  decide,
  isApprovable,
  hasCompletedVerification,
  explain,
};
