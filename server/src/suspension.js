/**
 * Chokro — whether an account may act (F5.2, F5.3).
 *
 * THIS RULE IS WRITTEN THREE TIMES AND ALL THREE MUST AGREE
 *
 *   1. `isActiveWith()` in `firestore.rules`   — enforces on client writes
 *   2. `UserModel.isActiveAt()` in Dart        — so the UI can tell the truth
 *   3. here                                    — enforces on every server call
 *
 * `UserModel` documents the first two and says they must agree. This file is the
 * third, and it did not exist: `requireAuth` compared `profile.status` to
 * `'active'` as a plain string.
 *
 * That is wrong because of how a temporary suspension is designed to end. There
 * is no scheduler in this system — Cloud Functions need a billing card and the
 * free Render instance sleeps — so nothing ever rewrites `status` back to
 * `active`. A lapsed suspension is permanently `status: 'suspended'` plus a date
 * in the past, and every reader resolves that for itself.
 *
 * So once a 24-hour suspension expired:
 *
 *   - the rules said active, and let the user create a disposal
 *   - the Flutter UI said active, and offered every action
 *   - the server said `403 account_suspended`, for every call, forever
 *
 * Photo upload, verification, claim submission — all refused. The user could
 * start a submission and never complete one, with nothing in the interface
 * explaining why. F5.3's whole point is that the suspension is *temporary*, and
 * from the server's side it never was.
 *
 * Kept in its own module rather than inline in `auth.js` so it can be tested
 * against the same boundary cases as the other two copies, which is the only
 * thing that keeps three implementations honest.
 */

/**
 * Whether [profile] may act, evaluated at [now].
 *
 * @param {object|null|undefined} profile  a `users/{uid}` document's data
 * @param {Date} [now]                     injectable for tests
 * @returns {boolean}
 */
function isActiveProfile(profile, now = new Date()) {
  if (!profile) return false;

  if (profile.status === 'active') return true;

  // Anything other than 'active' or 'suspended' is not active. Fail closed, the
  // same way `UserModel.isActiveAt` treats an unrecognised status and the same
  // way an unrecognised disposal status falls back to pending.
  if (profile.status !== 'suspended') return false;

  const until = toDate(profile.suspendedUntil);

  // No date means a permanent suspension. Null must never read as "not
  // suspended" — it is the marker for the most severe case, not the absence of
  // one.
  if (until === null) return false;

  // STRICTLY after, matching both other copies exactly:
  //
  //   rules: u.suspendedUntil < request.time
  //   Dart:  now.isAfter(until)
  //
  // At the boundary instant all three say suspended. A `>=` here would let
  // someone act one instant before the rules would, and the mismatch would show
  // up as a write refused by the rules after the server had already accepted it.
  return now.getTime() > until.getTime();
}

/** Whether a profile may receive new marketplace orders. */
function isTradingProfile(profile, now = new Date()) {
  return (
    isActiveProfile(profile, now) &&
    (profile.role === 'seller' || profile.role === 'admin')
  );
}

/**
 * A Firestore date field as a `Date`, or null.
 *
 * The Admin SDK returns a `Timestamp`, but a document written by the emulator UI
 * or a migration can carry an ISO string or epoch millis. Anything unrecognised
 * is null, which reads as a permanent suspension — the safe direction for a
 * field whose whole job is deciding whether someone is blocked.
 */
function toDate(value) {
  if (!value) return null;
  if (typeof value.toDate === 'function') return value.toDate();
  if (value instanceof Date) return value;
  if (typeof value === 'string') {
    const parsed = new Date(value);
    return Number.isNaN(parsed.getTime()) ? null : parsed;
  }
  if (typeof value === 'number') return new Date(value);
  return null;
}

/**
 * Why an account is blocked, for the response body.
 *
 * Distinguishes a live temporary suspension from a permanent one, because they
 * call for different things from the user: waiting, or contacting an
 * administrator (and, once F5.4 lands, appealing).
 */
function suspensionMessage(profile, now = new Date()) {
  if (isActiveProfile(profile, now)) return null;

  if (!profile || profile.status !== 'suspended') {
    return 'This account is not active.';
  }

  const until = toDate(profile.suspendedUntil);
  if (until === null) {
    return 'This account is suspended. Contact a 3ZERO Admin.';
  }

  return `This account is suspended until ${until.toISOString()}.`;
}

module.exports = {
  isActiveProfile,
  isTradingProfile,
  suspensionMessage,
  toDate,
};
