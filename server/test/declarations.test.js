/**
 * Put-on-market declarations (EPR-40 to EPR-43).
 *
 * The declaration is the denominator of every collection percentage Chokro
 * states, and it is the one figure on the whole certificate that the producer
 * supplies. So it is attested to by a named person, versioned immutably, and
 * corrected only by supersession — never edited in place.
 */

jest.mock('../src/firebase', () => ({
  db: jest.fn(),
  admin: {
    firestore: {
      FieldValue: {
        increment: (n) => ({ __increment: n }),
        arrayUnion: (...v) => ({ __arrayUnion: v }),
      },
      FieldPath: { documentId: () => '__name__' },
      Timestamp: {
        now: () => ({ toDate: () => new Date('2026-10-03T05:12:00Z') }),
        fromDate: (d) => ({ toDate: () => d }),
      },
    },
  },
  serverTimestamp: jest.fn(() => '__TS__'),
}));

const firebase = require('../src/firebase');
const declarations = require('../src/declarations');
const audit = require('../src/producerAudit');
const { fakeFirestore } = require('./helpers/firestoreFake');

let fs;

const LINES = [
  { category: 'rigid', massG: 18000000, units: 720000 },
  { category: 'flexible', massG: 9400000, units: 1880000 },
];

beforeEach(() => {
  jest.clearAllMocks();
  fs = fakeFirestore();
  firebase.db.mockReturnValue(fs);
});

const save = (overrides = {}) =>
  declarations.saveDraft({
    orgId: 'org_cola',
    periodId: '2026-09',
    lines: LINES,
    attestedByName: 'Nasrin Akhter',
    actorUid: 'uid_reporter',
    actorName: 'Nasrin Akhter',
    ...overrides,
  });

const submit = (overrides = {}) =>
  declarations.submitDeclaration({
    orgId: 'org_cola',
    periodId: '2026-09',
    attestedByName: 'Nasrin Akhter',
    actorUid: 'uid_owner',
    actorName: 'Nasrin Akhter',
    ...overrides,
  });

// ---------------------------------------------------------------------------
// Parsing the figures
// ---------------------------------------------------------------------------

describe('reading a mass in grams', () => {
  test('converts to integer milligrams', () => {
    expect(declarations.massMgFromGrams(10)).toBe(10000);
    expect(declarations.massMgFromGrams('10')).toBe(10000);
    expect(declarations.massMgFromGrams(0.001)).toBe(1);
  });

  test('refuses a thousands separator rather than reading past it', () => {
    // `parseFloat('61,000')` is 61 — so a producer who typed 61,000 g and had
    // 61 g recorded would have understated its obligation by a factor of a
    // thousand with no error shown, and understating the denominator is the
    // direction that flatters the percentage. The whole string is parsed or
    // nothing is.
    expect(declarations.massMgFromGrams('61,000')).toBeNull();
    expect(declarations.massMgFromGrams('18 000')).toBeNull();
    expect(declarations.massMgFromGrams('18_000')).toBeNull();
  });

  test('refuses anything that is not a number', () => {
    for (const bad of ['', '  ', 'abc', '12abc', '12kg', null, undefined, {}, [], NaN]) {
      expect(declarations.massMgFromGrams(bad)).toBeNull();
    }
  });

  test('refuses a negative mass and a non-finite one', () => {
    expect(declarations.massMgFromGrams(-1)).toBeNull();
    expect(declarations.massMgFromGrams(Infinity)).toBeNull();
  });

  test('accepts scientific notation, which is unambiguous', () => {
    // Unlikely from a form, but `1e6` has exactly one reading, so refusing it
    // would reject a correct figure rather than prevent a wrong one.
    expect(declarations.massMgFromGrams('1e6')).toBe(1000000000);
  });
});

describe('normalising lines', () => {
  test('keeps one line per gazette category', () => {
    const { lines, problems } = declarations.normalizeLines(LINES);
    expect(problems).toEqual([]);
    expect(lines).toHaveLength(2);
    expect(lines[0]).toMatchObject({ category: 'rigid', massMg: 18000000000 });
  });

  test('refuses an unknown category by name', () => {
    const { problems } = declarations.normalizeLines([
      { category: 'glass', massG: 1000, units: 10 },
    ]);
    expect(problems.join(' ')).toMatch(/glass/);
  });

  test('refuses a duplicated category', () => {
    // Two rows for the same category is ambiguous: it could mean the sum or it
    // could mean the second supersedes the first, and guessing either way
    // changes the producer's declared obligation.
    const { problems } = declarations.normalizeLines([
      { category: 'rigid', massG: 100, units: 1 },
      { category: 'rigid', massG: 200, units: 2 },
    ]);
    expect(problems.join(' ')).toMatch(/rigid/);
  });

  test('refuses an implausible mass rather than clamping it', () => {
    // Clamping would record a figure the producer never declared and then
    // certify against it.
    const { problems } = declarations.normalizeLines([
      { category: 'rigid', massG: 1e15, units: 1000 },
    ]);
    expect(problems).not.toEqual([]);
  });

  test('accepts an explicit nil declaration', () => {
    // EPR-42: "declared as zero" is a statement the producer can make, and a
    // different statement from "not declared".
    const { lines, problems } = declarations.normalizeLines([
      { category: 'eps', massG: 0, units: 0 },
    ]);
    expect(problems).toEqual([]);
    expect(lines[0].massMg).toBe(0);
  });

  test('refuses a half-entered line', () => {
    // Both zero is a legitimate nil declaration. One of the two zero is a
    // form somebody stopped filling in.
    expect(
      declarations.normalizeLines([{ category: 'rigid', massG: 0, units: 500 }]).problems,
    ).not.toEqual([]);
    expect(
      declarations.normalizeLines([{ category: 'rigid', massG: 500, units: 0 }]).problems,
    ).not.toEqual([]);
  });

  test('refuses a unit count that is not a whole number', () => {
    expect(
      declarations.normalizeLines([{ category: 'rigid', massG: 100, units: 1.5 }]).problems,
    ).not.toEqual([]);
  });

  test('orders lines by the gazette, not by how they arrived', () => {
    // So two periods' filings are directly comparable and an export does not
    // reshuffle.
    const { lines } = declarations.normalizeLines([
      { category: 'other', massG: 1, units: 1 },
      { category: 'rigid', massG: 1, units: 1 },
      { category: 'eps', massG: 1, units: 1 },
    ]);
    expect(lines.map((l) => l.category)).toEqual(['rigid', 'eps', 'other']);
  });

  test('refuses an empty declaration', () => {
    expect(declarations.normalizeLines([]).problems).not.toEqual([]);
    expect(declarations.normalizeLines(null).problems).not.toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// Drafting and submitting
// ---------------------------------------------------------------------------

describe('a draft', () => {
  test('stores integer milligrams and is not yet a denominator', async () => {
    await save();

    const stored = fs._store.get('putOnMarketDeclarations/org_cola_2026-09');
    expect(stored.status).toBe('draft');
    expect(stored.lines[0].massMg).toBe(18000000000);

    // Until it is submitted it has not been attested to, so nothing may
    // certify against it.
    await expect(
      declarations.declaredMassByCategory({ orgId: 'org_cola', periodId: '2026-09' }),
    ).resolves.toBeNull();
  });

  test('can be revised freely', async () => {
    await save();
    await save({ lines: [{ category: 'rigid', massG: 20000000, units: 800000 }] });

    const stored = fs._store.get('putOnMarketDeclarations/org_cola_2026-09');
    expect(stored.lines).toHaveLength(1);
    expect(stored.lines[0].massMg).toBe(20000000000);

    // No immutable version yet: versions are what submission creates.
    expect(fs._find(declarations.VERSIONS)).toHaveLength(0);
  });

  test('refuses a period that is not one', async () => {
    await expect(save({ periodId: '2026-9' })).rejects.toThrow(/reporting period/i);
  });

  test('reports every problem at once rather than the first', async () => {
    await expect(
      save({
        lines: [
          { category: 'glass', massG: 100, units: 1 },
          { category: 'rigid', massG: 'abc', units: 1 },
        ],
      }),
    ).rejects.toThrow(/glass[\s\S]*rigid|rigid[\s\S]*glass/);
  });
});

describe('submitting', () => {
  test('writes an immutable version row and copies the attestation on', async () => {
    await save();
    const result = await submit();

    const stored = fs._store.get('putOnMarketDeclarations/org_cola_2026-09');
    expect(stored.status).toBe('submitted');
    expect(stored.version).toBe(1);
    expect(stored.attestedByName).toBe('Nasrin Akhter');
    // The attestation text is copied onto the record, not referenced. A
    // producer attested to particular words, and those words must stay
    // readable even if the wording is later revised.
    expect(stored.attestationText).toBe(declarations.ATTESTATION_TEXT);

    const versions = fs._find(declarations.VERSIONS);
    expect(versions).toHaveLength(1);
    expect(versions[0].version).toBe(1);
    expect(versions[0].lines[0].massMg).toBe(18000000000);
  });

  test('names the offence in the attestation', async () => {
    // A producer signing a false declaration should be told, on the form, what
    // that is. "Attested under penalty" with no penalty named is decoration.
    expect(declarations.ATTESTATION_TEXT.length).toBeGreaterThan(60);
    expect(declarations.ATTESTATION_TEXT).toMatch(/false|offence|penalt/i);
  });

  test('requires a named person', async () => {
    await save();
    for (const attestedByName of [undefined, '', ' ', 'N']) {
      await expect(submit({ attestedByName })).rejects.toThrow(/name/i);
    }
  });

  test('refuses without a draft to submit', async () => {
    await expect(submit()).rejects.toThrow();
  });

  test('will not submit twice', async () => {
    await save();
    await submit();
    await expect(submit()).rejects.toThrow();
  });

  test('becomes the denominator only once submitted', async () => {
    await save();
    await submit();

    const byCategory = await declarations.declaredMassByCategory({
      orgId: 'org_cola',
      periodId: '2026-09',
    });
    expect(byCategory).toEqual({ rigid: 18000000000, flexible: 9400000000 });
  });

  test('records the submission in the audit chain', async () => {
    await save();
    await submit();

    const entries = fs._find(audit.COLLECTION);
    expect(entries.some((e) => e.action === audit.ACTIONS.DECLARATION_SUBMITTED)).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Corrections (EPR-43, EPR-30)
// ---------------------------------------------------------------------------

describe('correcting a submitted declaration', () => {
  beforeEach(async () => {
    await save();
    await submit();
  });

  test('requires a stated reason', async () => {
    for (const reason of [undefined, '', 'oops']) {
      await expect(
        declarations.openCorrection({
          orgId: 'org_cola', periodId: '2026-09', reason, actorUid: 'uid_owner',
        }),
      ).rejects.toThrow(/why/i);
    }
  });

  test('reopens for editing without destroying the submitted version', async () => {
    await declarations.openCorrection({
      orgId: 'org_cola',
      periodId: '2026-09',
      reason: 'A subsidiary’s volumes were omitted from the first filing.',
      actorUid: 'uid_owner',
      actorName: 'Nasrin Akhter',
    });

    const stored = fs._store.get('putOnMarketDeclarations/org_cola_2026-09');
    // Editable again, and so no longer a denominator — one editable status
    // rather than two, with the correction's provenance recorded alongside so
    // a reopened filing is still distinguishable from a first draft.
    expect(stored.status).toBe('draft');
    expect(stored.correctionReason).toMatch(/subsidiary/i);
    expect(stored.correctionOpenedBy).toBe('uid_owner');

    // The attestation does not carry forward. The new figures need their own.
    expect(stored.attestedAt).toBeNull();
    expect(stored.attestationText).toBeNull();

    // Version 1 is still there, unchanged. Past periods have to stay
    // reproducible (NFR-E-8), and a superseded figure is evidence of what was
    // declared at the time.
    const versions = fs._find(declarations.VERSIONS);
    expect(versions).toHaveLength(1);
    expect(versions[0].lines[0].massMg).toBe(18000000000);
    expect(versions[0].supersededReason).toMatch(/subsidiary/i);
  });

  test('stops being a denominator the moment it is reopened', async () => {
    await declarations.openCorrection({
      orgId: 'org_cola', periodId: '2026-09',
      reason: 'Omitted a subsidiary’s volumes.', actorUid: 'uid_owner',
    });

    // Nothing may certify against a figure the producer has withdrawn.
    await expect(
      declarations.declaredMassByCategory({ orgId: 'org_cola', periodId: '2026-09' }),
    ).resolves.toBeNull();
  });

  test('increments the version on resubmission', async () => {
    await declarations.openCorrection({
      orgId: 'org_cola', periodId: '2026-09',
      reason: 'Omitted a subsidiary’s volumes.', actorUid: 'uid_owner',
    });
    await save({ lines: [{ category: 'rigid', massG: 22000000, units: 900000 }] });
    await submit();

    const stored = fs._store.get('putOnMarketDeclarations/org_cola_2026-09');
    expect(stored.version).toBe(2);

    const versions = fs._find(declarations.VERSIONS).sort((a, b) => a.version - b.version);
    expect(versions).toHaveLength(2);
    expect(versions[0].lines[0].massMg).toBe(18000000000);
    expect(versions[1].lines[0].massMg).toBe(22000000000);
  });

  test('supersedes the passports that certified the old figure', async () => {
    // EPR-30: a corrected declaration must supersede every affected passport.
    // A certificate stating a percentage computed against a denominator the
    // producer has since withdrawn is a certificate stating something nobody
    // believes.
    fs._seed('plasticPassports', 'CHKR-PP-9F2K-7T4D', {
      serial: 'CHKR-PP-9F2K-7T4D',
      orgId: 'org_cola',
      periodId: '2026-09',
      status: 'issued',
    });
    fs._seed('plasticPassports', 'CHKR-PP-0000-0001', {
      serial: 'CHKR-PP-0000-0001',
      orgId: 'org_cola',
      periodId: '2026-08',
      status: 'issued',
    });

    await declarations.openCorrection({
      orgId: 'org_cola', periodId: '2026-09',
      reason: 'Omitted a subsidiary’s volumes.', actorUid: 'uid_owner',
    });

    expect(fs._store.get('plasticPassports/CHKR-PP-9F2K-7T4D').status).toBe('superseded');
    // A different period is untouched.
    expect(fs._store.get('plasticPassports/CHKR-PP-0000-0001').status).toBe('issued');
  });

  test('records the reason in the audit chain', async () => {
    await declarations.openCorrection({
      orgId: 'org_cola', periodId: '2026-09',
      reason: 'A subsidiary’s volumes were omitted.', actorUid: 'uid_owner',
    });

    const entry = fs._find(audit.COLLECTION)
      .find((e) => e.action === audit.ACTIONS.DECLARATION_CORRECTED);
    expect(entry).toBeTruthy();
    expect(entry.summary).toMatch(/subsidiary/i);
  });

  test('will not correct what was never submitted', async () => {
    await expect(
      declarations.openCorrection({
        orgId: 'org_other', periodId: '2026-09',
        reason: 'A perfectly good reason.', actorUid: 'uid_owner',
      }),
    ).rejects.toThrow();
  });
});

// ---------------------------------------------------------------------------
// The review queue (EPR-43)
// ---------------------------------------------------------------------------

describe('the declaration review queue', () => {
  test('highlights period-over-period variance (EPR-43)', async () => {
    // August: 27,400 kg. September: 8,000 kg. A move of that size "is either a
    // business change or a manipulation and either way an Admin should see it".
    await save({ periodId: '2026-08' });
    await submit({ periodId: '2026-08' });
    await save({ lines: [{ category: 'rigid', massG: 8000000, units: 300000 }] });
    await submit();

    const row = (await declarations.listForReview({}))
      .find((r) => r.periodId === '2026-09');

    expect(row.previousPeriod).toBe('2026-08');
    expect(row.previousMassMg).toBe(27400000000);
    expect(row.variance).toBeLessThan(-0.6);
  });

  test('reports no period-over-period variance for a first filing', async () => {
    // Null rather than zero: reporting no comparison as no change would hide
    // that there is nothing to compare against.
    await save();
    await submit();

    const row = (await declarations.listForReview({}))
      .find((r) => r.periodId === '2026-09');
    expect(row.variance).toBeNull();
    expect(row.previousMassMg).toBeNull();
  });

  test('surfaces a denominator withdrawn and refiled lower', async () => {
    // The threat §16 names: "producer understates put-on-market" for "a
    // flattering percentage". 27,400 kg gives about 18%; withdrawing it and
    // refiling 7,000 kg gives about 71% over the same collected mass.
    //
    // Period-over-period variance does not catch this — there is no previous
    // period here at all, and even with one the refiled figure might look no
    // stranger than the original did. What is unmistakable is the withdrawal.
    await save();
    await submit();
    await declarations.openCorrection({
      orgId: 'org_cola', periodId: '2026-09',
      reason: 'Restating after an internal review.', actorUid: 'uid_owner',
    });
    await save({ lines: [{ category: 'rigid', massG: 7000000, units: 300000 }] });
    await submit();

    const row = (await declarations.listForReview({}))
      .find((r) => r.periodId === '2026-09');

    expect(row.version).toBe(2);
    expect(row.priorVersionMassMg).toBe(27400000000);
    expect(row.correctionVariance).toBeLessThan(-0.7);
  });

  test('reports no correction variance on a first version', async () => {
    await save();
    await submit();

    const row = (await declarations.listForReview({}))
      .find((r) => r.periodId === '2026-09');
    expect(row.correctionVariance).toBeNull();
    expect(row.priorVersionMassMg).toBeNull();
  });

  test('is bounded', async () => {
    const queue = await declarations.listForReview({ limit: 5 });
    expect(queue.length).toBeLessThanOrEqual(5);
  });
});

// ---------------------------------------------------------------------------
// Reading back
// ---------------------------------------------------------------------------

describe('reading declarations', () => {
  test('returns null rather than a zeroed shape for a period with none', async () => {
    // EPR-42 again, at the accessor. A fallback that returned zeros would make
    // every undeclared period look like an explicit nil declaration.
    await expect(
      declarations.getDeclaration({ orgId: 'org_cola', periodId: '2026-01' }),
    ).resolves.toBeNull();
    await expect(
      declarations.declaredMassByCategory({ orgId: 'org_cola', periodId: '2026-01' }),
    ).resolves.toBeNull();
  });

  test('lists an organisation’s declarations, bounded', async () => {
    await save();
    const rows = await declarations.listDeclarations({ orgId: 'org_cola', limit: 10 });
    expect(rows).toHaveLength(1);
    expect(rows.length).toBeLessThanOrEqual(10);
  });

  test('lists the immutable versions for a period', async () => {
    await save();
    await submit();
    const versions = await declarations.listVersions({
      orgId: 'org_cola', periodId: '2026-09',
    });
    expect(versions).toHaveLength(1);
  });
});
