jest.mock('../src/firebase', () => ({
  db: jest.fn(),
  serverTimestamp: jest.fn(() => '__TS__'),
}));

const firebase = require('../src/firebase');
const eprPolicy = require('../src/eprPolicy');

function fakeDoc(data) {
  return {
    collection: () => ({
      doc: () => ({
        get: jest.fn().mockResolvedValue({
          exists: data !== undefined,
          data: () => data,
        }),
        set: jest.fn().mockResolvedValue(undefined),
      }),
    }),
  };
}

beforeEach(() => jest.clearAllMocks());

describe('defaults answer the open decisions they are meant to', () => {
  test('the mass tolerance and sample size match §15 decision 3', () => {
    expect(eprPolicy.DEFAULTS.massToleranceFraction).toBe(0.10);
    expect(eprPolicy.DEFAULTS.massAuditSampleSize).toBe(5);
  });

  test('category-average estimates are off, per §15 decision 4', () => {
    // "Attributing only what is recognised is a smaller number and a
    // defensible one, and a defensible number is the product."
    expect(eprPolicy.DEFAULTS.estimateUnmatchedMass).toBe(false);
  });

  test('confidence tiers match EPR-17', () => {
    expect(eprPolicy.DEFAULTS.highConfidenceThreshold).toBe(0.85);
    expect(eprPolicy.DEFAULTS.lowConfidenceThreshold).toBe(0.60);
    expect(eprPolicy.DEFAULTS.accuracyAuditSampleFraction).toBe(0.02);
  });

  test('the shortlist cap matches EPR-15', () => {
    expect(eprPolicy.DEFAULTS.skuShortlistCap).toBe(40);
  });
});

describe('normalising a stored document', () => {
  test('an absent document yields the documented defaults', () => {
    expect(eprPolicy.normalize(null)).toMatchObject(eprPolicy.DEFAULTS);
  });

  test('an out-of-range value falls back rather than clamping silently to the bound', () => {
    // Falling back to the documented default is more legible than clamping: a
    // tolerance of 0.25 in the database and 0.25 in effect is a decision
    // somebody made; 5.0 in the database and 0.25 in effect is not.
    expect(
      eprPolicy.normalize({ massToleranceFraction: 5 }).massToleranceFraction,
    ).toBe(0.10);
    expect(
      eprPolicy.normalize({ massToleranceFraction: 0 }).massToleranceFraction,
    ).toBe(0.10);
  });

  test('an in-range value is honoured', () => {
    expect(
      eprPolicy.normalize({ massToleranceFraction: 0.05 }).massToleranceFraction,
    ).toBe(0.05);
    expect(
      eprPolicy.normalize({ massAuditSampleSize: 10 }).massAuditSampleSize,
    ).toBe(10);
  });

  test('a non-numeric value falls back', () => {
    for (const bad of ['0.1', null, undefined, NaN, Infinity, {}]) {
      expect(
        eprPolicy.normalize({ massToleranceFraction: bad }).massToleranceFraction,
      ).toBe(0.10);
    }
  });

  test('a fractional sample size is rounded to a whole number of units', () => {
    expect(eprPolicy.normalize({ massAuditSampleSize: 7.6 }).massAuditSampleSize).toBe(8);
  });
});

describe('validate — the invariant a per-field bound cannot express', () => {
  test('the low tier must sit below the high tier', () => {
    // Otherwise EPR-17's three outcomes collapse into two with no way to tell
    // which a match got.
    expect(
      eprPolicy.validate({
        lowConfidenceThreshold: 0.9,
        highConfidenceThreshold: 0.85,
      }),
    ).toHaveLength(1);

    expect(
      eprPolicy.validate({
        lowConfidenceThreshold: 0.85,
        highConfidenceThreshold: 0.85,
      }),
    ).toHaveLength(1);
  });

  test('the defaults are valid', () => {
    expect(eprPolicy.validate(eprPolicy.DEFAULTS)).toEqual([]);
  });
});

describe('reading', () => {
  test('a missing document reads as the defaults', async () => {
    firebase.db.mockReturnValue(fakeDoc(undefined));
    await expect(eprPolicy.readPolicy()).resolves.toMatchObject(eprPolicy.DEFAULTS);
  });

  test('a read failure falls back rather than throwing', async () => {
    // A policy read is on the path of a mass verification. A verification that
    // fails because nobody has opened the policy screen is a worse failure than
    // one that uses a documented default.
    firebase.db.mockReturnValue({
      collection: () => ({
        doc: () => ({ get: jest.fn().mockRejectedValue(new Error('down')) }),
      }),
    });
    const errorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

    await expect(eprPolicy.readPolicy()).resolves.toMatchObject(eprPolicy.DEFAULTS);
    expect(errorSpy).toHaveBeenCalled();
    errorSpy.mockRestore();
  });

  test('a stored value overrides its default', async () => {
    firebase.db.mockReturnValue(fakeDoc({ massToleranceFraction: 0.05 }));
    const policy = await eprPolicy.readPolicy();
    expect(policy.massToleranceFraction).toBe(0.05);
    // And every unset field still has its default.
    expect(policy.massAuditSampleSize).toBe(5);
  });
});

describe('writing', () => {
  test('an invalid policy is refused with its problems', async () => {
    firebase.db.mockReturnValue(fakeDoc({}));
    await expect(
      eprPolicy.writePolicy(
        { lowConfidenceThreshold: 0.9, highConfidenceThreshold: 0.85 },
        { adminUid: 'admin_1' },
      ),
    ).rejects.toThrow('below the high-confidence one');
  });

  test('a valid policy is normalised before it is stored', async () => {
    const set = jest.fn().mockResolvedValue(undefined);
    firebase.db.mockReturnValue({
      collection: () => ({ doc: () => ({ set }) }),
    });

    const written = await eprPolicy.writePolicy(
      { massToleranceFraction: 0.05, massAuditSampleSize: 7.6, bogus: 'x' },
      { adminUid: 'admin_1' },
    );

    expect(written.massToleranceFraction).toBe(0.05);
    expect(written.massAuditSampleSize).toBe(8);
    // An unknown key never reaches the document.
    expect(set.mock.calls[0][0]).not.toHaveProperty('bogus');
    expect(set.mock.calls[0][0].updatedBy).toBe('admin_1');
  });
});

describe('isWithinTolerance (EPR-11)', () => {
  test('the worked example passes: 9.8 g measured against 10.0 g declared', () => {
    // Appendix A step 3: mean 9.8 g, within the ±10% tolerance, so the
    // declared figure is accepted.
    expect(
      eprPolicy.isWithinTolerance({
        declaredMg: 10000,
        measuredMeanMg: 9800,
        toleranceFraction: 0.10,
      }),
    ).toBe(true);
  });

  test('an overstated declaration is caught', () => {
    // The incentive EPR-11 exists to defeat: a heavier declared unit inflates
    // collected kilograms and any plastic credit.
    expect(
      eprPolicy.isWithinTolerance({
        declaredMg: 12000,
        measuredMeanMg: 9800,
        toleranceFraction: 0.10,
      }),
    ).toBe(false);
  });

  test('the boundary is inclusive on both sides', () => {
    // Exactly ±10% passes; one milligram beyond does not.
    expect(
      eprPolicy.isWithinTolerance({
        declaredMg: 10000,
        measuredMeanMg: 9000,
        toleranceFraction: 0.10,
      }),
    ).toBe(true);
    expect(
      eprPolicy.isWithinTolerance({
        declaredMg: 10000,
        measuredMeanMg: 11000,
        toleranceFraction: 0.10,
      }),
    ).toBe(true);
    expect(
      eprPolicy.isWithinTolerance({
        declaredMg: 10000,
        measuredMeanMg: 8999,
        toleranceFraction: 0.10,
      }),
    ).toBe(false);
  });

  test('a missing or nonsensical figure is never within tolerance', () => {
    // Fail closed: an unreadable measurement must not accept a declaration.
    for (const args of [
      { declaredMg: 0, measuredMeanMg: 9800 },
      { declaredMg: -1, measuredMeanMg: 9800 },
      { declaredMg: 10000, measuredMeanMg: 0 },
      { declaredMg: 10000, measuredMeanMg: NaN },
      { declaredMg: NaN, measuredMeanMg: 9800 },
    ]) {
      expect(
        eprPolicy.isWithinTolerance({ ...args, toleranceFraction: 0.10 }),
      ).toBe(false);
    }
  });

  test('the tolerance is taken from the caller, not from current policy', () => {
    // An audit judged last year against 10% must still read as judged against
    // 10% after an Admin tightens the policy — which is why the audit record
    // stores the tolerance that was in force.
    expect(
      eprPolicy.isWithinTolerance({
        declaredMg: 10000,
        measuredMeanMg: 9500,
        toleranceFraction: 0.10,
      }),
    ).toBe(true);
    expect(
      eprPolicy.isWithinTolerance({
        declaredMg: 10000,
        measuredMeanMg: 9500,
        toleranceFraction: 0.02,
      }),
    ).toBe(false);
  });
});
