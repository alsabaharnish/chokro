/**
 * Tests for the per-identity rate limiter.
 *
 * The limiter guards the two routes that cost real money — `/disposals/:id/verify`
 * (a billed Groq vision call) and `/photos/*` (a Cloudinary upload) — so the
 * property that matters is that it counts per uid and actually refuses.
 */

const { rateLimit, _reset } = require('../src/rateLimit');

function res() {
  const r = { status: jest.fn(), json: jest.fn(), set: jest.fn() };
  r.status.mockReturnValue(r);
  r.json.mockReturnValue(r);
  return r;
}

const req = (uid, ip = '1.2.3.4') => ({ user: uid ? { uid } : undefined, ip });

beforeEach(() => {
  _reset();
  jest.spyOn(console, 'warn').mockImplementation(() => {});
});

afterEach(() => {
  jest.restoreAllMocks();
});

test('allows requests up to the limit and refuses the next', () => {
  const limit = rateLimit({ name: 't1', windowMs: 1000, max: 3 });
  const next = jest.fn();

  for (let i = 0; i < 3; i += 1) limit(req('u1'), res(), next);
  expect(next).toHaveBeenCalledTimes(3);

  const r = res();
  limit(req('u1'), r, next);

  expect(next).toHaveBeenCalledTimes(3);
  expect(r.status).toHaveBeenCalledWith(429);
});

test('counts per uid, so one account cannot exhaust another', () => {
  const limit = rateLimit({ name: 't2', windowMs: 1000, max: 1 });
  const next = jest.fn();

  limit(req('u1'), res(), next);
  limit(req('u1'), res(), next); // refused

  const r = res();
  limit(req('u2'), r, next);

  expect(next).toHaveBeenCalledTimes(2);
  expect(r.status).not.toHaveBeenCalled();
});

test('two accounts behind one NAT address are limited separately', () => {
  // Mobile users share carrier addresses. An IP-keyed limiter would punish a
  // neighbourhood for one person's behaviour.
  const limit = rateLimit({ name: 't3', windowMs: 1000, max: 1 });
  const next = jest.fn();
  const sharedIp = '203.0.113.9';

  limit(req('u1', sharedIp), res(), next);
  const r = res();
  limit(req('u2', sharedIp), r, next);

  expect(next).toHaveBeenCalledTimes(2);
  expect(r.status).not.toHaveBeenCalled();
});

test('falls back to the IP when there is no authenticated user', () => {
  const limit = rateLimit({ name: 't4', windowMs: 1000, max: 1 });
  const next = jest.fn();

  limit(req(null, '9.9.9.9'), res(), next);
  const r = res();
  limit(req(null, '9.9.9.9'), r, next);

  expect(r.status).toHaveBeenCalledWith(429);
});

test('the window expires and the allowance returns', () => {
  jest.useFakeTimers();
  try {
    const limit = rateLimit({ name: 't5', windowMs: 1000, max: 1 });
    const next = jest.fn();

    limit(req('u1'), res(), next);
    limit(req('u1'), res(), next); // refused
    expect(next).toHaveBeenCalledTimes(1);

    jest.advanceTimersByTime(1001);

    limit(req('u1'), res(), next);
    expect(next).toHaveBeenCalledTimes(2);
  } finally {
    jest.useRealTimers();
  }
});

test('a refusal carries Retry-After so a client can back off correctly', () => {
  const limit = rateLimit({ name: 't6', windowMs: 60_000, max: 1 });
  const next = jest.fn();

  limit(req('u1'), res(), next);
  const r = res();
  limit(req('u1'), r, next);

  expect(r.set).toHaveBeenCalledWith('Retry-After', expect.any(String));
  expect(r.json).toHaveBeenCalledWith(
    expect.objectContaining({ error: 'rate_limited' }),
  );
});

test('separate limiters keep separate counters', () => {
  const a = rateLimit({ name: 'a', windowMs: 1000, max: 1 });
  const b = rateLimit({ name: 'b', windowMs: 1000, max: 1 });
  const next = jest.fn();

  a(req('u1'), res(), next);
  const r = res();
  b(req('u1'), r, next);

  expect(next).toHaveBeenCalledTimes(2);
  expect(r.status).not.toHaveBeenCalled();
});
