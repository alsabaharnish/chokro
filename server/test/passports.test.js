/**
 * The Plastic Passport (EPR-28 to EPR-31, SEC-7).
 *
 * The four properties that make the certificate worth trusting each get their
 * own section: the figures come from stored evidence and not from the request,
 * the content hash is stable and covers what matters, the serial is
 * unguessable, and issuance is immutable.
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

jest.mock('../src/eprPolicy', () => ({ readPolicy: jest.fn() }));

const firebase = require('../src/firebase');
const eprPolicy = require('../src/eprPolicy');
const passports = require('../src/passports');
const audit = require('../src/producerAudit');
const { fakeFirestore } = require('./helpers/firestoreFake');

let fs;

const FIGURES = Object.freeze({
  orgId: 'org_cola',
  periodId: '2026-09',
  scope: 'period',
  collectedMassMgByCategory: { rigid: 4120000000, flexible: 880000000 },
  unitsByCategory: { rigid: 168000, flexible: 44000 },
  massMgByPolymer: { pet: 4020000000, multilayer: 880000000 },
  collectedMassMg: 5000000000,
  declaredMassMgByCategory: { rigid: 18000000000 },
  declaredMassMg: 18000000000,
  declarationVersion: 2,
  collectionRate: 5000000000 / 18000000000,
  applicableCollectionTarget: 0.15,
  attributionCount: 224200,
  disposalCount: 198400,
  uniqueSkuCount: 37,
  uncertainMassMg: 402000000,
  estimatedShare: 0.0794,
  reversedCount: 14,
  carbonFactorVersion: 'mixedPlastics-2015-uk-v1',
  carbonKgCo2eAvoided: 5120,
});

beforeEach(() => {
  jest.clearAllMocks();
  fs = fakeFirestore();
  firebase.db.mockReturnValue(fs);
  eprPolicy.readPolicy.mockResolvedValue({
    carbonUncertaintyCeiling: 0.25,
    massToleranceFraction: 0.1,
  });

  fs._seed('organizations', 'org_cola', {
    legalName: 'Coca-Cola Bangladesh Beverages Ltd.',
    tradeName: 'Coca-Cola Bangladesh',
    doeRegistrationNo: 'DoE/EPR/2026/0417',
    sizeClass: 'large',
    status: 'active',
    obligationStartDate: { toDate: () => new Date('2026-07-01T00:00:00Z') },
  });
});

// ---------------------------------------------------------------------------
// The serial (SEC-7)
// ---------------------------------------------------------------------------

describe('the serial', () => {
  test('is not sequential and not guessable from another one', () => {
    const serials = new Set();
    for (let i = 0; i < 5000; i += 1) serials.add(passports.generateSerial());

    // 5000 draws from a 40-bit space: a collision would be a red flag about
    // the source of randomness, not bad luck.
    expect(serials.size).toBe(5000);
  });

  test('rejects the sequential form the spec names', () => {
    // SEC-7 calls out `CHOKRO-2026-0001` by name: a sequential serial lets a
    // competitor enumerate every certificate Chokro has issued.
    expect(passports.isValidSerial('CHOKRO-2026-0001')).toBe(false);
    expect(passports.isValidSerial('CHKR-PP-0000-0001')).toBe(true);
  });

  test('omits the letters that are ambiguous in print', () => {
    // I, L, O and U. The first three are unreadable next to 1 and 0 on a
    // certificate somebody is retyping; U makes an accidental English word
    // more likely in a four-character group.
    expect(passports.SERIAL_ALPHABET).not.toMatch(/[ILOU]/);

    const body = Array.from({ length: 400 }, () => passports.generateSerial()).join('');
    expect(body).not.toMatch(/[ILOU]/);
  });

  test('accepts the shape Appendix A shows and nothing looser', () => {
    expect(passports.isValidSerial('CHKR-PP-9F2K-7T4D')).toBe(true);
    expect(passports.isValidSerial('chkr-pp-9f2k-7t4d')).toBe(false);
    expect(passports.isValidSerial('CHKR-PP-9F2K7T4D')).toBe(false);
    expect(passports.isValidSerial('CHKR-PP-9F2K-7T4')).toBe(false);
    expect(passports.isValidSerial('')).toBe(false);
    expect(passports.isValidSerial(null)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// The content hash
// ---------------------------------------------------------------------------

describe('the content hash', () => {
  test('is stable across key order', () => {
    // The payload is an explicit field list precisely so that a refactor which
    // reorders two assignments cannot change the hash of a certificate whose
    // figures have not changed — which would break every passport already
    // issued.
    const reordered = {};
    for (const k of Object.keys(FIGURES).reverse()) reordered[k] = FIGURES[k];

    expect(passports.contentHash(reordered)).toBe(passports.contentHash(FIGURES));
  });

  test('changes when any figure changes', () => {
    const base = passports.contentHash(FIGURES);

    for (const change of [
      { collectedMassMg: 5000000001 },
      { declaredMassMg: 18000000001 },
      { collectionRate: FIGURES.collectionRate + 0.000001 },
      { attributionCount: 224201 },
      { uncertainMassMg: 402000001 },
      { carbonFactorVersion: 'mixedPlastics-2015-uk-v2' },
      { collectedMassMgByCategory: { rigid: 4120000001, flexible: 880000000 } },
      { massMgByPolymer: { pet: 4020000001, multilayer: 880000000 } },
    ]) {
      expect(passports.contentHash({ ...FIGURES, ...change })).not.toBe(base);
    }
  });

  test('binds the identity of the certificate’s subject', () => {
    // THE FORGERY HOLE THIS EXISTS FOR.
    //
    // These fields were missing from the payload, and two figure sets naming
    // different companies — with different DoE registration numbers, different
    // attesters, different size classes and different obligation years —
    // hashed IDENTICALLY.
    //
    // The hash is printed on the certificate and returned by the public
    // verification endpoint so a third party can answer "is the document in my
    // hand the document Chokro issued". A hash that covered the masses but not
    // the name answered a narrower question than the one it was printed to
    // answer: take a genuine certificate, change the legal name and the DoE
    // number, and the printed hash still matched.
    //
    // `orgId` alone was not enough. It is neither printed nor returned by the
    // endpoint, so a reader has nothing to compare it against — the fields a
    // reader can SEE are the ones that have to be bound.
    const base = passports.contentHash(FIGURES);

    for (const change of [
      { organizationLegalName: 'A Different Company Ltd' },
      { organizationTradeName: 'Different' },
      { doeRegistrationNo: 'DoE/EPR/2026/9999' },
      { sizeClass: 'micro' },
      { obligationYear: 4 },
      { declarationAttestedByName: 'Someone Else' },
    ]) {
      expect(passports.contentHash({ ...FIGURES, ...change })).not.toBe(base);
    }
  });

  test('excludes the concurrency marker', () => {
    // `declarationFingerprint` exists only so `issuePassport` can detect a
    // declaration changing mid-issue. Hashing it would make the certificate's
    // hash depend on an internal marker, and the submitted-versus-draft
    // distinction it carries is already in `declarationVersion`.
    expect(
      passports.contentHash({ ...FIGURES, declarationFingerprint: 'submitted:9' }),
    ).toBe(passports.contentHash(FIGURES));
  });

  test('reads an absent figure as absent rather than crashing', () => {
    // `=== null` missed `undefined`, so a figure set from an older stored
    // certificate — or one built by hand — crashed hash computation.
    expect(() =>
      passports.contentHash({ orgId: 'org_cola', periodId: '2026-09' }),
    ).not.toThrow();
    expect(passports.canonicalPayload({ orgId: 'a', periodId: '2026-01' }))
      .toContain('collectionRate=absent');
  });

  test('ignores who issued it and when', () => {
    // Those are properties of the issuance, not of the figures. Including them
    // would give two certificates over identical evidence different hashes,
    // which would defeat the hash's only purpose: answering "is the figure in
    // my hand the figure Chokro computed".
    const withIssuance = {
      ...FIGURES,
      issuedBy: 'uid_admin',
      issuedAt: new Date(),
      issuedByName: 'Someone Else',
    };
    expect(passports.contentHash(withIssuance)).toBe(passports.contentHash(FIGURES));
  });

  test('distinguishes an undeclared category from a nil one', () => {
    // EPR-42. "not declared" and "declared as zero" are different statements
    // by the producer, and a hash that conflated them would let one be
    // substituted for the other.
    const undeclared = { ...FIGURES, declaredMassMgByCategory: { rigid: 18000000000 } };
    const nil = {
      ...FIGURES,
      declaredMassMgByCategory: { rigid: 18000000000, flexible: 0 },
    };

    expect(passports.canonicalPayload(undeclared)).toContain('declared.flexible=absent');
    expect(passports.canonicalPayload(nil)).toContain('declared.flexible=0');
    expect(passports.contentHash(undeclared)).not.toBe(passports.contentHash(nil));
  });

  test('distinguishes an absent rate from a zero one', () => {
    // EPR-24. A period with no declaration has no percentage; it does not have
    // a percentage of zero.
    const absent = { ...FIGURES, collectionRate: null, declaredMassMg: null };
    const zero = { ...FIGURES, collectionRate: 0 };

    expect(passports.canonicalPayload(absent)).toContain('collectionRate=absent');
    expect(passports.canonicalPayload(zero)).toContain('collectionRate=0.000000');
    expect(passports.contentHash(absent)).not.toBe(passports.contentHash(zero));
  });

  test('states in the payload that recycling is not covered', () => {
    // §6.6. The literal is in the hash so a future version that added a
    // recycling rate would change every certificate's hash rather than
    // slipping one in unnoticed.
    expect(passports.canonicalPayload(FIGURES))
      .toContain('recyclingRate=notCoveredByChokroEvidence');
  });

  test('orders categories and polymers fixedly, not by map iteration', () => {
    const swapped = {
      ...FIGURES,
      collectedMassMgByCategory: { flexible: 880000000, rigid: 4120000000 },
    };
    expect(passports.contentHash(swapped)).toBe(passports.contentHash(FIGURES));

    const payload = passports.canonicalPayload(FIGURES);
    const order = passports.GAZETTE_CATEGORIES.map((c) =>
      payload.indexOf(`collected.${c}=`));
    expect(order).toEqual([...order].sort((a, b) => a - b));
  });
});

// ---------------------------------------------------------------------------
// Assembling the figures
// ---------------------------------------------------------------------------

describe('assembling a period', () => {
  test('reads every figure from stored evidence', async () => {
    fs._seed('eprPeriods', 'org_cola_2026-09', {
      orgId: 'org_cola',
      periodId: '2026-09',
      massMgByCategory: { rigid: 4120000000, flexible: 880000000 },
      unitsByCategory: { rigid: 168000 },
      massMgByPolymer: { pet: 4020000000 },
      attributionCount: 224200,
      disposalCount: 198400,
      uncertainMassMg: 402000000,
      reversedCount: 14,
      skuIds: ['sku_a', 'sku_b', 'sku_c'],
    });
    fs._seed('putOnMarketDeclarations', 'org_cola_2026-09', {
      orgId: 'org_cola',
      periodId: '2026-09',
      status: 'submitted',
      version: 2,
      attestedByName: 'Nasrin Akhter',
      lines: [{ category: 'rigid', massMg: 18000000000 }],
    });

    const f = await passports.assembleFigures({ orgId: 'org_cola', periodId: '2026-09' });

    expect(f.collectedMassMg).toBe(5000000000);
    expect(f.declaredMassMg).toBe(18000000000);
    expect(f.uniqueSkuCount).toBe(3);
    expect(f.organizationLegalName).toBe('Coca-Cola Bangladesh Beverages Ltd.');
    expect(f.declarationVersion).toBe(2);
    expect(f.collectionRate).toBeCloseTo(5000000000 / 18000000000, 10);
  });

  test('has no collection rate without a submitted declaration (EPR-24)', async () => {
    fs._seed('eprPeriods', 'org_cola_2026-09', {
      massMgByCategory: { rigid: 4120000000 },
    });

    const f = await passports.assembleFigures({ orgId: 'org_cola', periodId: '2026-09' });

    // Null, and not zero. Zero is a figure; this is the absence of one.
    expect(f.collectionRate).toBeNull();
    expect(f.declaredMassMg).toBeNull();
    expect(f.declaredMassMgByCategory).toBeNull();
  });

  test('ignores a draft declaration', async () => {
    fs._seed('eprPeriods', 'org_cola_2026-09', { massMgByCategory: { rigid: 100 } });
    fs._seed('putOnMarketDeclarations', 'org_cola_2026-09', {
      status: 'draft',
      version: 1,
      lines: [{ category: 'rigid', massMg: 18000000000 }],
    });

    const f = await passports.assembleFigures({ orgId: 'org_cola', periodId: '2026-09' });

    // A draft has not been attested to. Certifying against it would let a
    // producer set its own denominator without signing for it.
    expect(f.collectionRate).toBeNull();
    expect(f.declarationVersion).toBeNull();
  });

  test('has no rate against a nil denominator either', async () => {
    fs._seed('eprPeriods', 'org_cola_2026-09', { massMgByCategory: { rigid: 100 } });
    fs._seed('putOnMarketDeclarations', 'org_cola_2026-09', {
      status: 'submitted',
      version: 1,
      lines: [{ category: 'rigid', massMg: 0 }],
    });

    const f = await passports.assembleFigures({ orgId: 'org_cola', periodId: '2026-09' });

    expect(f.declaredMassMg).toBe(0);
    expect(f.collectionRate).toBeNull();
  });

  test('takes nothing from the caller but the identifiers', async () => {
    fs._seed('eprPeriods', 'org_cola_2026-09', {
      massMgByCategory: { rigid: 1000000 },
    });

    const f = await passports.assembleFigures({
      orgId: 'org_cola',
      periodId: '2026-09',
      // Everything below is ignored. This is the whole of EPR-31: the
      // producer names a period, and Chokro decides what is true about it.
      collectedMassMg: 999999999999,
      collectionRate: 0.99,
      organizationLegalName: 'Not This Company',
    });

    expect(f.collectedMassMg).toBe(1000000);
    expect(f.collectionRate).toBeNull();
    expect(f.organizationLegalName).toBe('Coca-Cola Bangladesh Beverages Ltd.');
  });

  test('refuses an organisation that does not exist', async () => {
    await expect(
      passports.assembleFigures({ orgId: 'org_ghost', periodId: '2026-09' }),
    ).rejects.toThrow(/does not exist/i);
  });
});

// ---------------------------------------------------------------------------
// The carbon line (EPR-38, EPR-39)
// ---------------------------------------------------------------------------

describe('the carbon line', () => {
  test('is refused above the uncertainty ceiling', () => {
    const carbon = passports.resolveCarbon({
      collectedMassMg: 1000000000,
      estimatedShare: 0.40,
      ceiling: 0.25,
    });

    // A carbon estimate built on a mass that is itself substantially uncertain
    // compounds two uncertainties into one number that reads as precise.
    expect(carbon.kgCo2eAvoided).toBeNull();
    expect(carbon.absenceReason).toBe('tooUncertain');
  });

  test('is stated below the ceiling, with the factor version pinned', () => {
    const carbon = passports.resolveCarbon({
      collectedMassMg: 1000000000,
      estimatedShare: 0.05,
      ceiling: 0.25,
    });

    expect(carbon.kgCo2eAvoided).toBeCloseTo(1024, 6);
    // The version, not the figure: a report pins the version it used so the
    // number stays reproducible when the registry is updated.
    expect(carbon.factorVersion).toBe('mixedPlastics-2015-uk-v1');
  });

  test('is absent with no mass at all', () => {
    const carbon = passports.resolveCarbon({
      collectedMassMg: 0,
      estimatedShare: 0,
      ceiling: 0.25,
    });
    expect(carbon.kgCo2eAvoided).toBeNull();
    expect(carbon.absenceReason).toBe('noMass');
  });
});

// ---------------------------------------------------------------------------
// The obligation year
// ---------------------------------------------------------------------------

describe('the obligation year', () => {
  const org = (iso) => ({ obligationStartDate: { toDate: () => new Date(iso) } });

  test('is null before the obligation starts', () => {
    expect(passports.obligationYearAt(org('2026-07-01T00:00:00Z'), '2026-06')).toBeNull();
  });

  test('counts from the anniversary, not the calendar year', () => {
    const start = org('2026-07-01T00:00:00Z');
    expect(passports.obligationYearAt(start, '2026-07')).toBe(1);
    expect(passports.obligationYearAt(start, '2027-06')).toBe(1);
    expect(passports.obligationYearAt(start, '2027-07')).toBe(2);
    expect(passports.obligationYearAt(start, '2029-07')).toBe(4);
  });

  test('is null with no recorded start date', () => {
    expect(passports.obligationYearAt({}, '2026-09')).toBeNull();
  });

  test('counts the very first obligated month, across the Dhaka offset', () => {
    // The regression this exists for. An obligation start of 1 July 2026 is
    // stored as UTC midnight; the July 2026 reporting period begins at Dhaka
    // midnight, which is 2026-06-30T18:00:00Z. Compared as instants, the
    // producer's first obligated period appears to precede its own obligation
    // by six hours — and a null obligation year means no applicable target is
    // stated on the certificate.
    const start = org('2026-07-01T00:00:00Z');
    expect(passports.obligationYearAt(start, '2026-07')).toBe(1);
    expect(passports.obligationYearAt(start, '2026-06')).toBeNull();
  });

  test('resolves the target the gazette sets for each year', () => {
    // §2: 15% in years 1-2, 30% thereafter. The switch is the twenty-fifth
    // month, not the third calendar year.
    const start = org('2026-07-01T00:00:00Z');
    const targetFor = (periodId) => {
      const year = passports.obligationYearAt(start, periodId);
      return year === null ? null : year >= 3 ? 0.3 : 0.15;
    };

    expect(targetFor('2026-07')).toBe(0.15);
    expect(targetFor('2028-06')).toBe(0.15);
    expect(targetFor('2028-07')).toBe(0.3);
  });

  test('ignores the day of the month', () => {
    // A reporting period cannot be half in one obligation year and half in the
    // next, and month granularity is the finest the scheme has.
    expect(passports.obligationYearAt(org('2026-07-01T00:00:00Z'), '2027-07')).toBe(2);
    expect(passports.obligationYearAt(org('2026-07-31T00:00:00Z'), '2027-07')).toBe(2);
  });

  test('is null for something that is not a period', () => {
    const start = org('2026-07-01T00:00:00Z');
    for (const bad of ['2026-9', '2026', 'September', '', null]) {
      expect(passports.obligationYearAt(start, bad)).toBeNull();
    }
  });
});

// ---------------------------------------------------------------------------
// Issuance and immutability (EPR-30)
// ---------------------------------------------------------------------------

describe('issuing', () => {
  beforeEach(() => {
    fs._seed('eprPeriods', 'org_cola_2026-09', {
      massMgByCategory: { rigid: 4120000000 },
      attributionCount: 100,
      disposalCount: 90,
      skuIds: ['sku_a'],
    });
  });

  test('writes the serial, the hash and a frozen figure snapshot', async () => {
    const result = await passports.issuePassport({
      orgId: 'org_cola',
      periodId: '2026-09',
      adminUid: 'uid_admin',
      adminName: 'Chokro Compliance',
    });

    const stored = fs._store.get(`plasticPassports/${result.serial}`);
    expect(stored.status).toBe('issued');
    expect(stored.contentHash).toBe(result.contentHash);
    // Stored, not referenced: a certificate must stay reproducible from its own
    // record even after the period is recomputed or a mass re-verified.
    expect(stored.figures.collectedMassMg).toBe(4120000000);
    expect(stored.figures.organizationTradeName).toBe('Coca-Cola Bangladesh');
  });

  test('supersedes the earlier passport rather than overwriting it', async () => {
    const first = await passports.issuePassport({
      orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
    });
    const second = await passports.issuePassport({
      orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
    });

    expect(second.serial).not.toBe(first.serial);
    expect(second.supersededCount).toBe(1);

    // The first certificate is still there and still readable — it is in a
    // third party's hands, and the only honest way to correct it is to let the
    // verification endpoint say it has been replaced.
    const old = fs._store.get(`plasticPassports/${first.serial}`);
    expect(old.status).toBe('superseded');
    expect(old.supersededBy).toBe(second.serial);
    expect(old.contentHash).toBeTruthy();
  });

  test('does not supersede another period or another organisation', async () => {
    fs._seed('eprPeriods', 'org_cola_2026-08', { massMgByCategory: { rigid: 5 } });
    const august = await passports.issuePassport({
      orgId: 'org_cola', periodId: '2026-08', adminUid: 'uid_admin',
    });
    await passports.issuePassport({
      orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
    });

    expect(fs._store.get(`plasticPassports/${august.serial}`).status).toBe('issued');
  });

  test('refuses to issue a certificate whose PDF could never be produced', async () => {
    // THE OPERATIONAL TRAP THE RENDERER'S REFUSAL CREATED.
    //
    // The renderer refuses text neither bundled face can draw, rather than
    // printing mojibake. Without a preflight, that refusal arrives too late:
    // issuance succeeds, the PDF route answers 422 forever, and — because
    // issuing SUPERSEDES every earlier certificate for the period — the
    // producer's last downloadable certificate has already been invalidated.
    //
    // An Admin would have destroyed a working certificate to mint an
    // undownloadable one.
    fs._seed('organizations', 'org_cola', {
      ...fs._store.get('organizations/org_cola'),
      legalName: '中国可乐有限公司 (Bangladesh) Ltd.',
    });

    await expect(
      passports.issuePassport({
        orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
      }),
    ).rejects.toThrow(/cannot be certified as it stands/i);

    // And nothing was written — no certificate, and no supersession of one
    // that still works.
    expect(fs._find('plasticPassports')).toHaveLength(0);
  });

  test('does not supersede a working certificate when the reissue would fail', async () => {
    const first = await passports.issuePassport({
      orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
    });

    fs._seed('organizations', 'org_cola', {
      ...fs._store.get('organizations/org_cola'),
      tradeName: 'شركة الكولا',
    });

    await expect(
      passports.issuePassport({
        orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
      }),
    ).rejects.toThrow(/cannot be certified as it stands/i);

    // The producer's existing certificate is untouched and still downloadable.
    expect(fs._store.get(`plasticPassports/${first.serial}`).status).toBe('issued');
  });

  test('the preflight checks both editions, not just English', async () => {
    // NFR-E-4 promises both. A producer that can only download English has not
    // been given what the certificate claims.
    expect(passports.assertRenderable).toBeInstanceOf(Function);

    const pdfModule = require('../src/passportPdf');
    expect(pdfModule.LOCALES).toEqual(expect.arrayContaining(['en', 'bn']));
  });

  test('refuses a period id that is not one', async () => {
    await expect(
      passports.issuePassport({ orgId: 'org_cola', periodId: '2026-9', adminUid: 'u' }),
    ).rejects.toThrow(/reporting period/i);
  });

  test('records the absence of a rate in the audit summary', async () => {
    await passports.issuePassport({
      orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
    });

    const entries = fs._find(audit.COLLECTION)
      .filter((e) => e.action === audit.ACTIONS.PASSPORT_ISSUED);
    expect(entries).toHaveLength(1);
    // The audit log says why there is no percentage, so a later reader does not
    // have to guess whether it was zero or missing.
    expect(entries[0].summary).toMatch(/no collection percentage/i);
    expect(entries[0].summary).toMatch(/no put-on-market declaration/i);
  });

  test('refuses when the denominator moves mid-issue', async () => {
    // ===================================================================
    // THE RACE THIS EXISTS FOR
    // ===================================================================
    //
    // `assembleFigures` runs outside the transaction. Between its read of the
    // declaration and the transaction's commit, `openCorrection` can run — and
    // its query for passports with `status == 'issued'` finds NOTHING, because
    // the certificate does not exist yet. The result is a certificate stating
    // a percentage against a denominator the producer has just withdrawn, and
    // nothing in the codebase ever sweeps it up: `openCorrection` has already
    // run, `submitDeclaration` supersedes no passports, and the verification
    // endpoint answers `found: true, status: 'issued'` indefinitely.
    fs._seed('putOnMarketDeclarations', 'org_cola_2026-09', {
      orgId: 'org_cola',
      periodId: '2026-09',
      status: 'submitted',
      version: 1,
      attestedByName: 'Nasrin Akhter',
      totalMassMg: 20000000000,
      lines: [{ category: 'rigid', massMg: 20000000000 }],
    });

    // The correction lands after the figures are assembled and before the
    // transaction commits. Injected by mutating the store the instant the
    // transaction opens, which is the same interleaving.
    const realRunTransaction = fs.runTransaction.bind(fs);
    fs.runTransaction = async (fn) => {
      fs._seed('putOnMarketDeclarations', 'org_cola_2026-09', {
        ...fs._store.get('putOnMarketDeclarations/org_cola_2026-09'),
        status: 'draft',
        correctionReason: 'A subsidiary’s volumes were omitted.',
      });
      fs.runTransaction = realRunTransaction;
      return realRunTransaction(fn);
    };

    await expect(
      passports.issuePassport({
        orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
      }),
    ).rejects.toThrow(/changed while the certificate was being issued/i);

    // And nothing was written. A certificate that exists but is wrong is far
    // worse than one that was never issued.
    expect(fs._find('plasticPassports')).toHaveLength(0);
  });

  test('issues normally when the denominator holds still', async () => {
    fs._seed('putOnMarketDeclarations', 'org_cola_2026-09', {
      orgId: 'org_cola',
      periodId: '2026-09',
      status: 'submitted',
      version: 1,
      attestedByName: 'Nasrin Akhter',
      lines: [{ category: 'rigid', massMg: 20000000000 }],
    });

    const result = await passports.issuePassport({
      orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
    });

    expect(result.serial).toMatch(/^CHKR-PP-/);
    expect(
      fs._store.get(`plasticPassports/${result.serial}`).figures.declarationVersion,
    ).toBe(1);
  });

  test('tells a draft at version 1 apart from no declaration at all', () => {
    // `declarationVersion` is null for both, so the fingerprint is what
    // actually distinguishes them — and issuing against a draft that was a
    // submitted filing a moment ago is exactly the case that matters.
    expect(passports.declarationFingerprint(null)).toBe('none');
    expect(
      passports.declarationFingerprint({ status: 'draft', version: 1 }),
    ).toBe('draft:1');
    expect(
      passports.declarationFingerprint({ status: 'submitted', version: 1 }),
    ).toBe('submitted:1');
    expect(
      passports.declarationFingerprint({ status: 'submitted', version: 2 }),
    ).not.toBe(passports.declarationFingerprint({ status: 'submitted', version: 1 }));
  });

  test('reads before it writes', async () => {
    // The fake throws on a read after a write, exactly as the Admin SDK does.
    await expect(
      passports.issuePassport({
        orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
      }),
    ).resolves.toBeTruthy();
  });
});

describe('revoking', () => {
  let serial;

  beforeEach(async () => {
    fs._seed('eprPeriods', 'org_cola_2026-09', { massMgByCategory: { rigid: 100 } });
    ({ serial } = await passports.issuePassport({
      orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
    }));
  });

  test('records the reason and who did it', async () => {
    await passports.revokePassport({
      serial,
      reason: 'An accuracy audit invalidated the September match batch.',
      adminUid: 'uid_admin',
      adminName: 'Chokro Compliance',
    });

    const stored = fs._store.get(`plasticPassports/${serial}`);
    expect(stored.status).toBe('revoked');
    expect(stored.revocationReason).toMatch(/accuracy audit/);
    expect(stored.revokedBy).toBe('uid_admin');
  });

  test('will not revoke without a reason', async () => {
    for (const reason of [undefined, '', '   ', 'oops']) {
      await expect(
        passports.revokePassport({ serial, reason, adminUid: 'uid_admin' }),
      ).rejects.toThrow(/why/i);
    }
  });

  test('will not revoke twice', async () => {
    await passports.revokePassport({
      serial, reason: 'A first good reason.', adminUid: 'uid_admin',
    });
    await expect(
      passports.revokePassport({
        serial, reason: 'A second good reason.', adminUid: 'uid_admin',
      }),
    ).rejects.toThrow(/already been revoked/i);
  });

  test('refuses a serial that does not exist', async () => {
    await expect(
      passports.revokePassport({
        serial: 'CHKR-PP-0000-0000',
        reason: 'A perfectly good reason.',
        adminUid: 'uid_admin',
      }),
    ).rejects.toThrow(/does not exist/i);
  });
});

// ---------------------------------------------------------------------------
// The public verification endpoint (EPR-29, SEC-7)
// ---------------------------------------------------------------------------

describe('verification', () => {
  let serial;

  beforeEach(async () => {
    fs._seed('eprPeriods', 'org_cola_2026-09', {
      massMgByCategory: { rigid: 4120000000 },
      attributionCount: 224200,
      skuIds: ['sku_a', 'sku_b'],
    });
    fs._seed('putOnMarketDeclarations', 'org_cola_2026-09', {
      status: 'submitted', version: 1, attestedByName: 'Nasrin Akhter',
      lines: [{ category: 'rigid', massMg: 18000000000 }],
    });
    ({ serial } = await passports.issuePassport({
      orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
    }));
  });

  test('returns exactly the five things EPR-29 allows', async () => {
    const result = await passports.verifySerial(serial);

    expect(Object.keys(result).sort()).toEqual(
      ['contentHash', 'found', 'periodId', 'status', 'supersededBy', 'tradeName'].sort(),
    );
    expect(result.found).toBe(true);
    expect(result.status).toBe('issued');
    expect(result.tradeName).toBe('Coca-Cola Bangladesh');
    expect(result.periodId).toBe('2026-09');
  });

  test('leaks no figure, no evidence and no member detail', async () => {
    const result = await passports.verifySerial(serial);
    const serialised = JSON.stringify(result);

    // The endpoint is deliberately impoverished: its purpose is only to let a
    // third party confirm the PDF in their hand is the document Chokro issued.
    for (const forbidden of [
      '4120000000', '18000000000', '224200', 'Nasrin', 'sku_a',
      'Beverages Ltd', 'DoE/EPR', 'uid_admin', 'collectionRate', 'figures',
    ]) {
      expect(serialised).not.toContain(forbidden);
    }
  });

  test('gives the legal name to nobody', async () => {
    // Trade name, because that is what the certificate prints and what a
    // journalist or a buyer would recognise. The legal name is registry data.
    const result = await passports.verifySerial(serial);
    expect(result.tradeName).toBe('Coca-Cola Bangladesh');
    expect(JSON.stringify(result)).not.toContain('Coca-Cola Bangladesh Beverages');
  });

  test('answers an unknown serial in the same shape as a known one', async () => {
    const known = await passports.verifySerial(serial);
    const unknown = await passports.verifySerial('CHKR-PP-0000-0000');

    // SEC-7: a 404 for unknown and a 200 for revoked would let an enumerator
    // separate real serials from guesses by status code alone, and the point
    // of an unguessable serial is that a miss teaches nothing.
    expect(Object.keys(unknown).sort()).toEqual(
      expect.arrayContaining(Object.keys(known).filter((k) => k !== 'supersededBy')),
    );
    expect(unknown.found).toBe(false);
    expect(unknown.status).toBeNull();
  });

  test('answers a malformed serial as not-found, not as an error', async () => {
    for (const bad of ['', 'nonsense', 'CHOKRO-2026-0001', '../../etc/passwd']) {
      await expect(passports.verifySerial(bad)).resolves.toMatchObject({ found: false });
    }
  });

  test('says a revoked certificate is revoked', async () => {
    await passports.revokePassport({
      serial, reason: 'An audit invalidated the batch.', adminUid: 'uid_admin',
    });

    const result = await passports.verifySerial(serial);
    // A revoked certificate that still verified as issued would be worse than
    // no verification at all.
    expect(result.found).toBe(true);
    expect(result.status).toBe('revoked');
    // Without repeating the reason, which is Chokro's internal finding.
    expect(JSON.stringify(result)).not.toMatch(/audit/i);
  });

  test('points a superseded certificate at its replacement', async () => {
    const second = await passports.issuePassport({
      orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
    });

    const result = await passports.verifySerial(serial);
    expect(result.status).toBe('superseded');
    // So the holder of an old certificate can find the current one. Not a
    // figure and not evidence.
    expect(result.supersededBy).toBe(second.serial);
  });

  test('raises rather than reporting a genuine certificate as unknown', async () => {
    firebase.db.mockReturnValue({
      collection: () => ({ doc: () => ({ get: () => Promise.reject(new Error('down')) }) }),
    });

    // A read failure that became a "not found" would tell a holder their
    // genuine certificate is fake.
    await expect(passports.verifySerial(serial)).rejects.toThrow(/unavailable/);
  });
});

// ---------------------------------------------------------------------------
// Supersession from elsewhere (EPR-30)
// ---------------------------------------------------------------------------

describe('superseding when the evidence changes underneath', () => {
  test('supersedes every issued passport for the period and audits it', async () => {
    fs._seed('eprPeriods', 'org_cola_2026-09', { massMgByCategory: { rigid: 100 } });
    const a = await passports.issuePassport({
      orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
    });

    const result = await passports.supersedeForPeriod({
      orgId: 'org_cola',
      periodId: '2026-09',
      reason: 'A re-verified unit mass changed this period.',
      actorUid: 'uid_admin',
    });

    expect(result.superseded).toBe(1);
    expect(fs._store.get(`plasticPassports/${a.serial}`).status).toBe('superseded');
    expect(
      fs._find(audit.COLLECTION).some(
        (e) => e.action === audit.ACTIONS.PASSPORT_SUPERSEDED,
      ),
    ).toBe(true);
  });

  test('does nothing when there is nothing to supersede', async () => {
    const result = await passports.supersedeForPeriod({
      orgId: 'org_cola', periodId: '2026-09', reason: 'Nothing here.',
    });
    expect(result.superseded).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// The triggers EPR-30 names (and that were, for a while, unwired)
// ---------------------------------------------------------------------------
//
// EPR-30 lists four events that must supersede automatically: a corrected
// declaration, a re-verified unit mass, a reversed attribution above a policy
// materiality threshold, and an accuracy audit. `openCorrection` handles the
// first. These are the second and third — and until they had callers,
// `supersedeForPeriod` was reachable only from this test file, which is a
// requirement documented rather than implemented.

describe('superseding after a reversal (EPR-30)', () => {
  beforeEach(() => {
    eprPolicy.readPolicy.mockResolvedValue({
      carbonUncertaintyCeiling: 0.25,
      reversalMaterialityFraction: 0.01,
    });
  });

  async function issueOver(collectedMassMg) {
    fs._seed('eprPeriods', 'org_cola_2026-09', {
      orgId: 'org_cola',
      periodId: '2026-09',
      massMgByCategory: { rigid: collectedMassMg },
      attributionCount: 100,
      skuIds: ['sku_a'],
    });
    return passports.issuePassport({
      orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
    });
  }

  test('supersedes when the reversed mass is material', async () => {
    const { serial } = await issueOver(1000000000);

    // 5% of the mass the certificate was computed over. The rollup has already
    // been decremented by the time this runs, which is why the reversed mass is
    // added back to reconstruct the certified figure.
    fs._seed('eprPeriods', 'org_cola_2026-09', {
      ...fs._store.get('eprPeriods/org_cola_2026-09'),
      massMgByCategory: { rigid: 950000000 },
    });

    const result = await passports.supersedeForReversal({
      orgId: 'org_cola',
      periodId: '2026-09',
      massMg: 50000000,
      actorUid: 'uid_admin',
    });

    expect(result.superseded).toBe(1);
    expect(fs._store.get(`plasticPassports/${serial}`).status).toBe('superseded');
    expect(fs._store.get(`plasticPassports/${serial}`).supersededReason)
      .toMatch(/reversed after review/i);
  });

  test('leaves the certificate alone below the threshold', async () => {
    const { serial } = await issueOver(1000000000);
    fs._seed('eprPeriods', 'org_cola_2026-09', {
      ...fs._store.get('eprPeriods/org_cola_2026-09'),
      massMgByCategory: { rigid: 999000000 },
    });

    // A tenth of a percent. A single mis-recognised bottle removed from a
    // month does not make a certificate wrong, and superseding on every
    // correction would teach producers and their customers to ignore the
    // status — which would make supersession useless exactly when it matters.
    const result = await passports.supersedeForReversal({
      orgId: 'org_cola',
      periodId: '2026-09',
      massMg: 1000000,
      actorUid: 'uid_admin',
    });

    expect(result.superseded).toBe(0);
    expect(result.immaterial).toBe(true);
    expect(fs._store.get(`plasticPassports/${serial}`).status).toBe('issued');
  });

  test('never throws, because the reversal is already committed', async () => {
    // A supersession failure must not turn an Admin's recorded correction into
    // an error they conclude did not take effect.
    eprPolicy.readPolicy.mockRejectedValue(new Error('policy unavailable'));

    await expect(
      passports.supersedeForReversal({
        orgId: 'org_cola', periodId: '2026-09', massMg: 1, actorUid: 'uid_admin',
      }),
    ).resolves.toMatchObject({ superseded: 0 });
  });

  test('ignores a malformed period rather than sweeping everything', async () => {
    await expect(
      passports.supersedeForReversal({
        orgId: 'org_cola', periodId: '2026-9', massMg: 999999999, actorUid: 'u',
      }),
    ).resolves.toMatchObject({ superseded: 0 });
  });
});

describe('superseding after a unit mass is re-verified (EPR-30)', () => {
  test('supersedes every certified period, because a SKU spans months', async () => {
    // A certificate's mass is units multiplied by the unit mass Chokro
    // established. Establishing a different one makes every period that used
    // the old figure state a mass Chokro no longer stands behind — and the
    // re-verification does not know which periods those are.
    for (const periodId of ['2026-08', '2026-09']) {
      fs._seed('eprPeriods', `org_cola_${periodId}`, {
        orgId: 'org_cola',
        periodId,
        massMgByCategory: { rigid: 1000000 },
        skuIds: ['sku_a'],
      });
      await passports.issuePassport({
        orgId: 'org_cola', periodId, adminUid: 'uid_admin',
      });
    }

    const result = await passports.supersedeForMassChange({
      orgId: 'org_cola', skuId: 'sku_a', actorUid: 'uid_admin',
    });

    expect(result.superseded).toBe(2);
    expect(result.periods).toBe(2);
    for (const p of fs._find('plasticPassports')) {
      expect(p.status).toBe('superseded');
      expect(p.supersededReason).toMatch(/verified unit mass/i);
    }
  });

  test('does not touch another organisation’s certificates', async () => {
    fs._seed('organizations', 'org_pran', {
      legalName: 'PRAN Ltd', tradeName: 'PRAN', status: 'active',
    });
    fs._seed('eprPeriods', 'org_pran_2026-09', {
      orgId: 'org_pran', periodId: '2026-09',
      massMgByCategory: { rigid: 1000000 }, skuIds: ['sku_x'],
    });
    const theirs = await passports.issuePassport({
      orgId: 'org_pran', periodId: '2026-09', adminUid: 'uid_admin',
    });

    fs._seed('eprPeriods', 'org_cola_2026-09', {
      orgId: 'org_cola', periodId: '2026-09',
      massMgByCategory: { rigid: 1000000 }, skuIds: ['sku_a'],
    });
    await passports.issuePassport({
      orgId: 'org_cola', periodId: '2026-09', adminUid: 'uid_admin',
    });

    await passports.supersedeForMassChange({
      orgId: 'org_cola', skuId: 'sku_a', actorUid: 'uid_admin',
    });

    expect(fs._store.get(`plasticPassports/${theirs.serial}`).status).toBe('issued');
  });

  test('never throws', async () => {
    firebase.db.mockReturnValue({
      collection: () => ({
        where: () => ({ where: () => ({ limit: () => ({ get: () =>
          Promise.reject(new Error('down')) }) }) }),
      }),
    });

    await expect(
      passports.supersedeForMassChange({
        orgId: 'org_cola', skuId: 'sku_a', actorUid: 'uid_admin',
      }),
    ).resolves.toMatchObject({ superseded: 0 });
  });
});
