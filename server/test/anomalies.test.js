/**
 * The anomaly queue (EPR-45, SEC-3, SEC-12).
 *
 * `anomalyMath.test.js` covers whether a set of figures is strange. This covers
 * what happens to a finding afterwards — and the two behaviours that decide
 * whether the queue is usable at all:
 *
 *   A re-scan must not duplicate a finding. A queue that grows every time an
 *   Admin triggers a scan is one nobody can work through.
 *
 *   A dismissal must survive a re-scan. An Admin who decided a concentration
 *   was a bottling plant should not have to decide it again.
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
const anomalies = require('../src/anomalies');
const audit = require('../src/producerAudit');
const { fakeFirestore } = require('./helpers/firestoreFake');

let fs;

const ORG = 'org_cola';
const PERIOD = '2026-09';
const MG = 1000000;

const POLICY = {
  anomalySkuMassMultiple: 4,
  anomalyBinShare: 0.5,
  anomalyAccountShare: 0.3,
  anomalyConfidenceDrift: 0.20,
  anomalyUnitMassIqrMultiple: 1.5,
  anomalyTargetMargin: 0.02,
  anomalyTargetFilingDays: 3,
};

/** One attribution row, with the fields the detectors read. */
function attribution(id, over = {}) {
  return {
    orgId: ORG,
    periodId: PERIOD,
    skuId: 'sku_cola',
    massMg: 20000,
    units: 2,
    binId: 'bin_a',
    disposedBy: 'uid_champion_1',
    confidenceTier: 'high',
    createdAt: { toDate: () => new Date('2026-09-14T09:00:00Z') },
    ...over,
    id,
  };
}

function seedAttributions(rows) {
  for (const row of rows) {
    const { id, ...data } = row;
    fs._seed('attributions', id, data);
  }
}

beforeEach(() => {
  jest.clearAllMocks();
  fs = fakeFirestore();
  firebase.db.mockReturnValue(fs);
  eprPolicy.readPolicy.mockResolvedValue(POLICY);

  fs._seed('organizations', ORG, {
    legalName: 'Coca-Cola Bangladesh Beverages Ltd.',
    tradeName: 'Coca-Cola Bangladesh',
    status: 'active',
    obligationStartDate: { toDate: () => new Date('2026-07-01T00:00:00Z') },
  });
});

const scan = (over = {}) =>
  anomalies.scanPeriod({
    orgId: ORG,
    periodId: PERIOD,
    adminUid: 'uid_admin',
    adminName: 'Chokro Compliance',
    ...over,
  });

// ---------------------------------------------------------------------------
// Identity
// ---------------------------------------------------------------------------

describe('a finding’s identity', () => {
  test('is derived from what the finding is, not randomly', () => {
    const args = { orgId: ORG, periodId: PERIOD, type: 'skuMassSpike', subjectId: 'sku_a' };
    expect(anomalies.findingId(args)).toBe(anomalies.findingId(args));
  });

  test('distinguishes every field that makes it a different finding', () => {
    const base = { orgId: ORG, periodId: PERIOD, type: 'skuMassSpike', subjectId: 'sku_a' };
    const id = anomalies.findingId(base);

    expect(anomalies.findingId({ ...base, orgId: 'org_pran' })).not.toBe(id);
    expect(anomalies.findingId({ ...base, periodId: '2026-08' })).not.toBe(id);
    expect(anomalies.findingId({ ...base, type: 'confidenceDrift' })).not.toBe(id);
    expect(anomalies.findingId({ ...base, subjectId: 'sku_b' })).not.toBe(id);
  });

  test('cannot be collided by concatenation', () => {
    // The separator is the unit separator, which cannot appear in any of the
    // four fields — so `org|2026-09` and `org|2026|-09` cannot digest alike.
    expect(
      anomalies.findingId({ orgId: 'a', periodId: 'b', type: 'c', subjectId: 'd' }),
    ).not.toBe(
      anomalies.findingId({ orgId: 'ab', periodId: '', type: 'c', subjectId: 'd' }),
    );
  });
});

// ---------------------------------------------------------------------------
// Concentration, from the rows
// ---------------------------------------------------------------------------

describe('concentration over a period’s rows', () => {
  test('finds a bin carrying most of the mass', () => {
    const rows = [
      ...Array.from({ length: 5 }, (_, i) =>
        attribution(`a${i}`, { binId: 'bin_hot', massMg: 20 * MG })),
      ...Array.from({ length: 5 }, (_, i) =>
        attribution(`b${i}`, { binId: `bin_${i}`, massMg: 1 * MG })),
    ];

    const findings = anomalies.concentrationFindings({ rows, policy: POLICY });
    const bin = findings.find((f) => f && f.subjectId === 'bin_hot');

    expect(bin.type).toBe('binConcentration');
    expect(bin.figures.share).toBeCloseTo(100 / 105, 2);
  });

  test('excludes reversed rows from the totals', () => {
    // EPR-21 reverses rather than deletes, and the period rollup excludes
    // reversed mass — so a detector that counted it would disagree with every
    // other figure Chokro states.
    const rows = [
      ...Array.from({ length: 6 }, (_, i) =>
        attribution(`a${i}`, { binId: `bin_${i}`, massMg: 10 * MG })),
      attribution('reversed', {
        binId: 'bin_hot',
        massMg: 900 * MG,
        reversedAt: { toDate: () => new Date() },
      }),
    ];

    const findings = anomalies.concentrationFindings({ rows, policy: POLICY });
    expect(findings.filter(Boolean)).toEqual([]);
  });

  test('says nothing about a period with no mass', () => {
    expect(
      anomalies.concentrationFindings({ rows: [], policy: POLICY }),
    ).toEqual([]);
  });

  test('carries an account as a uid and nothing else', () => {
    // SEC-3. This is the one detector that names a person.
    const rows = [
      ...Array.from({ length: 5 }, (_, i) =>
        attribution(`a${i}`, { disposedBy: 'uid_farmer', massMg: 20 * MG, binId: `bin_${i}` })),
      ...Array.from({ length: 5 }, (_, i) =>
        attribution(`b${i}`, { disposedBy: `uid_${i}`, massMg: 1 * MG, binId: `bin_${i}` })),
    ];

    const account = anomalies
      .concentrationFindings({ rows, policy: POLICY })
      .find((f) => f && f.type === 'accountConcentration');

    expect(account.subjectId).toBe('uid_farmer');
    expect(JSON.stringify(account)).not.toMatch(/email|phone|displayName/i);
  });
});

// ---------------------------------------------------------------------------
// Scanning and the queue
// ---------------------------------------------------------------------------

describe('scanning a period', () => {
  /** Enough history and a large enough jump to trip the mass-spike detector. */
  function seedSpike() {
    for (const prior of ['2026-08', '2026-07', '2026-06']) {
      seedAttributions([
        attribution(`${prior}_a`, { periodId: prior, massMg: 2 * MG }),
      ]);
    }
    seedAttributions([attribution('cur_a', { massMg: 40 * MG })]);
  }

  test('writes a finding and records the scan in the audit chain', async () => {
    seedSpike();
    const result = await scan();

    expect(result.attributionsExamined).toBe(1);
    expect(result.created).toBeGreaterThan(0);

    const stored = fs._find(anomalies.ANOMALIES);
    expect(stored.some((f) => f.type === 'skuMassSpike')).toBe(true);
    expect(stored[0].status).toBe('open');

    // SEC-12: the scan itself is a recorded event, so a queue that was never
    // run is distinguishable from one that was run and found nothing.
    expect(
      fs._find(audit.COLLECTION).some((e) => e.action === audit.ACTIONS.ANOMALY_SCAN),
    ).toBe(true);
  });

  test('is idempotent — a re-scan updates rather than duplicating', async () => {
    seedSpike();
    const first = await scan();
    const before = fs._find(anomalies.ANOMALIES).length;

    const second = await scan();

    expect(first.created).toBeGreaterThan(0);
    expect(second.created).toBe(0);
    expect(second.updated).toBe(first.created);
    expect(fs._find(anomalies.ANOMALIES)).toHaveLength(before);
  });

  test('a dismissal survives a re-scan', async () => {
    // THE BEHAVIOUR THE QUEUE LIVES OR DIES ON. An Admin who looked at a
    // finding and decided it was a bottling plant should not have to decide it
    // again every time somebody triggers a scan.
    seedSpike();
    await scan();

    const [finding] = fs._find(anomalies.ANOMALIES);
    await anomalies.dismiss({
      id: finding.id,
      reason: 'Confirmed with the producer: a new distributor in Khulna.',
      adminUid: 'uid_admin',
    });

    await scan();

    const after = fs._store.get(`${anomalies.ANOMALIES}/${finding.id}`);
    expect(after.status).toBe('dismissed');
    expect(after.dismissedReason).toMatch(/Khulna/);
  });

  test('a re-scan still refreshes what the finding says', async () => {
    seedSpike();
    await scan();
    const [before] = fs._find(anomalies.ANOMALIES);

    // The mass grows further.
    seedAttributions([attribution('cur_b', { massMg: 60 * MG })]);
    await scan();

    const after = fs._store.get(`${anomalies.ANOMALIES}/${before.id}`);
    expect(after.figures.currentMassMg).toBeGreaterThan(before.figures.currentMassMg);
  });

  test('refuses a period that is not one', async () => {
    await expect(scan({ periodId: '2026-9' })).rejects.toThrow(/reporting period/i);
  });

  test('a quiet period produces no findings and still records the scan', async () => {
    seedAttributions([attribution('a1', { massMg: 20000 })]);
    const result = await scan();

    expect(result.findings).toBe(0);
    expect(fs._find(anomalies.ANOMALIES)).toEqual([]);
    // The scan is still recorded: "we looked and found nothing" is a different
    // statement from "we never looked", and an auditor asks which.
    expect(
      fs._find(audit.COLLECTION).some((e) => e.action === audit.ACTIONS.ANOMALY_SCAN),
    ).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Closing a finding
// ---------------------------------------------------------------------------

describe('closing a finding', () => {
  async function openFinding() {
    for (const prior of ['2026-08', '2026-07', '2026-06']) {
      seedAttributions([attribution(`${prior}_a`, { periodId: prior, massMg: 2 * MG })]);
    }
    seedAttributions([attribution('cur_a', { massMg: 40 * MG })]);
    await scan();
    return fs._find(anomalies.ANOMALIES)[0];
  }

  test('requires a reason', async () => {
    const finding = await openFinding();
    for (const reason of [undefined, '', '   ', 'no']) {
      await expect(
        anomalies.dismiss({ id: finding.id, reason, adminUid: 'uid_admin' }),
      ).rejects.toThrow(/why/i);
    }
  });

  test('records the reason in the audit chain', async () => {
    // SEC-12: a dismissal with no stated basis is indistinguishable from an
    // insider clearing the queue.
    const finding = await openFinding();
    await anomalies.dismiss({
      id: finding.id,
      reason: 'A new distributor in Khulna, confirmed by the producer.',
      adminUid: 'uid_admin',
      adminName: 'Chokro Compliance',
    });

    const entry = fs._find(audit.COLLECTION)
      .find((e) => e.action === audit.ACTIONS.ANOMALY_DISMISSED);
    expect(entry.summary).toMatch(/Khulna/);
    expect(entry.actorUid).toBe('uid_admin');
  });

  test('distinguishes dismissed from actioned', async () => {
    // Collapsing them would make the queue's own history useless for the
    // question an auditor asks: how many of these turned out to be real.
    const finding = await openFinding();
    await anomalies.dismiss({
      id: finding.id,
      reason: 'Confirmed a re-registered unit mass; the SKU was re-weighed.',
      outcome: 'actioned',
      adminUid: 'uid_admin',
    });

    expect(fs._store.get(`${anomalies.ANOMALIES}/${finding.id}`).status).toBe('actioned');
  });

  test('refuses an outcome that is neither', async () => {
    const finding = await openFinding();
    await expect(
      anomalies.dismiss({
        id: finding.id,
        reason: 'A perfectly good reason.',
        outcome: 'ignored',
        adminUid: 'uid_admin',
      }),
    ).rejects.toThrow(/dismissed or actioned/i);
  });

  test('will not close the same finding twice', async () => {
    const finding = await openFinding();
    await anomalies.dismiss({
      id: finding.id, reason: 'A first good reason.', adminUid: 'uid_admin',
    });
    await expect(
      anomalies.dismiss({
        id: finding.id, reason: 'A second good reason.', adminUid: 'uid_admin',
      }),
    ).rejects.toThrow(/already been closed/i);
  });

  test('refuses a finding that does not exist', async () => {
    await expect(
      anomalies.dismiss({
        id: 'nope', reason: 'A perfectly good reason.', adminUid: 'uid_admin',
      }),
    ).rejects.toThrow(/does not exist/i);
  });
});

describe('the queue', () => {
  test('lists open findings and excludes closed ones', async () => {
    fs._seed(anomalies.ANOMALIES, 'f1', {
      id: 'f1', orgId: ORG, periodId: PERIOD, status: 'open',
      type: 'skuMassSpike', firstSeenAt: new Date('2026-10-01'),
    });
    fs._seed(anomalies.ANOMALIES, 'f2', {
      id: 'f2', orgId: ORG, periodId: PERIOD, status: 'dismissed',
      type: 'binConcentration', firstSeenAt: new Date('2026-10-02'),
    });

    const open = await anomalies.listQueue({});
    expect(open.map((f) => f.id)).toEqual(['f1']);

    const dismissed = await anomalies.listQueue({ status: 'dismissed' });
    expect(dismissed.map((f) => f.id)).toEqual(['f2']);
  });

  test('refuses a status that is not one', async () => {
    await expect(anomalies.listQueue({ status: 'pending' }))
      .rejects.toThrow(/dismissed, actioned/);
  });

  test('is bounded', async () => {
    const queue = await anomalies.listQueue({ limit: 5 });
    expect(queue.length).toBeLessThanOrEqual(5);
  });
});

// ---------------------------------------------------------------------------
// The comparison set
// ---------------------------------------------------------------------------

describe('the unit-mass comparison set', () => {
  test('is the gazette category across producers, not one catalogue', async () => {
    // A single producer's catalogue is not a distribution. The set crosses a
    // tenancy boundary deliberately, is read Admin-side, and only summary
    // statistics of it reach a finding.
    fs._seed('producerSkus', 'sku_mine', {
      orgId: ORG, gazetteCategory: 'rigid', massStatus: 'verified',
      verifiedUnitMassMg: 200000,
    });
    for (let i = 0; i < 10; i += 1) {
      fs._seed('producerSkus', `sku_peer_${i}`, {
        orgId: 'org_pran', gazetteCategory: 'rigid', massStatus: 'verified',
        verifiedUnitMassMg: 10000 + i * 500,
      });
    }

    const out = await anomalies.readCategoryUnitMasses({ orgId: ORG, skuIds: ['sku_mine'] });
    const comparison = out.get('sku_mine');

    expect(comparison.unitMassMg).toBe(200000);
    expect(comparison.peers.length).toBeGreaterThanOrEqual(10);
  });

  test('excludes a SKU from its own comparison set', async () => {
    // A product cannot be an outlier from a distribution it is helping to
    // define, and in a small category it would pull the fence toward itself.
    fs._seed('producerSkus', 'sku_mine', {
      orgId: ORG, gazetteCategory: 'rigid', massStatus: 'verified',
      verifiedUnitMassMg: 10000,
    });
    for (let i = 0; i < 5; i += 1) {
      fs._seed('producerSkus', `sku_peer_${i}`, {
        orgId: 'org_pran', gazetteCategory: 'rigid', massStatus: 'verified',
        verifiedUnitMassMg: 10000,
      });
    }

    const comparison = (
      await anomalies.readCategoryUnitMasses({ orgId: ORG, skuIds: ['sku_mine'] })
    ).get('sku_mine');

    // One occurrence removed, not every equal value — another producer's
    // product of the same mass is a legitimate peer.
    expect(comparison.peers).toHaveLength(5);
  });

  test('says nothing about another organisation’s SKU', async () => {
    fs._seed('producerSkus', 'sku_theirs', {
      orgId: 'org_pran', gazetteCategory: 'rigid', massStatus: 'verified',
      verifiedUnitMassMg: 10000,
    });

    const out = await anomalies.readCategoryUnitMasses({
      orgId: ORG, skuIds: ['sku_theirs'],
    });
    expect(out.has('sku_theirs')).toBe(false);
  });
});

describe('the trailing baseline', () => {
  test('counts a period with no collection as a zero, not as absent', async () => {
    // It genuinely is part of the trailing average. Dropping it would make a
    // sporadic product look steady and then flag its next appearance.
    seedAttributions([
      attribution('p8', { periodId: '2026-08', massMg: 10 * MG }),
    ]);

    const trailing = await anomalies.readTrailing({
      orgId: ORG, periodId: PERIOD, skuIds: ['sku_cola'],
    });

    expect(trailing.get('sku_cola').massMg).toHaveLength(anomalies.TRAILING_PERIODS);
    expect(trailing.get('sku_cola').massMg.filter((mg) => mg === 0).length)
      .toBe(anomalies.TRAILING_PERIODS - 1);
  });

  test('contributes nothing to the confidence history for an empty period', async () => {
    // A period with no matches has no mix to average, and a zero there would
    // read as perfect recognition.
    seedAttributions([
      attribution('p8', { periodId: '2026-08', confidenceTier: 'medium' }),
    ]);

    const trailing = await anomalies.readTrailing({
      orgId: ORG, periodId: PERIOD, skuIds: ['sku_cola'],
    });

    expect(trailing.get('sku_cola').mediumShare).toEqual([1]);
  });
});
