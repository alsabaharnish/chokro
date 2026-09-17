/**
 * Firebase App Check enforcement (SEC-10, NFR-E-9).
 *
 * The failure mode: automated scraping or write-attempt traffic against a
 * corporate dataset by anything holding a valid ID token.
 */

jest.mock('../src/firebase', () => ({
  admin: { appCheck: jest.fn() },
}));

const firebase = require('../src/firebase');
const appCheck = require('../src/appCheck');

function request({ path = '/epr/me', method = 'GET', token } = {}) {
  return {
    path,
    method,
    get: jest.fn((header) =>
      header === 'X-Firebase-AppCheck' ? token : undefined,
    ),
  };
}

function response() {
  const res = { status: jest.fn(), json: jest.fn() };
  res.status.mockReturnValue(res);
  res.json.mockReturnValue(res);
  return res;
}

const original = process.env.APP_CHECK_ENFORCED;

afterEach(() => {
  if (original === undefined) {
    delete process.env.APP_CHECK_ENFORCED;
  } else {
    process.env.APP_CHECK_ENFORCED = original;
  }
  jest.clearAllMocks();
});

describe('when enforcement is off', () => {
  beforeEach(() => {
    delete process.env.APP_CHECK_ENFORCED;
  });

  test('every request passes and nothing is verified', async () => {
    // Deliberately not verify-and-ignore: a check that never blocks anything
    // would spend a round trip per request to produce a log line nobody reads.
    const next = jest.fn();
    await appCheck.verifyAppCheck(request(), response(), next);
    expect(next).toHaveBeenCalled();
    expect(firebase.admin.appCheck).not.toHaveBeenCalled();
  });

  test('the startup line says so, and names the flag', () => {
    const described = appCheck.describeEnforcement();
    expect(described).toContain('not enforced');
    expect(described).toContain('APP_CHECK_ENFORCED');
  });
});

describe('when enforcement is on', () => {
  beforeEach(() => {
    process.env.APP_CHECK_ENFORCED = 'true';
  });

  test('a valid attestation passes', async () => {
    const verifyToken = jest.fn().mockResolvedValue({ appId: 'app_1' });
    firebase.admin.appCheck.mockReturnValue({ verifyToken });

    const next = jest.fn();
    await appCheck.verifyAppCheck(request({ token: 'good' }), response(), next);

    expect(verifyToken).toHaveBeenCalledWith('good');
    expect(next).toHaveBeenCalled();
  });

  test('a missing header is refused, not warned about', async () => {
    // A control that logs and continues is not a control.
    const res = response();
    const next = jest.fn();
    await appCheck.verifyAppCheck(request(), res, next);

    expect(next).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(401);
    expect(res.json.mock.calls[0][0].error).toBe('app_check_required');
  });

  test('an unverifiable attestation is refused without saying why', async () => {
    // Distinguishing "expired" from "wrong project" from "malformed" tells
    // somebody probing the service which of those they got wrong.
    firebase.admin.appCheck.mockReturnValue({
      verifyToken: jest.fn().mockRejectedValue(new Error('token expired')),
    });
    const warnSpy = jest.spyOn(console, 'warn').mockImplementation(() => {});

    const res = response();
    const next = jest.fn();
    await appCheck.verifyAppCheck(request({ token: 'stale' }), res, next);

    expect(next).not.toHaveBeenCalled();
    expect(res.json.mock.calls[0][0].error).toBe('app_check_failed');
    expect(JSON.stringify(res.json.mock.calls[0][0])).not.toContain('expired');
    warnSpy.mockRestore();
  });

  test('a browser preflight passes — it cannot carry the header', async () => {
    // Refusing OPTIONS would break CORS for every legitimate client rather
    // than block any illegitimate one.
    const next = jest.fn();
    await appCheck.verifyAppCheck(
      request({ method: 'OPTIONS' }),
      response(),
      next,
    );
    expect(next).toHaveBeenCalled();
  });

  test('the health check stays reachable', async () => {
    // An attested health check cannot be used to diagnose an outage.
    const next = jest.fn();
    await appCheck.verifyAppCheck(request({ path: '/health' }), response(), next);
    expect(next).toHaveBeenCalled();
  });

  test('invitation redemption stays reachable', async () => {
    // The person clicking the link may be in a browser that has never loaded
    // the app, so there is no app instance to attest. Its protection is the
    // 256-bit single-use token and the per-IP limiter (SEC-8).
    const next = jest.fn();
    await appCheck.verifyAppCheck(
      request({ path: '/epr/invitations/redeem', method: 'POST' }),
      response(),
      next,
    );
    expect(next).toHaveBeenCalled();
  });

  test('the exemption list is short and every entry is named', () => {
    // An exemption has to be written down where a reviewer sees it, rather
    // than being implicit in middleware ordering.
    expect(appCheck.EXEMPT_PATHS).toEqual([
      '/health',
      '/epr/password-policy',
      '/epr/invitations/redeem',
    ]);
    expect(appCheck.isExempt('/epr/me')).toBe(false);
    expect(appCheck.isExempt('/disposals/abc/verify')).toBe(false);
  });

  test('the startup line says enforcement is on', () => {
    expect(appCheck.describeEnforcement()).toContain('ENFORCED');
  });
});

// ---------------------------------------------------------------------------
// The exemption that cannot be got wrong (SEC-7, SEC-10)
// ---------------------------------------------------------------------------

describe('certificate verification survives App Check enforcement', () => {
  /**
   * Recovered from the 2026-09-10 audit journals on 2026-09-17 and confirmed.
   *
   * `GET /passports/verify/:serial` was not exempt. The URL is PRINTED INTO
   * every certificate, the holder is a regulator or a customer with a piece of
   * paper and nothing to attest with, and the document is content-hashed — so
   * enforcing App Check would have invalidated every certificate already
   * issued, with reissuing all of them as the only remedy.
   *
   * NFR-E-9 and SEC-10 make enforcement release-blocking, so this was going to
   * be turned on.
   */
  test('a serial path is exempt', () => {
    expect(appCheck.isExempt('/passports/verify/CHKR-PP-ABCD-2345')).toBe(true);
  });

  test('every serial is exempt, not one literal string', () => {
    // The trap in the obvious fix. `EXEMPT_PATHS` is exact-match, and
    // `/passports/verify/<serial>` is a different string for every certificate
    // ever issued — adding it there would have looked like a fix, matched
    // nothing, and left the deploy log claiming an exemption was in place.
    for (const serial of [
      'CHKR-PP-0000-0000',
      'CHKR-PP-ZZZZ-9999',
      'CHKR-PP-9F2K-7T4D',
      'not-a-serial',
    ]) {
      expect(appCheck.isExempt(`/passports/verify/${serial}`)).toBe(true);
    }
  });

  test('the prefix cannot be widened by a similarly-named route', () => {
    // The trailing slash is why. A later `/passports/verify-all` must not
    // inherit an exemption written for certificate holders.
    expect(appCheck.isExempt('/passports/verify-all')).toBe(false);
    expect(appCheck.isExempt('/passports/verifyanything')).toBe(false);
    expect(appCheck.isExempt('/passports/verify')).toBe(false);
  });

  test('nothing else under /passports is exempt', () => {
    // The producer-facing passport routes have an app and an account, so they
    // attest like everything else.
    expect(appCheck.isExempt('/epr/passports')).toBe(false);
    expect(appCheck.isExempt('/epr/passports/CHKR-PP-ABCD-2345.pdf')).toBe(false);
  });

  test('the documented exemptions and the code agree on how many there are', () => {
    // The comment said "Two of them" while the array held three. A list whose
    // own description is wrong is a list nobody will check against the code.
    const total = appCheck.EXEMPT_PATHS.length + appCheck.EXEMPT_PREFIXES.length;
    expect(total).toBe(4);
  });
});
