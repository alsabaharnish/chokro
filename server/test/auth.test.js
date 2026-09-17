jest.mock('../src/firebase', () => ({
  auth: jest.fn(),
  db: jest.fn(),
}));

const firebase = require('../src/firebase');
const { requireAuth } = require('../src/auth');
const auth = require('../src/auth');

function request(header = 'Bearer valid-token') {
  return { get: jest.fn(() => header) };
}

function response() {
  const res = {
    status: jest.fn(),
    json: jest.fn(),
  };
  res.status.mockReturnValue(res);
  res.json.mockReturnValue(res);
  return res;
}

describe('requireAuth failure responses', () => {
  beforeEach(() => {
    jest.clearAllMocks();
    firebase.auth.mockReturnValue({
      verifyIdToken: jest.fn().mockResolvedValue({ uid: 'user_1' }),
    });
  });

  test('a Firestore profile outage returns a retryable 503', async () => {
    firebase.db.mockReturnValue({
      collection: () => ({
        doc: () => ({
          get: jest.fn().mockRejectedValue(new Error('upstream unavailable')),
        }),
      }),
    });

    const res = response();
    const next = jest.fn();
    const errorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

    await requireAuth(request(), res, next);

    expect(res.status).toHaveBeenCalledWith(503);
    expect(res.json).toHaveBeenCalledWith({
      error: 'account_service_unavailable',
      message: 'The account service is temporarily unavailable. Try again.',
    });
    expect(next).not.toHaveBeenCalled();
    errorSpy.mockRestore();
  });

  test('a missing token is a 401 and does not touch Firebase', async () => {
    const res = response();
    await requireAuth(request(''), res, jest.fn());
    expect(res.status).toHaveBeenCalledWith(401);
    expect(firebase.auth).not.toHaveBeenCalled();
    expect(firebase.db).not.toHaveBeenCalled();
  });
});

// ---------------------------------------------------------------------------
// SEC-9 — the absolute session lifetime
// ---------------------------------------------------------------------------

describe('a session has a maximum length, per role', () => {
  const now = 1_800_000_000;
  const at = (secondsAgo) => now - secondsAgo;
  const HOUR = 60 * 60;
  const DAY = 24 * HOUR;

  test('the portal roles are shorter than the consumer app, as SEC-9 requires', () => {
    // The requirement is comparative, and the consumer app had no limit at
    // all — so this assertion is the only thing making "shorter than" mean
    // anything.
    expect(auth.sessionMaxAgeFor('producer')).toBeLessThan(
      auth.sessionMaxAgeFor('buyer'),
    );
    expect(auth.sessionMaxAgeFor('admin')).toBeLessThan(
      auth.sessionMaxAgeFor('buyer'),
    );
    expect(auth.sessionMaxAgeFor('producer')).toBe(8 * HOUR);
  });

  test('a producer session dies after a working day', () => {
    expect(
      auth.sessionHasExpired({ role: 'producer', authTime: at(7 * HOUR) }, now),
    ).toBe(false);
    expect(
      auth.sessionHasExpired({ role: 'producer', authTime: at(9 * HOUR) }, now),
    ).toBe(true);
  });

  test('a Champion is not signed out on a producer schedule', () => {
    // Signing a Champion out every eight hours would cost disposals and
    // protect nothing — their account carries no compliance record.
    expect(
      auth.sessionHasExpired({ role: 'buyer', authTime: at(5 * DAY) }, now),
    ).toBe(false);
    expect(
      auth.sessionHasExpired({ role: 'buyer', authTime: at(31 * DAY) }, now),
    ).toBe(true);
  });

  test('an unknown role gets the STRICTEST limit, not the loosest', () => {
    // The direction that matters. A role this table has not heard of is more
    // likely to be a new privileged one than a new anonymous one.
    expect(auth.sessionMaxAgeFor('something-new')).toBe(
      auth.sessionMaxAgeFor('producer'),
    );
    expect(auth.sessionMaxAgeFor(undefined)).toBe(8 * HOUR);
  });

  test('a token with no auth_time is expired, not exempt', () => {
    // `auth_time` is on every Firebase ID token, so its absence means
    // something is wrong with the token — and this guards a failure where the
    // attacker chooses the token.
    expect(auth.sessionHasExpired({ role: 'producer' }, now)).toBe(true);
    expect(auth.sessionHasExpired({ role: 'producer', authTime: null }, now)).toBe(true);
    expect(auth.sessionHasExpired({ role: 'producer', authTime: 'x' }, now)).toBe(true);
    expect(auth.sessionHasExpired(null, now)).toBe(true);
  });

  test('a backwards clock jump does not sign everybody out', () => {
    // `auth_time` in the future is clock skew, not a session from tomorrow.
    // Treating the negative age as huge would end every session at once, on
    // the one day nobody could log in to investigate.
    expect(
      auth.sessionHasExpired({ role: 'producer', authTime: now + 600 }, now),
    ).toBe(false);
  });

  test('the limit follows the STORED role, not a claim', () => {
    // The check runs after the profile read for this reason: a producer
    // holding a stale token must not inherit a Champion's session length.
    expect(
      auth.sessionHasExpired({ role: 'producer', authTime: at(10 * HOUR) }, now),
    ).toBe(true);
    expect(
      auth.sessionHasExpired({ role: 'buyer', authTime: at(10 * HOUR) }, now),
    ).toBe(false);
  });
});
