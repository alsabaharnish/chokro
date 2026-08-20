/**
 * Tests for the CORS allowlist.
 *
 * This is the control that decides whether a browser page may make
 * authenticated calls to this service, and it was also the cause of a real
 * outage in local development: the only allowlisted dev origin was
 * `http://localhost:5000`, an unrelated project was holding port 5000, and so
 * every call from the Flutter web build was refused while Firestore reads kept
 * working. The screens that needed the server broke and nothing else did, which
 * is a genuinely confusing signal.
 *
 * The loopback escape hatch that fixes that is only safe if it is exact, so the
 * near-miss hostnames are the tests that matter here.
 */

const {
  parseAllowedOrigins,
  isAllowedOrigin,
} = require('../src/cors');

describe('parseAllowedOrigins', () => {
  it('splits, trims and drops blanks', () => {
    expect(parseAllowedOrigins(' a , b ,, c ')).toEqual(['a', 'b', 'c']);
  });

  it('an unset value is an empty list, not a crash', () => {
    expect(parseAllowedOrigins(undefined)).toEqual([]);
    expect(parseAllowedOrigins('')).toEqual([]);
  });
});

describe('the explicit allowlist', () => {
  const allowedOrigins = ['https://chokro-30887.web.app'];

  it('accepts an exact match', () => {
    expect(
      isAllowedOrigin('https://chokro-30887.web.app', { allowedOrigins }),
    ).toBe(true);
  });

  it('is exact about scheme, host and port', () => {
    for (const origin of [
      'http://chokro-30887.web.app',
      'https://chokro-30887.web.app:443',
      'https://chokro-30887.firebaseapp.com',
      'https://evil.com',
    ]) {
      expect(isAllowedOrigin(origin, { allowedOrigins })).toBe(false);
    }
  });

  it('refuses everything when the list is empty and loopback is off', () => {
    expect(isAllowedOrigin('https://anything.com', {})).toBe(false);
  });

  it('refuses a missing or non-string origin rather than throwing', () => {
    expect(isAllowedOrigin(undefined, { allowedOrigins })).toBe(false);
    expect(isAllowedOrigin('', { allowedOrigins })).toBe(false);
    expect(isAllowedOrigin(null, { allowedOrigins })).toBe(false);
  });
});

describe('the loopback escape hatch (development only)', () => {
  const dev = { allowLoopback: true };

  it('accepts any localhost port, which is the point', () => {
    // `flutter run -d chrome` picks a fresh port on every launch, so pinning one
    // in ALLOWED_ORIGINS cannot work reliably.
    for (const origin of [
      'http://localhost:5000',
      'http://localhost:53211',
      'http://127.0.0.1:41234',
      'https://localhost:8443',
      'http://localhost',
    ]) {
      expect(isAllowedOrigin(origin, dev)).toBe(true);
    }
  });

  it('THE BYPASSES: a hostname that merely contains "localhost" is refused', () => {
    // These are what an unanchored pattern would let through, and they are
    // registrable domains an attacker can actually own.
    for (const origin of [
      'http://localhost.evil.com',
      'https://localhost.evil.com',
      'http://notlocalhost:5000',
      'http://mylocalhost:3000',
      'http://127.0.0.1.evil.com',
      'http://evil.com/?x=http://localhost:5000',
    ]) {
      expect(isAllowedOrigin(origin, dev)).toBe(false);
    }
  });

  it('is off unless explicitly enabled', () => {
    // Deliberately opt-in rather than defaulted on by a NODE_ENV check: one
    // missing variable on a deploy must not silently remove the control.
    expect(isAllowedOrigin('http://localhost:53211', {})).toBe(false);
    expect(
      isAllowedOrigin('http://localhost:53211', { allowLoopback: false }),
    ).toBe(false);
  });

  it('does not widen the explicit list', () => {
    expect(
      isAllowedOrigin('https://evil.com', {
        allowedOrigins: ['https://chokro-30887.web.app'],
        allowLoopback: true,
      }),
    ).toBe(false);
  });
});
