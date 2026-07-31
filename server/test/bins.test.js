/**
 * Pure unit tests for bin validation and QR payload allocation (F2.1).
 *
 * No Firebase: `validateBin` and `generateQrPayload` touch nothing external,
 * which is why they are written as separate functions from `createBin`.
 */

const {
  generateQrPayload,
  validateBin,
  DEFAULT_RADIUS_METERS,
  MAX_RADIUS_METERS,
} = require('../src/bins');

describe('generateQrPayload', () => {
  test('uses the chokro:bin: prefix', () => {
    expect(generateQrPayload()).toMatch(/^chokro:bin:[0-9a-f]{12}$/);
  });

  test('does not repeat across many calls', () => {
    const seen = new Set();
    for (let i = 0; i < 2000; i += 1) seen.add(generateQrPayload());
    expect(seen.size).toBe(2000);
  });

  test('encodes no coordinates or user data', () => {
    // The payload names a bin and nothing else. If this ever changes, a
    // photographed code starts disclosing something.
    const payload = generateQrPayload();
    expect(payload.split(':')).toHaveLength(3);
    expect(payload).not.toMatch(/\d+\.\d+/); // no lat/lng
  });
});

describe('validateBin', () => {
  const valid = {
    label: 'Merul Badda — Block C gate',
    lat: 23.7808,
    lng: 90.4074,
    radiusMeters: 50,
  };

  test('accepts a well-formed bin', () => {
    expect(validateBin(valid)).toEqual([]);
  });

  test('requires a label', () => {
    expect(validateBin({ ...valid, label: '' })).toHaveLength(1);
    expect(validateBin({ ...valid, label: '   ' })).toHaveLength(1);
    expect(validateBin({ ...valid, label: undefined })).toHaveLength(1);
  });

  test('rejects an absurdly long label', () => {
    expect(validateBin({ ...valid, label: 'x'.repeat(121) })).toHaveLength(1);
  });

  test('rejects out-of-range coordinates', () => {
    expect(validateBin({ ...valid, lat: 91 })).not.toEqual([]);
    expect(validateBin({ ...valid, lat: -91 })).not.toEqual([]);
    expect(validateBin({ ...valid, lng: 181 })).not.toEqual([]);
    expect(validateBin({ ...valid, lng: -181 })).not.toEqual([]);
  });

  test('rejects non-numeric coordinates', () => {
    expect(validateBin({ ...valid, lat: '23.78' })).not.toEqual([]);
    expect(validateBin({ ...valid, lng: null })).not.toEqual([]);
    expect(validateBin({ ...valid, lat: NaN })).not.toEqual([]);
  });

  test('rejects Null Island as a failed GPS fix', () => {
    // 0,0 is what a failed fix reports. A bin there would accept submissions
    // from the middle of the Atlantic.
    expect(validateBin({ ...valid, lat: 0, lng: 0 })).not.toEqual([]);
  });

  test('accepts a legitimate zero on one axis only', () => {
    expect(validateBin({ ...valid, lat: 0 })).toEqual([]);
    expect(validateBin({ ...valid, lng: 0 })).toEqual([]);
  });

  test('requires a positive radius', () => {
    expect(validateBin({ ...valid, radiusMeters: 0 })).not.toEqual([]);
    expect(validateBin({ ...valid, radiusMeters: -10 })).not.toEqual([]);
  });

  test('caps the radius so the geofence still proves something', () => {
    expect(validateBin({ ...valid, radiusMeters: MAX_RADIUS_METERS })).toEqual([]);
    expect(
      validateBin({ ...valid, radiusMeters: MAX_RADIUS_METERS + 1 }),
    ).not.toEqual([]);
  });

  test('an omitted radius falls back to the default and passes', () => {
    const { radiusMeters, ...withoutRadius } = valid;
    expect(radiusMeters).toBe(50);
    expect(validateBin(withoutRadius)).toEqual([]);
    expect(DEFAULT_RADIUS_METERS).toBeGreaterThan(0);
  });

  test('reports every problem at once, not just the first', () => {
    const problems = validateBin({ label: '', lat: 999, lng: 999, radiusMeters: 0 });
    expect(problems.length).toBeGreaterThanOrEqual(4);
  });
});
