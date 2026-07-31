const geo = require('../src/geo');
const policy = require('../src/pointsPolicy');

/**
 * Pure Node tests — no Firebase, no emulator, no network.
 *
 * These exist because `geo.js` and `pointsPolicy.js` are deliberate duplicates of
 * their Dart counterparts (§5.3). Duplication is only safe if something proves
 * the two stay in step, so the expected values here are the same ones asserted in
 * `test/core/geo_test.dart` and `test/core/points_policy_test.dart`. If a change
 * to one side breaks agreement, one of the two suites fails.
 */

describe('haversine distance', () => {
  const BIN_LAT = 23.7808;
  const BIN_LNG = 90.4074;

  test('is zero for an identical point', () => {
    expect(geo.haversineDistance(BIN_LAT, BIN_LNG, BIN_LAT, BIN_LNG)).toBe(0);
  });

  test('one thousandth of a degree of latitude is about 111 m', () => {
    const d = geo.haversineDistance(BIN_LAT, BIN_LNG, BIN_LAT + 0.001, BIN_LNG);
    expect(d).toBeCloseTo(111.195, 1);
  });

  test('a degree of longitude shortens with latitude', () => {
    const northSouth = geo.haversineDistance(
      BIN_LAT, BIN_LNG, BIN_LAT + 0.001, BIN_LNG,
    );
    const eastWest = geo.haversineDistance(
      BIN_LAT, BIN_LNG, BIN_LAT, BIN_LNG + 0.001,
    );
    expect(eastWest).toBeCloseTo(101.754, 1);
    expect(eastWest).toBeLessThan(northSouth);
  });

  test('matches known geodesic landmarks', () => {
    expect(geo.haversineDistance(0, 0, 0, 1)).toBeCloseTo(111194.9, 0);
    expect(geo.haversineDistance(0, 0, 90, 0)).toBeCloseTo(10007543.4, 0);

    const antipodal = geo.haversineDistance(0, 0, 0, 180);
    expect(Number.isNaN(antipodal)).toBe(false);
    expect(antipodal).toBeCloseTo(20015086.8, 0);
  });

  test('is symmetric', () => {
    const forward = geo.haversineDistance(BIN_LAT, BIN_LNG, 22.3569, 91.7832);
    const backward = geo.haversineDistance(22.3569, 91.7832, BIN_LAT, BIN_LNG);
    expect(forward).toBeCloseTo(backward, 6);
  });
});

describe('radius check', () => {
  const bin = { binLat: 23.7808, binLng: 90.4074, radiusMeters: 50 };

  test('accepts a point inside', () => {
    expect(
      geo.isWithinRadius({
        ...bin,
        capturedLat: 23.7808 + 0.0002,
        capturedLng: 90.4074,
      }),
    ).toBe(true);
  });

  test('rejects a point outside', () => {
    expect(
      geo.isWithinRadius({
        ...bin,
        capturedLat: 23.7808 + 0.001,
        capturedLng: 90.4074,
      }),
    ).toBe(false);
  });

  test('a non-positive radius accepts nothing', () => {
    expect(
      geo.isWithinRadius({
        ...bin,
        radiusMeters: 0,
        capturedLat: 23.7808,
        capturedLng: 90.4074,
      }),
    ).toBe(false);
  });
});

describe('coordinate plausibility', () => {
  test('rejects null island as a failed fix', () => {
    expect(geo.isPlausibleCoordinate(0, 0)).toBe(false);
    expect(geo.isPlausibleCoordinate(0, 90.4074)).toBe(true);
  });

  test('rejects out-of-range values', () => {
    expect(geo.isPlausibleCoordinate(91, 0)).toBe(false);
    expect(geo.isPlausibleCoordinate(23, 181)).toBe(false);
  });
});

describe('points policy defaults', () => {
  const p = policy.defaults();

  test('match §7.3', () => {
    expect(p.disposalAward).toBe(50);
    expect(p.claimAward).toBe(15);
    expect(p.claimQuotaPerWeek).toBe(3);
    expect(p.purchaseAwardPercent).toBe(5);
    expect(p.redemptionPointsPerBlock).toBe(100);
    expect(p.redemptionTakaPerBlock).toBe(10);
    expect(p.maxRedemptionPercentOfSubtotal).toBe(50);
    expect(p.lockoutHours).toBe(6);
    expect(p.dailyDisposalCap).toBe(3);
  });

  test('are internally consistent', () => {
    expect(policy.validate(p)).toEqual([]);
  });

  test('100 points buys 10 taka, so one disposal is worth 5', () => {
    expect(policy.pointsPerTaka(p)).toBe(10);
    expect(policy.takaForPoints(p, 100)).toBe(10);
    expect(policy.takaForPoints(p, p.disposalAward)).toBe(5);
  });
});

describe('points policy parsing', () => {
  test('falls back per-field on missing or malformed data', () => {
    const parsed = policy.fromDoc({
      disposalAward: 40,
      claimAward: 'not a number',
      lockoutHours: null,
    });
    expect(parsed.disposalAward).toBe(40);
    expect(parsed.claimAward).toBe(policy.DEFAULTS.claimAward);
    expect(parsed.lockoutHours).toBe(policy.DEFAULTS.lockoutHours);
  });

  test('an absent document yields the defaults', () => {
    expect(policy.fromDoc(null)).toEqual(policy.defaults());
    expect(policy.fromDoc(undefined)).toEqual(policy.defaults());
  });

  test('reads tolerantly but does not silently fix an invalid policy', () => {
    const parsed = policy.fromDoc({ claimAward: 90 });
    expect(parsed.claimAward).toBe(90);
    expect(policy.validate(parsed).length).toBeGreaterThan(0);
  });
});

describe('points policy validation', () => {
  test('rejects a claim award that meets or beats the disposal award', () => {
    const equal = { ...policy.defaults(), claimAward: 50 };
    const greater = { ...policy.defaults(), claimAward: 80 };
    expect(policy.validate(equal).length).toBeGreaterThan(0);
    expect(policy.validate(greater)[0]).toContain('must pay less');
  });

  test('rejects non-positive awards and windows', () => {
    expect(
      policy.validate({ ...policy.defaults(), disposalAward: 0 }).length,
    ).toBeGreaterThan(0);
    expect(
      policy.validate({ ...policy.defaults(), lockoutHours: 0 }).length,
    ).toBeGreaterThan(0);
  });

  test('rejects a lockout window longer than a week', () => {
    expect(
      policy.validate({ ...policy.defaults(), lockoutHours: 200 }).length,
    ).toBeGreaterThan(0);
  });

  test('accepts a plausible admin adjustment', () => {
    const adjusted = { ...policy.defaults(), redemptionTakaPerBlock: 20 };
    expect(policy.validate(adjusted)).toEqual([]);
    expect(policy.pointsPerTaka(adjusted)).toBe(5);
  });
});

describe('purchase award', () => {
  const p = policy.defaults();

  test('is 5% of payable, rounded down', () => {
    expect(policy.purchaseAward(p, 100)).toBe(5);
    expect(policy.purchaseAward(p, 199)).toBe(9);
    expect(policy.purchaseAward(p, 1000)).toBe(50);
  });

  test('is zero for trivial amounts', () => {
    expect(policy.purchaseAward(p, 19)).toBe(0);
    expect(policy.purchaseAward(p, 0)).toBe(0);
  });
});

describe('lockout window', () => {
  const p = policy.defaults();

  test('expires six hours after it opens', () => {
    const from = new Date('2026-07-31T08:00:00Z');
    expect(policy.lockoutExpiry(p, from).toISOString()).toBe(
      '2026-07-31T14:00:00.000Z',
    );
  });

  test('crosses a day boundary correctly', () => {
    const from = new Date('2026-07-31T23:00:00Z');
    expect(policy.lockoutExpiry(p, from).toISOString()).toBe(
      '2026-08-01T05:00:00.000Z',
    );
  });
});

describe('ISO week keys', () => {
  test('produce a zero-padded sortable key', () => {
    expect(policy.isoWeekKey(new Date('2026-07-31T00:00:00Z'))).toBe('2026-W31');
    expect(policy.isoWeekKey(new Date('2026-01-01T00:00:00Z'))).toBe('2026-W01');
  });

  test('a new week starts on Monday, not Sunday', () => {
    expect(policy.isoWeekKey(new Date('2026-08-02T00:00:00Z'))).toBe('2026-W31');
    expect(policy.isoWeekKey(new Date('2026-08-03T00:00:00Z'))).toBe('2026-W32');
  });

  test('early January can belong to the previous ISO year', () => {
    expect(policy.isoWeekKey(new Date('2027-01-01T00:00:00Z'))).toBe('2026-W53');
  });

  test('late December can belong to the next ISO year', () => {
    expect(policy.isoWeekKey(new Date('2024-12-30T00:00:00Z'))).toBe('2025-W01');
    expect(policy.isoWeekKey(new Date('2025-12-29T00:00:00Z'))).toBe('2026-W01');
  });

  test('time of day does not affect the key', () => {
    expect(policy.isoWeekKey(new Date('2026-07-31T23:59:00Z'))).toBe(
      policy.isoWeekKey(new Date('2026-07-31T00:01:00Z')),
    );
  });
});
