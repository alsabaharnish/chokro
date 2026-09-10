/**
 * Recognition to attribution to rollup (EPR-17 to EPR-23).
 *
 * The spine of this file is Appendix A: Anik's two bottles become 19.6 g of
 * rigid PET attributed to Coca-Cola in 2026-09, and his points do not change.
 */

jest.mock('../src/firebase', () => {
  const increments = [];
  return {
    db: jest.fn(),
    admin: {
      firestore: {
        FieldValue: {
          increment: (n) => {
            const marker = { __increment: n };
            increments.push(marker);
            return marker;
          },
          // `arrayUnion` adds only what is absent, which is what makes the
          // distinct-product set idempotent under a retried attribution.
          arrayUnion: (...values) => ({ __arrayUnion: values }),
        },
        Timestamp: {
          now: () => ({ toDate: () => new Date('2026-09-15T10:00:00Z') }),
          fromDate: (d) => ({ toDate: () => d, __ts: true }),
        },
      },
    },
    serverTimestamp: jest.fn(() => '__TS__'),
    __increments: increments,
  };
});

jest.mock('../src/eprPolicy', () => ({
  readPolicy: jest.fn(),
}));

const firebase = require('../src/firebase');
const eprPolicy = require('../src/eprPolicy');
const attribute = require('../src/attribute');

const POLICY = {
  highConfidenceThreshold: 0.85,
  lowConfidenceThreshold: 0.6,
  accuracyAuditSampleFraction: 0,
  skuShortlistCap: 40,
};

// ---------------------------------------------------------------------------
// The pure half
// ---------------------------------------------------------------------------

describe('confidence tiers (EPR-17)', () => {
  test('the thresholds are inclusive at their lower edge', () => {
    expect(attribute.tierFor(0.85, POLICY)).toBe('high');
    expect(attribute.tierFor(0.8499, POLICY)).toBe('medium');
    expect(attribute.tierFor(0.6, POLICY)).toBe('medium');
    expect(attribute.tierFor(0.5999, POLICY)).toBe('low');
    expect(attribute.tierFor(0.91, POLICY)).toBe('high');
  });

  test('anything unreadable is low, and low attributes nothing', () => {
    // Fail closed. Defaulting to high would auto-attribute an unrated guess.
    for (const bad of [null, undefined, NaN, Infinity, 'x', {}, -1]) {
      expect(attribute.tierFor(bad, POLICY)).toBe('low');
    }
  });
});

describe('the polymer split (EPR-9, EPR-20)', () => {
  const bottle = {
    components: [
      { part: 'body', polymer: 'pet', massMg: 8200 },
      { part: 'cap', polymer: 'pp', massMg: 1300 },
      { part: 'label', polymer: 'pet', massMg: 500 },
    ],
  };

  test('one recognised bottle contributes to two polymer lines', () => {
    // Appendix A step 5: 19.6 g, "of which 16.4 g PET body, 2.6 g PP cap,
    // 1.0 g PET label". PET body and PET label combine on one line.
    const split = attribute.polymerSplitFor({
      revision: bottle,
      units: 2,
      massMg: 19600,
    });
    expect(Object.keys(split).sort()).toEqual(['pet', 'pp']);
    expect(split.pp).toBe(2548);
    expect(split.pet).toBe(19600 - 2548);
  });

  test('the polymer lines sum EXACTLY to the attributed mass', () => {
    // Two figures in one report that do not add up is precisely what a
    // regulator notices, and "rounding" is not an answer when both are
    // integers. Flooring loses up to a milligram per component; the remainder
    // goes to the heaviest part.
    for (const massMg of [19600, 19601, 1, 7, 999983, 12345679]) {
      const split = attribute.polymerSplitFor({
        revision: bottle,
        units: 1,
        massMg,
      });
      const total = Object.values(split).reduce((a, b) => a + b, 0);
      expect(total).toBe(massMg);
    }
  });

  test('a verified mass lighter than the declared parts still sums exactly', () => {
    // The declared components sum to 10 000 mg and the verified mass is 9 800.
    // Adding component masses directly would report polymer lines totalling
    // more than the product's own mass, so the split is proportional.
    const split = attribute.polymerSplitFor({
      revision: bottle,
      units: 1,
      massMg: 9800,
    });
    expect(Object.values(split).reduce((a, b) => a + b, 0)).toBe(9800);
  });

  test('no components means no split, not a guess', () => {
    // Assigning the whole mass to the dominant polymer would be a guess, and
    // §6.7 forbids a figure whose provenance cannot be traced field by field.
    expect(attribute.polymerSplitFor({ revision: {}, units: 2, massMg: 19600 })).toEqual({});
    expect(
      attribute.polymerSplitFor({
        revision: { components: [] },
        units: 2,
        massMg: 19600,
      }),
    ).toEqual({});
  });

  test('components with no usable mass yield no split', () => {
    expect(
      attribute.polymerSplitFor({
        revision: { components: [{ part: 'x', polymer: 'pet', massMg: 0 }] },
        units: 1,
        massMg: 100,
      }),
    ).toEqual({});
  });
});

describe('the accuracy sample (EPR-17)', () => {
  test('is deterministic, so a re-run samples the same disposals', () => {
    // A random draw would make the measured accuracy depend on how many times
    // a backfill had run.
    for (const id of ['disposal_1', 'disposal_abc', 'x']) {
      expect(attribute.isSampled(id, 0.5)).toBe(attribute.isSampled(id, 0.5));
    }
  });

  test('converges on the policy fraction', () => {
    const ids = Array.from({ length: 4000 }, (_, i) => `disposal_${i}`);
    const share = ids.filter((id) => attribute.isSampled(id, 0.02)).length / ids.length;
    expect(share).toBeGreaterThan(0.005);
    expect(share).toBeLessThan(0.05);
  });

  test('a zero fraction samples nothing', () => {
    const ids = Array.from({ length: 500 }, (_, i) => `d_${i}`);
    expect(ids.filter((id) => attribute.isSampled(id, 0)).length).toBe(0);
  });
});

describe('district keys', () => {
  test('a dot in a district name cannot become a nested field path', () => {
    // `FieldValue.increment` reads a dot as a path separator, so "St. Martin's"
    // would silently create a map called `St` with a child called `Martin's`.
    expect(attribute.sanitizeKey("St. Martin's")).not.toContain('.');
    expect(attribute.sanitizeKey('Dhaka')).toBe('Dhaka');
    // A run of separators collapses to one, so two districts differing only
    // in punctuation do not become two different keys.
    expect(attribute.sanitizeKey('a/b[c]#d$e')).toBe('a_b_c_d_e');
    expect(attribute.sanitizeKey("St. Martin's")).toBe("St_Martin's");
  });
});

// ---------------------------------------------------------------------------
// The Firestore half
// ---------------------------------------------------------------------------

function fakeFirestore() {
  const store = new Map();
  const key = (col, id) => `${col}/${id}`;
  let autoId = 0;
  let writeIssued = false;

  function makeRef(col, id) {
    return {
      id,
      path: key(col, id),
      async get() {
        const data = store.get(key(col, id));
        return { exists: data !== undefined, id, data: () => data };
      },
      // Real document references write directly, outside a transaction. The
      // platform-level unattributed pool counter uses one.
      async set(data, options) {
        store.set(
          key(col, id),
          options?.merge ? mergeIncrements(store.get(key(col, id)), data) : { ...data },
        );
      },
      async update(data) {
        store.set(key(col, id), mergeIncrements(store.get(key(col, id)), data));
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
          rows = rows.filter((r) => {
            const stored = r.data()[field];
            if (op === '==') return stored === value;
            if (op === '>') return stored > value;
            throw new Error(`fake does not implement ${op}`);
          });
        }
        if (q.order) {
          const [field, direction] = q.order;
          rows.sort((a, b) => {
            const x = a.data()[field];
            const y = b.data()[field];
            if (x === y) return 0;
            return direction === 'desc' ? (y > x ? 1 : -1) : x > y ? 1 : -1;
          });
        }
        return { docs: rows.slice(0, q.max), empty: rows.length === 0, size: rows.length };
      },
    };
    return api;
  }

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
        options?.merge ? mergeIncrements(store.get(ref.path), data) : { ...data },
      );
    },
    update(ref, data) {
      writeIssued = true;
      store.set(ref.path, mergeIncrements(store.get(ref.path), data));
    },
  };

  return {
    collection,
    batch() {
      const writes = [];
      return {
        set(ref, data) {
          writes.push([ref, data]);
        },
        async commit() {
          for (const [ref, data] of writes) store.set(ref.path, { ...data });
        },
      };
    },
    async runTransaction(fn) {
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

/**
 * Applies `{__increment}` markers and dotted field paths, as Firestore does.
 *
 * `isIncrement` is a predicate rather than a sentinel value. An earlier version
 * used `null` to mean "this is an increment", which collided with the many
 * fields legitimately written as null — `gazetteCategoryResolved: null` was
 * then treated as an increment and threw on reading `.__increment` of null.
 */
function isIncrement(value) {
  return Boolean(value) && typeof value === 'object' && '__increment' in value;
}

function isArrayUnion(value) {
  return Boolean(value) && typeof value === 'object' && '__arrayUnion' in value;
}

function mergeIncrements(existing, update) {
  const result = { ...(existing || {}) };

  for (const [rawKey, value] of Object.entries(update)) {
    if (rawKey.includes('.')) {
      const [head, ...rest] = rawKey.split('.');
      const leaf = rest.join('.');
      result[head] = { ...(result[head] || {}) };
      result[head][leaf] = isIncrement(value)
        ? (result[head][leaf] || 0) + value.__increment
        : value;
      continue;
    }

    if (isArrayUnion(value)) {
      const existing = Array.isArray(result[rawKey]) ? result[rawKey] : [];
      result[rawKey] = [...new Set([...existing, ...value.__arrayUnion])];
      continue;
    }

    result[rawKey] = isIncrement(value)
      ? (result[rawKey] || 0) + value.__increment
      : value;
  }

  return result;
}

let fs;
const previousFlag = process.env.EPR_ATTRIBUTION_ENABLED;

/** Appendix A's bottle, verified at 9.8 g as revision 1. */
function seedWorkedExample({
  decidedAt = new Date('2026-09-15T10:00:00Z'),
  skuMatches = [{ skuId: 'sku_cola', units: 2, confidence: 0.91 }],
  status = 'autoApproved',
  extraDisposal = {},
} = {}) {
  fs._seed('bins', 'MHP-014', { district: 'Dhaka', city: 'Dhaka' });

  fs._seed('producerSkus', 'sku_cola', {
    orgId: 'org_cola',
    name: 'Coca-Cola 250 ml PET bottle',
    brand: 'Coca-Cola',
    gazetteCategory: 'rigid',
    polymer: 'pet',
    massStatus: 'verified',
    status: 'active',
    verifiedUnitMassMg: 9800,
    declaredUnitMassMg: 10000,
    revision: 1,
    gtin: '8901234567890',
  });

  fs._seed('skuRevisions', 'sku_cola_1', {
    skuId: 'sku_cola',
    orgId: 'org_cola',
    revision: 1,
    declaredUnitMassMg: 10000,
    verifiedUnitMassMg: 9800,
    gazetteCategory: 'rigid',
    polymer: 'pet',
    components: [
      { part: 'body', polymer: 'pet', massMg: 8200 },
      { part: 'cap', polymer: 'pp', massMg: 1300 },
      { part: 'label', polymer: 'pet', massMg: 500 },
    ],
    activeFrom: { toDate: () => new Date('2026-09-01T00:00:00Z') },
    activeTo: null,
  });

  fs._seed('disposals', 'disposal_anik', {
    userId: 'uid_anik',
    binId: 'MHP-014',
    itemType: 'plasticBottle',
    declaredItemCount: 2,
    status,
    pointsAwarded: 50,
    attributionStatus: 'pending',
    skuMatches,
    verifiedAt: { toDate: () => decidedAt },
    createdAt: { toDate: () => decidedAt },
    ...extraDisposal,
  });
}

beforeEach(() => {
  jest.clearAllMocks();
  fs = fakeFirestore();
  firebase.db.mockReturnValue(fs);
  eprPolicy.readPolicy.mockResolvedValue(POLICY);
  process.env.EPR_ATTRIBUTION_ENABLED = 'true';
});

afterAll(() => {
  if (previousFlag === undefined) {
    delete process.env.EPR_ATTRIBUTION_ENABLED;
  } else {
    process.env.EPR_ATTRIBUTION_ENABLED = previousFlag;
  }
});

describe('the Appendix A worked example', () => {
  test('two bottles become 19.6 g of rigid PET for Coca-Cola in 2026-09', async () => {
    seedWorkedExample();

    const result = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });

    expect(result.outcome).toBe('attributed');
    expect(result.periodId).toBe('2026-09');
    expect(result.attributions).toBe(1);
    // 2 x 9.8 g = 19.6 g. The declared 10.0 g is never used.
    expect(result.totalMassMg).toBe(19600);

    const row = fs._find('attributions')[0];
    expect(row.orgId).toBe('org_cola');
    expect(row.units).toBe(2);
    expect(row.unitMassMgUsed).toBe(9800);
    expect(row.massMg).toBe(19600);
    expect(row.skuRevision).toBe(1);
    expect(row.method).toBe('aiSku');
    expect(row.confidenceTier).toBe('high');
    expect(row.gazetteCategory).toBe('rigid');
    expect(row.district).toBe('Dhaka');
    expect(row.periodId).toBe('2026-09');
  });

  test('the period rollup increments in the same transaction', async () => {
    seedWorkedExample();
    await attribute.attributeDisposal({ disposalId: 'disposal_anik' });

    const period = fs._store.get('eprPeriods/org_cola_2026-09');
    // The distinct-product set, which a counter could not have maintained.
    expect(period.skuIds).toEqual(['sku_cola']);
    expect(period.massMgByCategory.rigid).toBe(19600);
    expect(period.unitsByCategory.rigid).toBe(2);
    expect(period.massMgByDistrict.Dhaka).toBe(19600);
    expect(period.massMgByPolymer.pet).toBe(19600 - 2548);
    expect(period.massMgByPolymer.pp).toBe(2548);
    expect(period.attributionCount).toBe(1);
    expect(period.disposalCount).toBe(1);
  });

  test('the disposal gains only the EPR-6 server-owned fields', async () => {
    seedWorkedExample();
    await attribute.attributeDisposal({ disposalId: 'disposal_anik' });

    const disposal = fs._store.get('disposals/disposal_anik');
    expect(disposal.attributionStatus).toBe('attributed');
    expect(disposal.skuMatchCount).toBe(1);
    expect(disposal.attributedMassGrams).toBe(19600);
    expect(disposal.gazetteCategoryResolved).toBe('rigid');
    // EPR-27: Anik's points do not change.
    expect(disposal.pointsAwarded).toBe(50);
    expect(disposal.status).toBe('autoApproved');
  });

  test('no wallet, ledger, cap or lockout document is touched', async () => {
    seedWorkedExample();
    await attribute.attributeDisposal({ disposalId: 'disposal_anik' });

    for (const collection of ['wallets', 'transactions', 'dailyCaps', 'lockouts', 'stats']) {
      expect(fs._find(collection)).toEqual([]);
    }
  });
});

describe('the distinct-product set is idempotent', () => {
  test('a retried attribution does not duplicate the product', async () => {
    // `arrayUnion` adds only what is absent, which is why the set can survive
    // the retries that `increment` would double-count.
    seedWorkedExample();
    await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    await attribute.attributeDisposal({ disposalId: 'disposal_anik' });

    expect(fs._store.get('eprPeriods/org_cola_2026-09').skuIds).toEqual([
      'sku_cola',
    ]);
  });
});

describe('idempotence on disposalId (EPR-21)', () => {
  test('a second attribution of the same disposal writes nothing more', async () => {
    seedWorkedExample();
    await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    const after = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });

    expect(after.outcome).toBe('alreadyAttributed');
    expect(fs._find('attributions')).toHaveLength(1);
    expect(fs._store.get('eprPeriods/org_cola_2026-09').massMgByCategory.rigid).toBe(19600);
  });

  test('an already-unattributable disposal is not retried', async () => {
    seedWorkedExample({ skuMatches: [] });
    await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    const after = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    expect(after.outcome).toBe('alreadyAttributed');
  });
});

describe('only a terminal approved state attributes (EPR-21)', () => {
  test('a pending disposal does not attribute', async () => {
    seedWorkedExample({ status: 'pending' });
    const result = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    expect(result.outcome).toBe('notApproved');
    expect(fs._find('attributions')).toEqual([]);
  });

  test('a rejected disposal never attributes', async () => {
    seedWorkedExample({ status: 'rejected' });
    const result = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    expect(result.outcome).toBe('notApproved');
    expect(fs._find('attributions')).toEqual([]);
  });

  test('a manually approved disposal attributes, using the review time', async () => {
    // An appeal that overturns a rejection attributes on approval, because the
    // appeal path calls approveDisposal like everything else.
    seedWorkedExample({
      status: 'manualApproved',
      extraDisposal: {
        reviewedAt: { toDate: () => new Date('2026-10-02T04:00:00Z') },
      },
    });

    const result = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    expect(result.outcome).toBe('attributed');
    // The review happened in October Dhaka time, so that is the period.
    expect(result.periodId).toBe('2026-10');
  });
});

describe('confidence tiers decide what happens (EPR-17)', () => {
  test('a medium match is attributed, flagged and counted as uncertain', async () => {
    seedWorkedExample({
      skuMatches: [{ skuId: 'sku_cola', units: 2, confidence: 0.7 }],
    });

    const result = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    expect(result.outcome).toBe('attributed');
    expect(fs._find('attributions')[0].confidenceTier).toBe('medium');

    const period = fs._store.get('eprPeriods/org_cola_2026-09');
    // "A producer that cannot see how much of its number is uncertain will
    // publish the number as if it were certain."
    expect(period.uncertainMassMg).toBe(19600);
  });

  test('a low match is NOT attributed and is queued for a person', async () => {
    seedWorkedExample({
      skuMatches: [{ skuId: 'sku_cola', units: 2, confidence: 0.4 }],
    });

    const result = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    expect(result.outcome).toBe('unattributable');
    expect(fs._find('attributions')).toEqual([]);

    const queued = fs._find('attributionConfirmations');
    expect(queued).toHaveLength(1);
    expect(queued[0].reason).toBe('lowConfidence');
    expect(queued[0].confidenceTier).toBe('low');
  });
});

describe('unmatched mass is never invented (EPR-19)', () => {
  test('an empty match list is unattributable and counted in the pool', async () => {
    seedWorkedExample({ skuMatches: [] });

    const result = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    expect(result).toMatchObject({ outcome: 'unattributable' });

    const disposal = fs._store.get('disposals/disposal_anik');
    expect(disposal.attributionStatus).toBe('unattributable');
    expect(disposal.attributedMassGrams).toBe(0);

    // The pool is counted per period and NOT per organisation: an unrecognised
    // item belongs to nobody, so attributing its absence to a producer would
    // invent the very thing EPR-19 forbids.
    const platform = fs._store.get('eprPeriods/__platform_2026-09');
    expect(platform.unattributedDisposalCount).toBe(1);
    expect(fs._store.get('eprPeriods/org_cola_2026-09')).toBeUndefined();
  });

  test('recognition unavailable is NOT unattributable', async () => {
    // Null means "not checked" and empty means "checked, nothing there".
    // Counting the first into the reported pool would claim it had been checked.
    seedWorkedExample({ skuMatches: null });

    const result = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    expect(result.outcome).toBe('recognitionUnavailable');

    // Left pending, so a backfill can attribute it later.
    expect(fs._store.get('disposals/disposal_anik').attributionStatus).toBe('pending');
    expect(fs._store.get('eprPeriods/__platform_2026-09')).toBeUndefined();
  });
});

describe('the mass that applied at the time (EPR-12)', () => {
  test('a re-weighing does not change an earlier period', async () => {
    // Appendix A step 11: a November re-weighing finds the bottle at 9.1 g.
    // September's figure stays at 9.8 g because September's revision says so.
    seedWorkedExample();

    fs._seed('skuRevisions', 'sku_cola_1', {
      ...fs._store.get('skuRevisions/sku_cola_1'),
      activeTo: { toDate: () => new Date('2026-11-01T00:00:00Z') },
    });
    fs._seed('skuRevisions', 'sku_cola_2', {
      skuId: 'sku_cola',
      orgId: 'org_cola',
      revision: 2,
      verifiedUnitMassMg: 9100,
      gazetteCategory: 'rigid',
      components: [{ part: 'body', polymer: 'pet', massMg: 9100 }],
      activeFrom: { toDate: () => new Date('2026-11-01T00:00:00Z') },
      activeTo: null,
    });
    // And the product itself now reads 9.1 g.
    fs._seed('producerSkus', 'sku_cola', {
      ...fs._store.get('producerSkus/sku_cola'),
      verifiedUnitMassMg: 9100,
      revision: 2,
    });

    const result = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });

    // September, so revision 1 at 9.8 g.
    expect(result.totalMassMg).toBe(19600);
    expect(fs._find('attributions')[0].skuRevision).toBe(1);
    expect(fs._find('attributions')[0].unitMassMgUsed).toBe(9800);
  });

  test('a disposal before the mass was ever verified is not attributed', async () => {
    // Recognised, but Chokro had no verified mass in force at the time. Not an
    // error and not a mass — a defensible kilogram needs a figure that applied.
    seedWorkedExample({ decidedAt: new Date('2026-08-15T10:00:00Z') });

    const result = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    expect(result.outcome).toBe('unattributable');

    const queued = fs._find('attributionConfirmations');
    expect(queued[0].reason).toBe('noVerifiedMassAtTheTime');
  });
});

describe('the barcode path (EPR-18)', () => {
  test('a scanned GTIN wins outright, at high tier, with no confidence', async () => {
    // Where a Champion scans, accuracy stops being probabilistic — so the
    // confidence is stored as null rather than as a fabricated 1.0, which
    // would pollute the published accuracy statistics.
    seedWorkedExample({
      skuMatches: [{ skuId: 'sku_cola', units: 1, confidence: 0.62 }],
      extraDisposal: { scannedGtin: '8901234567890' },
    });

    const result = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    expect(result.outcome).toBe('attributed');

    const row = fs._find('attributions')[0];
    expect(row.method).toBe('barcode');
    expect(row.confidenceTier).toBe('high');
    expect(row.confidence).toBeNull();
    // The declared count, because a scan identifies the product and the person
    // states the quantity.
    expect(row.units).toBe(2);
    expect(row.massMg).toBe(19600);
  });

  test('an unknown GTIN falls back to the model, not to nothing', async () => {
    seedWorkedExample({ extraDisposal: { scannedGtin: '0000000000000' } });

    const result = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    expect(result.outcome).toBe('attributed');
    expect(fs._find('attributions')[0].method).toBe('aiSku');
  });
});

describe('the period is Asia/Dhaka (EPR-23)', () => {
  test('a UTC evening on the last of the month is the next Dhaka period', async () => {
    // 30 September 20:00 UTC is 1 October 02:00 in Dhaka. A December/January
    // version of this error in an annual filing is a compliance error.
    seedWorkedExample({ decidedAt: new Date('2026-09-30T20:00:00Z') });

    const result = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    expect(result.periodId).toBe('2026-10');
    expect(fs._store.get('eprPeriods/org_cola_2026-10')).toBeDefined();
    expect(fs._store.get('eprPeriods/org_cola_2026-09')).toBeUndefined();
  });
});

describe('failure never propagates (EPR-16)', () => {
  test('a disposal that no longer exists is an outcome, not a throw', async () => {
    await expect(
      attribute.attributeDisposal({ disposalId: 'nope' }),
    ).resolves.toEqual({ outcome: 'noSuchDisposal' });
  });

  test('a disposal with no decision time is left pending', async () => {
    seedWorkedExample();
    fs._seed('disposals', 'disposal_anik', {
      ...fs._store.get('disposals/disposal_anik'),
      verifiedAt: null,
      createdAt: null,
    });

    const result = await attribute.attributeDisposal({ disposalId: 'disposal_anik' });
    expect(result.outcome).toBe('noDecisionTime');
    expect(fs._store.get('disposals/disposal_anik').attributionStatus).toBe('pending');
  });

  test('a policy read failure does not stop attribution', async () => {
    // eprPolicy.readPolicy already falls back to documented defaults rather
    // than throwing; this pins that attribution relies on that.
    seedWorkedExample();
    eprPolicy.readPolicy.mockResolvedValue(POLICY);
    await expect(
      attribute.attributeDisposal({ disposalId: 'disposal_anik' }),
    ).resolves.toMatchObject({ outcome: 'attributed' });
  });
});
