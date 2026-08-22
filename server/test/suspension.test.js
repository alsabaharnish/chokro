/**
 * Whether an account may act, server side (F5.2, F5.3).
 *
 * The rule exists in three places and they must agree:
 *
 *   1. `isActiveWith()` in firestore.rules   — `u.suspendedUntil < request.time`
 *   2. `UserModel.isActiveAt()` in Dart      — `now.isAfter(until)`
 *   3. `isActiveProfile()` here
 *
 * `requireAuth` used to compare `profile.status` to `'active'` as a string, which
 * is the one reading that cannot work: a temporary suspension is never rewritten
 * back to `active`, because nothing runs that could do it. So a lapsed 24-hour
 * suspension left the rules and the UI treating a user as active while every
 * server call returned 403 — permanently. These pin the agreement.
 */

const {
  isActiveProfile,
  isTradingProfile,
  suspensionMessage,
  toDate,
} = require('../src/suspension');

/** A Firestore Timestamp, as the Admin SDK hands one back. */
const timestamp = (date) => ({ toDate: () => date });

const NOW = new Date('2026-08-18T12:00:00Z');
const hoursFromNow = (h) => new Date(NOW.getTime() + h * 3600 * 1000);

describe('isActiveProfile', () => {
  test('an active account may act', () => {
    expect(isActiveProfile({ status: 'active' }, NOW)).toBe(true);
  });

  test('an indefinite suspension blocks', () => {
    // No date at all. Null must never read as "not suspended" — it marks the
    // most severe case, not the absence of one.
    expect(isActiveProfile({ status: 'suspended' }, NOW)).toBe(false);
    expect(
      isActiveProfile({ status: 'suspended', suspendedUntil: null }, NOW),
    ).toBe(false);
  });

  test('a suspension ending in the future blocks', () => {
    expect(
      isActiveProfile(
        { status: 'suspended', suspendedUntil: timestamp(hoursFromNow(5)) },
        NOW,
      ),
    ).toBe(false);
  });

  test('a lapsed suspension no longer blocks', () => {
    // THE REGRESSION. `status` still reads 'suspended' and always will, so the
    // old string comparison refused this user every call, forever, while the
    // rules and the UI both let them act.
    expect(
      isActiveProfile(
        { status: 'suspended', suspendedUntil: timestamp(hoursFromNow(-1)) },
        NOW,
      ),
    ).toBe(true);
  });

  test('a 24-hour suspension lapses after 24 hours, not never', () => {
    const profile = {
      status: 'suspended',
      suspendedUntil: timestamp(hoursFromNow(24)),
    };

    expect(isActiveProfile(profile, hoursFromNow(23))).toBe(false);
    expect(isActiveProfile(profile, hoursFromNow(25))).toBe(true);
  });

  test('the boundary instant is still suspended', () => {
    // Matches the other two copies exactly. The rules use `<` and Dart uses
    // `isAfter`, both strict, so all three say suspended at the exact instant.
    // A `>=` here would accept a call the rules would then refuse.
    const until = hoursFromNow(3);
    const profile = { status: 'suspended', suspendedUntil: timestamp(until) };

    expect(isActiveProfile(profile, until)).toBe(false);
    expect(isActiveProfile(profile, new Date(until.getTime() + 1))).toBe(true);
  });

  test('an unrecognised status fails closed', () => {
    // Same as `UserModel.isActiveAt`, which treats anything it does not know as
    // not active.
    expect(isActiveProfile({ status: 'banned' }, NOW)).toBe(false);
    expect(isActiveProfile({ status: '' }, NOW)).toBe(false);
    expect(isActiveProfile({}, NOW)).toBe(false);
  });

  test('a missing profile fails closed', () => {
    expect(isActiveProfile(null, NOW)).toBe(false);
    expect(isActiveProfile(undefined, NOW)).toBe(false);
  });

  test('a stale date on an active account does not suspend it', () => {
    // `reinstateUser` deletes the field, but a document written before that was
    // added could still carry one. `status: 'active'` wins.
    expect(
      isActiveProfile(
        { status: 'active', suspendedUntil: timestamp(hoursFromNow(50)) },
        NOW,
      ),
    ).toBe(true);
  });

  test('an admin is subject to suspension like anyone else', () => {
    // The rules prove this separately: a suspended admin cannot act as an admin.
    expect(
      isActiveProfile(
        { status: 'suspended', role: 'admin', suspendedUntil: null },
        NOW,
      ),
    ).toBe(false);
  });
});

describe('isTradingProfile', () => {
  test('only active sellers and administrators may receive new orders', () => {
    expect(isTradingProfile({ status: 'active', role: 'seller' }, NOW)).toBe(true);
    expect(isTradingProfile({ status: 'active', role: 'admin' }, NOW)).toBe(true);
    expect(isTradingProfile({ status: 'active', role: 'buyer' }, NOW)).toBe(false);
  });

  test('a seller cannot trade during a live suspension', () => {
    expect(
      isTradingProfile(
        { status: 'suspended', role: 'seller', suspendedUntil: hoursFromNow(1) },
        NOW,
      ),
    ).toBe(false);
  });

  test('a seller may trade after a timed suspension lapses', () => {
    expect(
      isTradingProfile(
        { status: 'suspended', role: 'seller', suspendedUntil: hoursFromNow(-1) },
        NOW,
      ),
    ).toBe(true);
  });
});

describe('toDate', () => {
  test('reads a Firestore Timestamp', () => {
    const date = hoursFromNow(1);
    expect(toDate(timestamp(date))).toEqual(date);
  });

  test('reads a Date, an ISO string and epoch millis', () => {
    const date = new Date('2026-08-18T12:00:00Z');
    expect(toDate(date)).toEqual(date);
    expect(toDate('2026-08-18T12:00:00Z')).toEqual(date);
    expect(toDate(date.getTime())).toEqual(date);
  });

  test('unparseable values are null, which reads as permanent', () => {
    // The safe direction for a field whose only job is deciding who is blocked.
    expect(toDate('not a date')).toBeNull();
    expect(toDate({})).toBeNull();
    expect(toDate(null)).toBeNull();
    expect(toDate(undefined)).toBeNull();
  });
});

describe('suspensionMessage', () => {
  test('an active account has nothing to say', () => {
    expect(suspensionMessage({ status: 'active' }, NOW)).toBeNull();
  });

  test('a lapsed suspension has nothing to say', () => {
    expect(
      suspensionMessage(
        { status: 'suspended', suspendedUntil: timestamp(hoursFromNow(-1)) },
        NOW,
      ),
    ).toBeNull();
  });

  test('a timed suspension names the date', () => {
    // The user's next move is to wait, and they cannot decide that without
    // knowing how long.
    const message = suspensionMessage(
      { status: 'suspended', suspendedUntil: timestamp(hoursFromNow(5)) },
      NOW,
    );
    expect(message).toContain('2026-08-18T17:00:00');
  });

  test('an indefinite suspension points at a 3ZERO Admin', () => {
    // No date to wait for, so the only route is a person.
    const message = suspensionMessage({ status: 'suspended' }, NOW);
    expect(message).toContain('3ZERO Admin');
    expect(message).not.toContain('until');
  });
});
