/**
 * The product registry and the verified-mass chain (EPR-9 to EPR-14).
 *
 * §6.2 is the integrity crux of the whole specification, so this file leans
 * hardest on the two properties that make a reported kilogram defensible:
 * a declared mass is never used for reporting, and a verified mass is never
 * edited in place.
 */

jest.mock('../src/firebase', () => ({
  db: jest.fn(),
  admin: {
    firestore: {
      Timestamp: {
        now: () => ({ __ts: 'NOW', toDate: () => new Date('2026-09-09T00:00:00Z') }),
        fromDate: (d) => ({ __ts: true, toDate: () => d }),
      },
    },
  },
  serverTimestamp: jest.fn(() => '__TS__'),
}));

jest.mock('../src/eprPolicy', () => ({
  readPolicy: jest.fn(),
  isWithinTolerance: jest.requireActual('../src/eprPolicy').isWithinTolerance,
}));

const firebase = require('../src/firebase');
const eprPolicy = require('../src/eprPolicy');
const skus = require('../src/producerSkus');

// ---------------------------------------------------------------------------
// The pure half — no Firestore needed
// ---------------------------------------------------------------------------

describe('milligramsFromGrams — the server copy of mass_math', () => {
  test('reads the worked example the same way Dart does', () => {
    // The two copies live either side of a language boundary with no shared
    // runtime. Testing both against the same worked example is what turns a
    // divergence into a failing test rather than a disagreeing kilogram.
    expect(skus.milligramsFromGrams(8.2)).toBe(8200);
    expect(skus.milligramsFromGrams(1.3)).toBe(1300);
    expect(skus.milligramsFromGrams(0.5)).toBe(500);
    expect(skus.milligramsFromGrams(10.0)).toBe(10000);
    expect(skus.milligramsFromGrams(9.8)).toBe(9800);
    expect(skus.milligramsFromGrams('8.2')).toBe(8200);
  });

  test('refuses anything unusable rather than defaulting', () => {
    for (const bad of [null, undefined, '', 'abc', 0, -1, NaN, Infinity, {}, []]) {
      expect(skus.milligramsFromGrams(bad)).toBeNull();
    }
  });

  test('refuses a partially-numeric string instead of prefix-parsing it', () => {
    // `Number.parseFloat` reads as far as it can and discards the rest, which
    // made this copy disagree with Dart's `double.tryParse` on exactly the
    // inputs a real client sends. '1,250' parsed to 1 — a 1250x understatement
    // of a declared unit mass, becoming the baseline that every later
    // verification and every attributed kilogram is measured against.
    //
    // The same values are asserted on the Dart side in
    // test/core/mass_math_test.dart under the same test name, so the pair is
    // pinned rather than each copy being pinned to itself.
    expect(skus.milligramsFromGrams('1,250')).toBeNull();
    expect(skus.milligramsFromGrams('8.2g')).toBeNull();
    expect(skus.milligramsFromGrams('8.2.5')).toBeNull();
    expect(skus.milligramsFromGrams('12 grams')).toBeNull();
    expect(skus.milligramsFromGrams('1 250')).toBeNull();
    // Hex too: Number('0x10') is 16, and Dart rejects it.
    expect(skus.milligramsFromGrams('0x10')).toBeNull();
  });

  test('accepts every numeric form Dart accepts, and no others', () => {
    expect(skus.milligramsFromGrams('10')).toBe(10000);
    expect(skus.milligramsFromGrams('  10 ')).toBe(10000);
    expect(skus.milligramsFromGrams('8.2')).toBe(8200);
    expect(skus.milligramsFromGrams('.5')).toBe(500);
    expect(skus.milligramsFromGrams('+8.2')).toBe(8200);
    expect(skus.milligramsFromGrams('1e3')).toBe(1000000);
  });

  test('enforces the same 0.1 g to 5000 g bounds', () => {
    expect(skus.milligramsFromGrams(0.1)).toBe(skus.MIN_UNIT_MASS_MG);
    expect(skus.milligramsFromGrams(0.09)).toBeNull();
    expect(skus.milligramsFromGrams(5000)).toBe(skus.MAX_UNIT_MASS_MG);
    expect(skus.milligramsFromGrams(5000.1)).toBeNull();
  });
});

describe('validateSkuDraft', () => {
  const good = {
    name: 'Coca-Cola 250 ml PET bottle',
    brand: 'Coca-Cola',
    gazetteCategory: 'rigid',
    polymer: 'pet',
    declaredUnitMassMg: 10000,
    components: [
      { part: 'body', polymer: 'pet', massMg: 8200 },
      { part: 'cap', polymer: 'pp', massMg: 1300 },
      { part: 'label', polymer: 'pet', massMg: 500 },
    ],
    sampleImageUrls: ['https://a/1.jpg', 'https://a/2.jpg'],
  };

  test('accepts the worked example', () => {
    expect(skus.validateSkuDraft(good).problems).toEqual([]);
    expect(skus.validateSkuDraft(good, { requireSubmittable: true }).problems).toEqual([]);
  });

  test('refuses components that do not add up, naming both figures', () => {
    const problems = skus.validateSkuDraft({
      ...good,
      components: [{ part: 'body', polymer: 'pet', massMg: 8200 }],
    }).problems;
    expect(problems.join(' ')).toContain('8.2 g');
    expect(problems.join(' ')).toContain('10 g');
  });

  test('one milligram out is out — exact integer equality', () => {
    expect(
      skus.validateSkuDraft({
        ...good,
        components: [
          { part: 'body', polymer: 'pet', massMg: 8201 },
          { part: 'cap', polymer: 'pp', massMg: 1300 },
          { part: 'label', polymer: 'pet', massMg: 500 },
        ],
      }).problems,
    ).not.toEqual([]);
  });

  test('refuses an unknown category or polymer', () => {
    expect(
      skus.validateSkuDraft({ ...good, gazetteCategory: 'compostable' }).problems.join(' '),
    ).toContain('gazette category');
    expect(
      skus.validateSkuDraft({ ...good, polymer: 'unobtainium' }).problems.join(' '),
    ).toContain('main polymer');
  });

  test('refuses a component with an unknown polymer, not just drops it', () => {
    // A dropped component would put grams on the wrong gazette line and still
    // fail the sum — but the message should say what is actually wrong.
    const problems = skus.validateSkuDraft({
      ...good,
      components: [{ part: 'body', polymer: 'unobtainium', massMg: 10000 }],
    }).problems;
    expect(problems.join(' ')).toContain('known polymer');
  });

  test('sample photographs are required only when submitting', () => {
    const draft = { ...good, sampleImageUrls: [] };
    // A producer may save a half-finished draft over several sittings.
    expect(skus.validateSkuDraft(draft).problems).toEqual([]);
    // The full requirement lands when they ask Chokro to weigh something.
    expect(
      skus.validateSkuDraft(draft, { requireSubmittable: true }).problems.join(' '),
    ).toContain('two sample photographs');
  });

  test('more than six photographs is refused either way', () => {
    const draft = {
      ...good,
      sampleImageUrls: Array.from({ length: 7 }, (_, i) => `https://a/${i}.jpg`),
    };
    expect(skus.validateSkuDraft(draft).problems).not.toEqual([]);
  });

  test('a malformed GTIN is refused', () => {
    expect(skus.validateSkuDraft({ ...good, gtin: 'ABC' }).problems.join(' ')).toContain('GTIN');
    expect(skus.validateSkuDraft({ ...good, gtin: '8901234567890' }).problems).toEqual([]);
    // Absent is fine — most SKUs have no barcode on file.
    expect(skus.validateSkuDraft({ ...good, gtin: '' }).problems).toEqual([]);
  });

  test('reports every problem, not the first', () => {
    expect(
      skus.validateSkuDraft({
        name: 'X',
        brand: '',
        gazetteCategory: 'nope',
        polymer: 'nope',
        components: 'not a list',
      }).problems.length,
    ).toBeGreaterThanOrEqual(5);
  });

  test('an empty draft is refused without throwing', () => {
    expect(skus.validateSkuDraft(undefined).problems.length).toBeGreaterThan(0);
    expect(skus.validateSkuDraft(null).problems.length).toBeGreaterThan(0);
  });
});

describe('brandKey', () => {
  test('matches the organisations copy, so collisions agree', () => {
    const organizations = require('../src/organizations');
    expect(skus.brandKey('Coca-Cola Bangladesh')).toBe(
      organizations.brandKey('Coca-Cola Bangladesh'),
    );
    expect(skus.brandKey('coca cola  bangladesh')).toBe(
      skus.brandKey('Coca-Cola Bangladesh'),
    );
  });
});

// ---------------------------------------------------------------------------
// The Firestore half
// ---------------------------------------------------------------------------

/**
 * Firestore's query operators, as far as these tests use them.
 *
 * Timestamps are unwrapped through `toDate()` so a range filter on a stored
 * `Timestamp` compares against a real instant rather than against an object.
 */
function compare(stored, op, value) {
  const left = stored?.toDate ? stored.toDate().getTime() : stored;
  const right = value?.toDate ? value.toDate().getTime() : value;

  switch (op) {
    case '==':
      return left === right;
    case '!=':
      return left !== right;
    case '>':
      return left > right;
    case '>=':
      return left >= right;
    case '<':
      return left < right;
    case '<=':
      return left <= right;
    case 'in':
      return Array.isArray(right) && right.includes(left);
    default:
      throw new Error(`fake Firestore does not implement operator ${op}`);
  }
}

function fakeFirestore() {
  const store = new Map();
  const key = (col, id) => `${col}/${id}`;
  let autoId = 0;

  function makeRef(col, id) {
    return {
      id,
      path: key(col, id),
      async get() {
        const data = store.get(key(col, id));
        return { exists: data !== undefined, id, data: () => data };
      },
    };
  }

  function collection(col) {
    const q = { filters: [], max: Infinity, order: null };
    const api = {
      doc(id) {
        autoId += 1;
        return makeRef(col, id || `auto_${autoId}`);
      },
      where(field, op, value) {
        // The operator is honoured, not ignored. A fake that treated every
        // `where` as equality silently returned nothing for a range filter, so
        // a query bounded on `expiresAt > now` looked empty and the
        // invitation ceiling it guards never fired in tests.
        q.filters.push([field, op, value]);
        return api;
      },
      orderBy(field, direction = 'asc') {
        q.order = [field, direction];
        return api;
      },
      limit(n) {
        q.max = n;
        return api;
      },
      async get() {
        let rows = [...store.entries()]
          .filter(([k]) => k.startsWith(`${col}/`))
          .map(([k, v]) => ({ id: k.slice(col.length + 1), data: () => v }));
        for (const [field, op, value] of q.filters) {
          rows = rows.filter((r) => compare(r.data()[field], op, value));
        }
        if (q.order) {
          const [field, direction] = q.order;
          rows.sort((a, b) => {
            const x = a.data()[field];
            const y = b.data()[field];
            if (x === y) return 0;
            return direction === 'desc' ? (y > x ? 1 : -1) : (x > y ? 1 : -1);
          });
        }
        rows = rows.slice(0, q.max);
        return { docs: rows, empty: rows.length === 0, size: rows.length };
      },
    };
    return api;
  }

  // Enforces the one rule a hand-written fake normally lets through:
  // Firestore requires every read in a transaction to precede every write, and
  // the Admin SDK throws unconditionally otherwise. Three real read-after-write
  // bugs shipped past this suite because the fake did not care.
  let writeIssued = false;

  const txn = {
    async get(target) {
      if (writeIssued) {
        throw new Error(
          'Firestore transactions require all reads to be executed before all writes.',
        );
      }
      return typeof target.get === 'function' ? target.get() : target;
    },
    set(ref, data, options) {
      writeIssued = true;
      store.set(
        ref.path,
        options?.merge ? { ...store.get(ref.path), ...data } : { ...data },
      );
    },
    update(ref, data) {
      writeIssued = true;
      store.set(ref.path, { ...store.get(ref.path), ...data });
    },
  };

  return {
    collection,
    async runTransaction(fn) {
      // A fresh transaction starts with no writes issued, exactly as a real
      // one does — otherwise the second transaction in a test would refuse
      // every read.
      writeIssued = false;
      return fn(txn);
    },
    _store: store,
    _seed(col, id, data) {
      store.set(key(col, id), data);
    },
    _find(col) {
      return [...store.entries()]
        .filter(([k]) => k.startsWith(`${col}/`))
        .map(([k, v]) => ({ id: k.slice(col.length + 1), ...v }));
    },
  };
}

let fs;

const DRAFT = {
  name: 'Coca-Cola 250 ml PET bottle',
  brand: 'Coca-Cola',
  gazetteCategory: 'rigid',
  polymer: 'pet',
  declaredUnitMassMg: 10000,
  components: [
    { part: 'body', polymer: 'pet', massMg: 8200 },
    { part: 'cap', polymer: 'pp', massMg: 1300 },
    { part: 'label', polymer: 'pet', massMg: 500 },
  ],
  sampleImageUrls: ['https://a/1.jpg', 'https://a/2.jpg'],
};

beforeEach(() => {
  jest.clearAllMocks();
  fs = fakeFirestore();
  firebase.db.mockReturnValue(fs);
  eprPolicy.readPolicy.mockResolvedValue({
    massAuditSampleSize: 5,
    massToleranceFraction: 0.10,
    massRevalidationMonths: 12,
  });
});

async function seedVerifiableSku() {
  const { skuId } = await skus.saveSkuDraft({
    orgId: 'org_cola',
    draft: DRAFT,
    actorUid: 'uid_reporter',
  });
  await skus.submitForVerification({
    skuId,
    orgId: 'org_cola',
    actorUid: 'uid_reporter',
  });
  return skuId;
}

describe('saving a draft', () => {
  test('stores integer milligrams and the gram figure beside it', async () => {
    const { skuId } = await skus.saveSkuDraft({
      orgId: 'org_cola',
      draft: DRAFT,
      actorUid: 'uid_reporter',
    });

    const stored = fs._store.get(`producerSkus/${skuId}`);
    expect(stored.declaredUnitMassMg).toBe(10000);
    expect(stored.declaredUnitMassG).toBe(10);
    expect(stored.brandKey).toBe('cocacola');
  });

  test('a new product arrives unverified, at revision zero', async () => {
    const { skuId } = await skus.saveSkuDraft({
      orgId: 'org_cola',
      draft: DRAFT,
      actorUid: 'uid_reporter',
    });

    const stored = fs._store.get(`producerSkus/${skuId}`);
    expect(stored.massStatus).toBe('draft');
    expect(stored.verifiedUnitMassMg).toBeNull();
    expect(stored.revision).toBe(0);
    expect(stored.activeFrom).toBeNull();
  });

  test('a client cannot smuggle a verified mass through the draft', async () => {
    // The rules refuse these keys too. Belt and braces, because this is the
    // field that decides what a regulator reads.
    const { skuId } = await skus.saveSkuDraft({
      orgId: 'org_cola',
      draft: {
        ...DRAFT,
        massStatus: 'verified',
        verifiedUnitMassMg: 25000,
        revision: 99,
        activeFrom: new Date(),
      },
      actorUid: 'uid_reporter',
    });

    const stored = fs._store.get(`producerSkus/${skuId}`);
    expect(stored.massStatus).toBe('draft');
    expect(stored.verifiedUnitMassMg).toBeNull();
    expect(stored.revision).toBe(0);
  });

  test('editing another organisation’s product is a not-found', async () => {
    // SEC-1, inside the transaction and on the stored document. The route
    // already resolved membership; this is the second place that has to agree.
    const { skuId } = await skus.saveSkuDraft({
      orgId: 'org_cola',
      draft: DRAFT,
      actorUid: 'uid_reporter',
    });

    await expect(
      skus.saveSkuDraft({
        skuId,
        orgId: 'org_pran',
        draft: DRAFT,
        actorUid: 'uid_pran',
      }),
    ).rejects.toThrow('no longer exists');
  });

  test('a submitted product is locked while Chokro weighs it', async () => {
    // Otherwise the figure on the bench stops matching the figure on file.
    const skuId = await seedVerifiableSku();

    await expect(
      skus.saveSkuDraft({
        skuId,
        orgId: 'org_cola',
        draft: { ...DRAFT, declaredUnitMassMg: 12000, components: [
          { part: 'body', polymer: 'pet', massMg: 12000 },
        ] },
        actorUid: 'uid_reporter',
      }),
    ).rejects.toThrow('with Chokro for verification');
  });

  test('an invalid draft is refused with its problems attached', async () => {
    await expect(
      skus.saveSkuDraft({
        orgId: 'org_cola',
        draft: { ...DRAFT, declaredUnitMassMg: 9000 },
        actorUid: 'uid_reporter',
      }),
    ).rejects.toMatchObject({ code: 'invalid_sku' });
  });
});

describe('editing after verification invalidates it (EPR-12, §6.2)', () => {
  async function seedVerified() {
    const { skuId } = await skus.saveSkuDraft({
      orgId: 'org_cola',
      draft: DRAFT,
      actorUid: 'uid_reporter',
    });
    await skus.submitForVerification({
      skuId,
      orgId: 'org_cola',
      actorUid: 'uid_reporter',
    });
    await skus.recordMassAudit({
      skuId,
      sampleSize: 5,
      measuredMeanMg: 9800,
      adminUid: 'admin_1',
    });
    return skuId;
  }

  /** The bottle-into-a-cap swap, as a draft. */
  const CAP_DRAFT = {
    ...DRAFT,
    name: 'Coca-Cola PP bottle cap',
    gtin: '8901234567891',
    declaredUnitMassMg: 1300,
    components: [{ part: 'cap', polymer: 'pp', massMg: 1300 }],
  };

  test('a verified mass does not survive a change to what was weighed', async () => {
    // The attack: register a 10 g bottle, let Chokro verify 9.8 g, then edit the
    // same document into a 1.3 g cap. Without this, the document is a cap
    // carrying `verifiedUnitMassMg: 9800`, and every recognised cap would be
    // attributed 9.8 g. No Admin is involved at any point.
    const skuId = await seedVerified();
    expect(fs._store.get(`producerSkus/${skuId}`).verifiedUnitMassMg).toBe(9800);

    const result = await skus.saveSkuDraft({
      skuId,
      orgId: 'org_cola',
      draft: CAP_DRAFT,
      actorUid: 'uid_reporter',
    });

    expect(result.verificationInvalidated).toBe(true);

    const stored = fs._store.get(`producerSkus/${skuId}`);
    expect(stored.name).toBe('Coca-Cola PP bottle cap');
    expect(stored.declaredUnitMassMg).toBe(1300);
    // The verification is gone, in every field that could carry it forward.
    expect(stored.massStatus).toBe('draft');
    expect(stored.verifiedUnitMassMg).toBeNull();
    expect(stored.verifiedUnitMassG).toBeNull();
    expect(stored.verifiedBy).toBeNull();
    expect(stored.verifiedAt).toBeNull();
    expect(stored.activeFrom).toBeNull();
    // And it is no longer recognisable at a bin.
    expect(stored.status).toBe('draft');
    expect(stored.invalidatedReason).toContain('no longer describes');
  });

  test('the superseded revision is closed, not deleted', async () => {
    // A report issued against revision 1 must remain reproducible: every
    // attribution stored the revision and the unit mass it used (EPR-12).
    const skuId = await seedVerified();
    await skus.saveSkuDraft({
      skuId,
      orgId: 'org_cola',
      draft: CAP_DRAFT,
      actorUid: 'uid_reporter',
    });

    const revision = fs._store.get(`skuRevisions/${skuId}_1`);
    expect(revision).toBeDefined();
    expect(revision.verifiedUnitMassMg).toBe(9800);
    expect(revision.activeTo).not.toBeNull();
    expect(revision.closedReason).toBe('declarationChanged');
  });

  test('the audit entry says the verified mass no longer applies', async () => {
    const skuId = await seedVerified();
    await skus.saveSkuDraft({
      skuId,
      orgId: 'org_cola',
      draft: CAP_DRAFT,
      actorUid: 'uid_reporter',
    });

    const entries = fs._find('producerAuditLog');
    const summary = entries[entries.length - 1].summary;
    expect(summary).toContain('after verification');
    expect(summary).toContain('9.8 g');
  });

  test('a cosmetic edit does not churn the verification', async () => {
    // A typo fix in the name is not a change to what was weighed, and forcing a
    // re-weigh for one would cost bench time for no integrity gain.
    const skuId = await seedVerified();

    const result = await skus.saveSkuDraft({
      skuId,
      orgId: 'org_cola',
      draft: { ...DRAFT, name: 'Coca-Cola 250 ml PET bottle (contour)' },
      actorUid: 'uid_reporter',
    });

    expect(result.verificationInvalidated).toBe(false);
    const stored = fs._store.get(`producerSkus/${skuId}`);
    expect(stored.massStatus).toBe('verified');
    expect(stored.verifiedUnitMassMg).toBe(9800);
    expect(stored.revision).toBe(1);
  });

  test('a reordered component list is not a changed product', async () => {
    const skuId = await seedVerified();
    const reordered = {
      ...DRAFT,
      components: [...DRAFT.components].reverse(),
    };

    const result = await skus.saveSkuDraft({
      skuId,
      orgId: 'org_cola',
      draft: reordered,
      actorUid: 'uid_reporter',
    });

    expect(result.verificationInvalidated).toBe(false);
  });

  test('every physical field triggers invalidation', async () => {
    // Each of these describes the object on the scale, so changing any of them
    // means the weighing was of something else.
    const cases = [
      ['declared mass', { declaredUnitMassMg: 9000, components: [
        { part: 'body', polymer: 'pet', massMg: 7200 },
        { part: 'cap', polymer: 'pp', massMg: 1300 },
        { part: 'label', polymer: 'pet', massMg: 500 },
      ] }],
      ['gazette category', { gazetteCategory: 'flexible' }],
      ['polymer', { polymer: 'hdpe' }],
      ['volume', { volumeMl: 500 }],
      ['GTIN', { gtin: '8901234567899' }],
      ['a component polymer', { components: [
        { part: 'body', polymer: 'hdpe', massMg: 8200 },
        { part: 'cap', polymer: 'pp', massMg: 1300 },
        { part: 'label', polymer: 'pet', massMg: 500 },
      ] }],
    ];

    for (const [label, overrides] of cases) {
      fs = fakeFirestore();
      firebase.db.mockReturnValue(fs);
      const skuId = await seedVerified();

      const result = await skus.saveSkuDraft({
        skuId,
        orgId: 'org_cola',
        draft: { ...DRAFT, ...overrides },
        actorUid: 'uid_reporter',
      });

      expect(result.verificationInvalidated).toBe(true);
      expect(fs._store.get(`producerSkus/${skuId}`).massStatus).toBe(
        'draft',
      );
    }
  });

  test('the predicate itself is exercised directly', async () => {
    const current = {
      declaredUnitMassMg: 10000,
      gazetteCategory: 'rigid',
      polymer: 'pet',
      volumeMl: 250,
      gtin: null,
      components: DRAFT.components,
    };
    const same = {
      declaredMg: 10000,
      components: [...DRAFT.components].reverse(),
      draft: { gazetteCategory: 'rigid', polymer: 'pet', volumeMl: 250, gtin: null },
    };

    expect(skus.physicalDeclarationChanged(current, same)).toBe(false);
    expect(
      skus.physicalDeclarationChanged(current, { ...same, declaredMg: 9000 }),
    ).toBe(true);
    // Order-independent, so a reshuffled array is not a changed product.
    expect(skus.canonicalComponents(DRAFT.components)).toBe(
      skus.canonicalComponents([...DRAFT.components].reverse()),
    );
  });
});

describe('submitting for verification', () => {
  test('requires the sample photographs EPR-9 asks for', async () => {
    const { skuId } = await skus.saveSkuDraft({
      orgId: 'org_cola',
      draft: { ...DRAFT, sampleImageUrls: [] },
      actorUid: 'uid_reporter',
    });

    await expect(
      skus.submitForVerification({ skuId, orgId: 'org_cola', actorUid: 'u' }),
    ).rejects.toMatchObject({ code: 'not_submittable' });
  });

  test('cannot be submitted twice', async () => {
    const skuId = await seedVerifiableSku();
    await expect(
      skus.submitForVerification({ skuId, orgId: 'org_cola', actorUid: 'u' }),
    ).rejects.toThrow('already with Chokro');
  });

  test('another organisation cannot submit it', async () => {
    const { skuId } = await skus.saveSkuDraft({
      orgId: 'org_cola',
      draft: DRAFT,
      actorUid: 'uid_reporter',
    });
    await expect(
      skus.submitForVerification({ skuId, orgId: 'org_pran', actorUid: 'u' }),
    ).rejects.toThrow('no longer exists');
  });
});

describe('the mass audit — where a declared mass becomes a verified one', () => {
  test('the worked example: reporting uses the measured 9.8 g, not 10.0 g', async () => {
    // Appendix A step 3, verbatim: mean 9.8 g against a declared 10.0 g, within
    // the ±10% tolerance, and `verifiedUnitMassG: 9.8` — "Reporting uses 9.8,
    // not the declared 10.0."
    const skuId = await seedVerifiableSku();

    const result = await skus.recordMassAudit({
      skuId,
      sampleSize: 5,
      measuredMeanMg: 9800,
      measuredStdDevMg: 200,
      adminUid: 'admin_1',
    });

    expect(result.verdict).toBe('withinTolerance');
    expect(result.verifiedUnitMassMg).toBe(9800);
    expect(result.revision).toBe(1);
  });

  test('the tolerance cannot be used as a licence to overstate', async () => {
    // The bias this closes: declare 10.0 g, let the true mass drift to 9.1 g,
    // and a rule that kept the declaration whenever it was "close enough" would
    // certify 10.0 g — a 9% overstatement in the producer's favour, sanctioned
    // by the control meant to prevent it, and repeatable across a catalogue.
    const skuId = await seedVerifiableSku();

    const result = await skus.recordMassAudit({
      skuId,
      sampleSize: 5,
      measuredMeanMg: 9100,
      adminUid: 'admin_1',
    });

    expect(result.verdict).toBe('withinTolerance');
    expect(result.verifiedUnitMassMg).toBe(9100);
  });

  test('outside tolerance the measurement is adopted and the verdict says so', async () => {
    const skuId = await seedVerifiableSku();

    const result = await skus.recordMassAudit({
      skuId,
      sampleSize: 5,
      measuredMeanMg: 8000,
      adminUid: 'admin_1',
    });

    expect(result.verdict).toBe('outsideTolerance');
    expect(result.verifiedUnitMassMg).toBe(8000);
    // The verdict is a finding about the declaration, kept for the audit pack
    // and the anomaly queue.
    expect(fs._find('skuMassAudits')[0].resultingAction).toContain('flagged');
  });

  test('the audit record carries what an inspector would ask for', async () => {
    const skuId = await seedVerifiableSku();
    await skus.recordMassAudit({
      skuId,
      sampleSize: 5,
      measuredMeanMg: 9800,
      measuredStdDevMg: 200,
      weighingLocation: 'Chokro lab, Mohammadpur',
      scalePhotoUrl: 'https://a/scale.jpg',
      adminUid: 'admin_1',
    });

    const audit = fs._find('skuMassAudits')[0];
    expect(audit.sampleSize).toBe(5);
    expect(audit.measuredMeanMg).toBe(9800);
    expect(audit.measuredStdDevMg).toBe(200);
    expect(audit.scalePhotoUrl).toBe('https://a/scale.jpg');
    expect(audit.operatorUid).toBe('admin_1');
    expect(audit.weighingLocation).toContain('Mohammadpur');
  });

  test('the tolerance in force is stored on the record', async () => {
    // An Admin tightening the policy later must not retrospectively change
    // whether this audit passed.
    const skuId = await seedVerifiableSku();
    await skus.recordMassAudit({
      skuId,
      sampleSize: 5,
      measuredMeanMg: 9800,
      adminUid: 'admin_1',
    });

    expect(fs._find('skuMassAudits')[0].toleranceFraction).toBe(0.10);
  });

  test('a sample below the policy minimum is refused', async () => {
    // Below five units a mean is not a mean.
    const skuId = await seedVerifiableSku();
    await expect(
      skus.recordMassAudit({
        skuId,
        sampleSize: 3,
        measuredMeanMg: 9800,
        adminUid: 'admin_1',
      }),
    ).rejects.toThrow('at least 5 units');
  });

  test('a missing sample size or mean is refused', async () => {
    const skuId = await seedVerifiableSku();
    for (const args of [
      { sampleSize: undefined, measuredMeanMg: 9800 },
      { sampleSize: 5, measuredMeanMg: undefined },
      { sampleSize: 5, measuredMeanMg: 0 },
      { sampleSize: 5, measuredMeanMg: 99 },
    ]) {
      await expect(
        skus.recordMassAudit({ skuId, ...args, adminUid: 'admin_1' }),
      ).rejects.toBeTruthy();
    }
  });
});

describe('effective dating — a verified mass is never edited in place (EPR-12)', () => {
  test('the first verification opens revision 1, open-ended', async () => {
    const skuId = await seedVerifiableSku();
    await skus.recordMassAudit({
      skuId,
      sampleSize: 5,
      measuredMeanMg: 9800,
      adminUid: 'admin_1',
    });

    const revision = fs._store.get(`skuRevisions/${skuId}_1`);
    expect(revision.revision).toBe(1);
    expect(revision.verifiedUnitMassMg).toBe(9800);
    expect(revision.activeTo).toBeNull();
    expect(revision.reason).toBe('initialVerification');
  });

  test('a re-weighing closes revision 1 and opens revision 2', async () => {
    // Appendix A step 11: a November re-weighing finds the bottle light-weighted
    // to 9.1 g. September's passport stays correct because its attributions
    // stored revision 1.
    const skuId = await seedVerifiableSku();
    await skus.recordMassAudit({
      skuId,
      sampleSize: 5,
      measuredMeanMg: 9800,
      adminUid: 'admin_1',
    });
    await skus.recordMassAudit({
      skuId,
      sampleSize: 5,
      measuredMeanMg: 9100,
      adminUid: 'admin_1',
    });

    const first = fs._store.get(`skuRevisions/${skuId}_1`);
    const second = fs._store.get(`skuRevisions/${skuId}_2`);

    // Revision 1 is closed, not overwritten. Its mass is untouched.
    expect(first.verifiedUnitMassMg).toBe(9800);
    expect(first.activeTo).not.toBeNull();

    expect(second.revision).toBe(2);
    expect(second.verifiedUnitMassMg).toBe(9100);
    expect(second.activeTo).toBeNull();
    expect(second.reason).toBe('reweighed');

    // And the SKU points at the current one.
    expect(fs._store.get(`producerSkus/${skuId}`).revision).toBe(2);
    expect(fs._store.get(`producerSkus/${skuId}`).verifiedUnitMassMg).toBe(9100);
  });

  test('every revision records who changed it and on what basis', async () => {
    const skuId = await seedVerifiableSku();
    await skus.recordMassAudit({
      skuId,
      sampleSize: 5,
      measuredMeanMg: 9800,
      adminUid: 'admin_1',
    });

    const revision = fs._store.get(`skuRevisions/${skuId}_1`);
    expect(revision.changedBy).toBe('admin_1');
    expect(revision.auditId).toBeTruthy();
    expect(revision.declaredUnitMassMg).toBe(10000);
  });
});

describe('setting a verified mass without a scale (EPR-11 cases 2 and 3)', () => {
  test('documentary verification opens a revision', async () => {
    const skuId = await seedVerifiableSku();
    const result = await skus.setVerifiedMass({
      skuId,
      verifiedUnitMassMg: 9700,
      reason: 'documentary',
      note: 'Manufacturer technical data sheet TDS-4471, checked 9 September.',
      adminUid: 'admin_1',
    });

    expect(result.verifiedUnitMassMg).toBe(9700);
    expect(fs._store.get(`skuRevisions/${skuId}_1`).reason).toBe('documentary');
    // No audit record, honestly: nothing was weighed.
    expect(fs._find('skuMassAudits')).toHaveLength(0);
  });

  test('an override without a stated basis is refused', async () => {
    // A figure set by hand with no recorded basis is exactly what a DoE data
    // verification asks about.
    const skuId = await seedVerifiableSku();
    for (const note of [undefined, '', 'ok', 'because']) {
      await expect(
        skus.setVerifiedMass({
          skuId,
          verifiedUnitMassMg: 9700,
          reason: 'adminOverride',
          note,
          adminUid: 'admin_1',
        }),
      ).rejects.toThrow('Record the basis');
    }
  });

  test('an unknown reason is refused', async () => {
    const skuId = await seedVerifiableSku();
    await expect(
      skus.setVerifiedMass({
        skuId,
        verifiedUnitMassMg: 9700,
        reason: 'reweighed',
        note: 'A long enough note to pass the length check.',
        adminUid: 'admin_1',
      }),
    ).rejects.toThrow('documentary verification or an override');
  });

  test('an out-of-range mass is refused', async () => {
    const skuId = await seedVerifiableSku();
    await expect(
      skus.setVerifiedMass({
        skuId,
        verifiedUnitMassMg: skus.MAX_UNIT_MASS_MG + 1,
        reason: 'documentary',
        note: 'A long enough note to pass the length check.',
        adminUid: 'admin_1',
      }),
    ).rejects.toThrow('outside the allowed range');
  });
});

describe('rejecting a declaration', () => {
  test('records a reason the producer can act on', async () => {
    const skuId = await seedVerifiableSku();
    await skus.rejectSku({
      skuId,
      reason: 'The cap mass looks like a bottle mass. Re-weigh the parts.',
      adminUid: 'admin_1',
    });

    const stored = fs._store.get(`producerSkus/${skuId}`);
    expect(stored.massStatus).toBe('rejected');
    expect(stored.rejectionReason).toContain('Re-weigh');
    // And no revision was opened — nothing was verified.
    expect(fs._find('skuRevisions')).toHaveLength(0);
  });

  test('a reason is mandatory', async () => {
    const skuId = await seedVerifiableSku();
    await expect(
      skus.rejectSku({ skuId, reason: 'no', adminUid: 'admin_1' }),
    ).rejects.toThrow('reason');
  });

  test('only a submitted declaration can be rejected', async () => {
    const { skuId } = await skus.saveSkuDraft({
      orgId: 'org_cola',
      draft: DRAFT,
      actorUid: 'uid_reporter',
    });
    await expect(
      skus.rejectSku({
        skuId,
        reason: 'A perfectly good reason for rejecting this.',
        adminUid: 'admin_1',
      }),
    ).rejects.toThrow('not awaiting a decision');
  });

  test('a rejected product can be edited again', async () => {
    const skuId = await seedVerifiableSku();
    await skus.rejectSku({
      skuId,
      reason: 'The cap mass looks wrong. Re-weigh the parts.',
      adminUid: 'admin_1',
    });

    await expect(
      skus.saveSkuDraft({
        skuId,
        orgId: 'org_cola',
        draft: DRAFT,
        actorUid: 'uid_reporter',
      }),
    ).resolves.toBeTruthy();
  });
});

describe('re-verification is due lazily (EPR-13, NFR-E-2)', () => {
  const policy = { massRevalidationMonths: 12 };

  test('a mass verified within the interval is not due', () => {
    expect(
      skus.revalidationDue(
        { massStatus: 'verified', verifiedAt: { toDate: () => new Date('2026-06-01') } },
        policy,
        new Date('2026-09-09'),
      ),
    ).toBe(false);
  });

  test('a mass older than the interval is due', () => {
    // Packaging is light-weighted constantly: a 2026 bottle weighs less than a
    // 2024 one.
    expect(
      skus.revalidationDue(
        { massStatus: 'verified', verifiedAt: { toDate: () => new Date('2025-06-01') } },
        policy,
        new Date('2026-09-09'),
      ),
    ).toBe(true);
  });

  test('an unverified product is never "due" — it is simply unverified', () => {
    expect(
      skus.revalidationDue(
        { massStatus: 'submitted', verifiedAt: { toDate: () => new Date('2020-01-01') } },
        policy,
        new Date('2026-09-09'),
      ),
    ).toBe(false);
  });

  test('a verified product with no timestamp is not reported as due', () => {
    // Nothing rewrites a status when a clock passes, so an absent timestamp is
    // a data gap rather than an overdue item; flagging it would fill the queue
    // with rows nobody can action.
    expect(
      skus.revalidationDue({ massStatus: 'verified' }, policy, new Date()),
    ).toBe(false);
  });
});

describe('the verification queue (EPR-42)', () => {
  test('lists only submitted declarations', async () => {
    await skus.saveSkuDraft({ orgId: 'org_cola', draft: DRAFT, actorUid: 'u' });
    const submitted = await seedVerifiableSku();

    const queue = await skus.listVerificationQueue({});
    expect(queue).toHaveLength(1);
    expect(queue[0].skuId).toBe(submitted);
  });
});
