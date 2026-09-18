/**
 * Report jobs (EPR-33, EPR-34, EPR-35, SEC-6).
 *
 * The requirement most likely to rot silently is EPR-34's: "Two reports of the
 * same scope and period must be byte-identical apart from the generation
 * timestamp and requester — determinism is what lets an auditor compare their
 * copy to the producer's." Nothing about a non-deterministic report looks wrong
 * until two people compare copies, so most of this file is about that.
 */

jest.mock('../src/firebase', () => {
  const saved = new Map();
  return {
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
    bucket: jest.fn(() => ({
      // The preflight asks whether the bucket is THERE, not just whether its
      // name is configured — a project where Cloud Storage was never
      // provisioned has the name and no bucket. Overridden per test where the
      // absent case is the subject.
      exists: async () => [true],
      file: (path) => ({
        save: async (buffer) => saved.set(path, buffer),
        getSignedUrl: async () => [`https://signed.example/${path}?sig=abc`],
      }),
    })),
    __saved: saved,
  };
});

jest.mock('../src/eprPolicy', () => ({ readPolicy: jest.fn() }));

const firebase = require('../src/firebase');
const eprPolicy = require('../src/eprPolicy');
const reportJobs = require('../src/reportJobs');
const audit = require('../src/producerAudit');
const { fakeFirestore } = require('./helpers/firestoreFake');

let fs;

const ORG = 'org_cola';
const PERIOD = '2026-09';

beforeEach(() => {
  jest.clearAllMocks();
  firebase.__saved.clear();
  fs = fakeFirestore();
  firebase.db.mockReturnValue(fs);
  process.env.FIREBASE_STORAGE_BUCKET = 'chokro-test.appspot.com';

  eprPolicy.readPolicy.mockResolvedValue({
    kAnonymityFloor: 5,
    carbonUncertaintyCeiling: 0.25,
    massToleranceFraction: 0.1,
  });

  fs._seed('organizations', ORG, {
    legalName: 'Coca-Cola Bangladesh Beverages Ltd.',
    tradeName: 'Coca-Cola Bangladesh',
    doeRegistrationNo: 'DoE/EPR/2026/0417',
    sizeClass: 'large',
    status: 'active',
    complianceRoute: 'self',
    obligationStartDate: { toDate: () => new Date('2026-07-01T00:00:00Z') },
  });

  fs._seed('eprPeriods', `${ORG}_${PERIOD}`, {
    orgId: ORG,
    periodId: PERIOD,
    massMgByCategory: { rigid: 4120000000, flexible: 880000000 },
    unitsByCategory: { rigid: 168000, flexible: 44000 },
    massMgByPolymer: { pet: 4020000000, multilayer: 880000000 },
    massMgByDistrict: { Dhaka: 3000000000, Chattogram: 2000000000 },
    attributionCount: 3,
    disposalCount: 3,
    uncertainMassMg: 400000000,
    reversedCount: 0,
    skuIds: ['sku_a', 'sku_b'],
  });

  fs._seed('putOnMarketDeclarations', `${ORG}_${PERIOD}`, {
    orgId: ORG,
    periodId: PERIOD,
    status: 'submitted',
    version: 1,
    attestedByName: 'Nasrin Akhter',
    totalMassMg: 18000000000,
    lines: [{ category: 'rigid', units: 720000, massMg: 18000000000 }],
  });

  // Three attributions, deliberately seeded out of id order so an unordered
  // read would surface them differently from run to run.
  for (const [id, over] of [
    ['attr_c', { skuId: 'sku_b', units: 1, massMg: 880000000 }],
    ['attr_a', { skuId: 'sku_a', units: 2, massMg: 2120000000 }],
    ['attr_b', { skuId: 'sku_a', units: 2, massMg: 2000000000 }],
  ]) {
    fs._seed('attributions', id, {
      orgId: ORG,
      periodId: PERIOD,
      disposalId: `disposal_${id}`,
      skuId: 'sku_a',
      skuRevision: 1,
      units: 2,
      unitMassMgUsed: 9800,
      massMg: 19600,
      method: 'aiSku',
      confidenceTier: 'high',
      binId: 'bin_open',
      district: 'Dhaka',
      gazetteCategory: 'rigid',
      createdAt: { toDate: () => new Date('2026-09-14T09:00:00Z') },
      ...over,
    });
  }

  fs._seed('producerSkus', 'sku_a', {
    orgId: ORG,
    name: 'Coca-Cola 250 ml PET bottle',
    brand: 'Coca-Cola',
    gazetteCategory: 'rigid',
    massStatus: 'verified',
  });
  fs._seed('producerSkus', 'sku_b', {
    orgId: ORG,
    name: 'Sprite 500 ml PET bottle',
    brand: 'Sprite',
    gazetteCategory: 'rigid',
    massStatus: 'verified',
  });
});

const enqueue = (over = {}) =>
  reportJobs.enqueue({
    orgId: ORG,
    reportType: 'periodCollectionStatement',
    periodId: PERIOD,
    format: 'json',
    actorUid: 'uid_owner',
    actorName: 'Nasrin Akhter',
    actorRole: 'orgOwner',
    ...over,
  });

async function run(over = {}) {
  const { jobId } = await enqueue(over);
  await reportJobs.runJob(jobId);
  const job = fs._store.get(`reportJobs/${jobId}`);
  const artefact = [...firebase.__saved.values()].pop()?.toString('utf8') ?? '';
  return { jobId, job, artefact };
}

// ---------------------------------------------------------------------------
// Determinism (EPR-34)
// ---------------------------------------------------------------------------

describe('determinism', () => {
  test('two runs of the same scope produce the same content hash', async () => {
    // The requirement, directly. An auditor comparing their copy to the
    // producer's has nothing to compare if the hash moves between runs.
    const first = await run();
    const second = await run();

    expect(first.job.contentHash).toBe(second.job.contentHash);
    expect(first.job.contentHash).toMatch(/^[0-9a-f]{64}$/);
  });

  test('the hash covers the body and not the generation header', async () => {
    const { job, artefact } = await run();
    const parsed = JSON.parse(artefact);

    const crypto = require('crypto');
    const recomputed = crypto
      .createHash('sha256')
      .update(JSON.stringify(parsed.data, null, 2), 'utf8')
      .digest('hex');

    // Recomputable by a third party from the data member alone. An earlier
    // version hashed a fragment that was not valid JSON on its own, so two
    // copies still compared equal but nobody could verify the hash.
    expect(recomputed).toBe(job.contentHash);
    expect(job.contentHash).toBe(parsed._header.contentHash);
  });

  test('a different requester does not change the hash', async () => {
    const mine = await run({ actorUid: 'uid_a', actorName: 'A' });
    const theirs = await run({ actorUid: 'uid_b', actorName: 'B' });

    expect(mine.job.contentHash).toBe(theirs.job.contentHash);
  });

  test('a row-level export is ordered, not left to Firestore', async () => {
    // Attributions were seeded out of id order. Two runs must emit them in the
    // same sequence — an unordered read has no guaranteed order at all.
    const first = await run({ reportType: 'chainOfCustody' });
    const second = await run({ reportType: 'chainOfCustody' });

    expect(first.job.contentHash).toBe(second.job.contentHash);

    const rows = JSON.parse(first.artefact).data.rows;
    expect(rows.map((r) => r.attributionId)).toEqual(['attr_a', 'attr_b', 'attr_c']);
  });

  test('a SKU report sorts by id, so a mass tie cannot reorder it', async () => {
    const first = await run({ reportType: 'skuPerformance' });
    const second = await run({ reportType: 'skuPerformance' });

    expect(first.job.contentHash).toBe(second.job.contentHash);
    const rows = JSON.parse(first.artefact).data.rows;
    expect(rows.map((r) => r.skuId)).toEqual([...rows.map((r) => r.skuId)].sort());
  });

  test('a different period produces a different hash', async () => {
    const september = await run();
    const august = await run({ periodId: '2026-08' });
    expect(september.job.contentHash).not.toBe(august.job.contentHash);
  });
});

// ---------------------------------------------------------------------------
// The header and the boundaries (EPR-34)
// ---------------------------------------------------------------------------

describe('every report’s header', () => {
  test('names the system, the period, the requester and the hash', async () => {
    const { artefact } = await run();
    const header = JSON.parse(artefact)._header;

    expect(header.system).toBe(reportJobs.GENERATOR);
    expect(header.version).toBe(reportJobs.GENERATOR_VERSION);
    expect(header.period).toBe(PERIOD);
    expect(header.timezone).toMatch(/Dhaka/);
    expect(header.requestedBy).toBe('Nasrin Akhter');
    expect(header.generatedAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(header.contentHash).toMatch(/^[0-9a-f]{64}$/);
  });

  test('carries the boundary statements on the artefact', async () => {
    // EPR-34. A spreadsheet gets forwarded further than a certificate and
    // arrives without the context a certificate's layout provides.
    const { artefact } = await run();
    const boundaries = JSON.parse(artefact)._header.boundaries;

    expect(boundaries.length).toBeGreaterThanOrEqual(5);
    expect(boundaries.join(' ')).toMatch(/not a statement of compliance/i);
    expect(boundaries.join(' ')).toMatch(/does not state a recycling rate/i);
    expect(boundaries.join(' ')).toMatch(/not verified carbon credits/i);
  });

  test('reaches a CSV report too, as comment lines', async () => {
    const { artefact } = await run({ format: 'csv' });

    expect(artefact.startsWith('# system: ')).toBe(true);
    expect(artefact).toMatch(/#\s+- Collection figures count only/);
    // And the column row is still there, after the header.
    expect(artefact).toMatch(/\ncategory,collectedMassMg,/);
  });
});

// ---------------------------------------------------------------------------
// What the reports say
// ---------------------------------------------------------------------------

describe('the period collection statement', () => {
  test('states an undeclared category as such, not as zero', async () => {
    // EPR-42, at the one place it is most likely to be lost: a spreadsheet
    // cell containing 0 is read as a declared nil by everyone who opens it.
    const { artefact } = await run();
    const rows = JSON.parse(artefact).data.rows;

    const flexible = rows.find((r) => r.category === 'flexible');
    expect(flexible.declaredMassMg).toBe('notDeclared');
    expect(flexible.collectionRate).toBe('notStated');
  });

  test('states a rate where a declaration covers the category', async () => {
    const { artefact } = await run();
    const rigid = JSON.parse(artefact).data.rows.find((r) => r.category === 'rigid');

    expect(rigid.declaredMassMg).toBe(18000000000);
    expect(Number(rigid.collectionRate)).toBeCloseTo(4120000000 / 18000000000, 6);
  });

  test('has no overall rate when nothing was declared', async () => {
    fs._store.delete(`putOnMarketDeclarations/${ORG}_${PERIOD}`);
    const { artefact } = await run();

    // Null, never zero (EPR-24).
    expect(JSON.parse(artefact).data.totals.collectionRate).toBeNull();
    expect(JSON.parse(artefact).data.totals.declaredMassMg).toBeNull();
  });
});

describe('reversed attributions', () => {
  // ===================================================================
  // THE BUG THIS EXISTS FOR
  // ===================================================================
  //
  // These builders tested `row.reversed === true`, and nothing in the system
  // writes a boolean `reversed` field: `attribute.js` initialises
  // `reversedAt: null` and `eprPeriods.reverseAttribution` sets it. So the
  // guard never fired.
  //
  // The consequence is the worst kind for an auditor-facing artefact. The
  // period rollup and the certificate correctly exclude reversed mass; these
  // reports did not. An auditor summing the chain-of-custody export got a
  // figure ABOVE the passport's, and the `reversed` column that would have
  // explained the difference read `false` on every row.
  beforeEach(() => {
    fs._seed('attributions', 'attr_b', {
      ...fs._store.get('attributions/attr_b'),
      reversedAt: { toDate: () => new Date('2026-09-20T09:00:00Z') },
      reversedBy: 'uid_admin',
      reversedReason: 'The match was wrong on review.',
    });
  });

  test('are excluded from the SKU performance report', async () => {
    const { artefact } = await run({ reportType: 'skuPerformance' });
    const rows = JSON.parse(artefact).data.rows;
    const skuA = rows.find((r) => r.skuId === 'sku_a');

    // attr_a (2 units) survives; attr_b (2 units) is reversed. Counting the
    // reversed row would report 4.
    expect(skuA.units).toBe(2);
    expect(skuA.highConfidence).toBe(1);
  });

  test('are marked as reversed in the chain-of-custody export', async () => {
    const { artefact } = await run({ reportType: 'chainOfCustody' });
    const rows = JSON.parse(artefact).data.rows;

    // Present, because EPR-21 reverses rather than deletes and an auditor has
    // to be able to see the reversal — but marked, so the sum reconciles.
    expect(rows.find((r) => r.attributionId === 'attr_b').reversed).toBe(true);
    expect(rows.find((r) => r.attributionId === 'attr_a').reversed).toBe(false);
  });

  test('the predicate keys on reversedAt and not on a boolean', () => {
    // Asserted directly, because the field that does not exist is exactly what
    // a future reader will reach for again.
    expect(reportJobs.isReversed({ reversedAt: new Date() })).toBe(true);
    expect(reportJobs.isReversed({ reversed: true })).toBe(false);
    expect(reportJobs.isReversed({ reversedAt: null })).toBe(false);
    expect(reportJobs.isReversed({})).toBe(false);
    expect(reportJobs.isReversed(null)).toBe(false);
  });
});

describe('the chain-of-custody export', () => {
  test('carries no personal identifier and no raw disposal id', async () => {
    // EPR-33 requires "no personal identifiers", and SEC-3 is why: the raw
    // disposal id would let two producers who each received a fragment of the
    // same bag correlate their exports and reconstruct a Champion's activity.
    const { artefact } = await run({ reportType: 'chainOfCustody' });

    expect(artefact).not.toMatch(/disposal_attr_/);
    expect(artefact).not.toMatch(/uid_/);

    const rows = JSON.parse(artefact).data.rows;
    for (const row of rows) {
      expect(row.disposalRef).toMatch(/^[0-9a-f]{24}$/);
      expect(row.disposalId).toBeUndefined();
    }
  });

  test('pseudonymises per organisation, so two exports cannot be joined', async () => {
    const mine = reportJobs.pseudonym('org_cola', 'disposal_1');
    const theirs = reportJobs.pseudonym('org_pran', 'disposal_1');

    expect(mine).not.toBe(theirs);
    // Stable within an organisation, so an auditor can still follow one
    // disposal across rows of this producer's export.
    expect(reportJobs.pseudonym('org_cola', 'disposal_1')).toBe(mine);
  });

  test('reports a date and not a timestamp', async () => {
    // A second-precision time plus a bin location identifies the person who
    // was standing there (SEC-3).
    const { artefact } = await run({ reportType: 'chainOfCustody' });
    for (const row of JSON.parse(artefact).data.rows) {
      expect(row.date).toMatch(/^\d{4}-\d{2}-\d{2}$/);
      expect(row.date).not.toMatch(/T|:/);
    }
  });
});

describe('the geographic recovery report', () => {
  test('applies the k-anonymity floor rather than routing around it', async () => {
    // SEC-3. A report that bypassed the projection would be the export route
    // around the control that the screen respects.
    fs._seed('eprPeriods', `${ORG}_2026-08`, {
      orgId: ORG,
      periodId: '2026-08',
      massMgByCategory: { rigid: 100 },
      massMgByDistrict: { Dhaka: 100 },
      attributionCount: 1,
      // Below the k floor of 5: too few disposals to name a district without
      // identifying the individual ones.
      disposalCount: 1,
      skuIds: ['sku_a'],
    });

    const { artefact } = await run({
      reportType: 'geographicRecovery',
      periodId: '2026-08',
    });
    const data = JSON.parse(artefact).data;

    expect(data.districtsSuppressed).toBe(true);
    expect(data.rows).toEqual([]);
    expect(data.note).toMatch(/withheld/i);
  });
});

describe('the surplus mass statement', () => {
  test('calls it surplus and never a credit', async () => {
    // §15 decision 7: "report surplus mass, call it surplus, do not call it
    // credits until the framework is understood".
    const { artefact } = await run({ reportType: 'surplusMass' });
    const data = JSON.parse(artefact).data;

    expect(data).toHaveProperty('surplusMassMg');
    expect(data).not.toHaveProperty('credits');
    expect(data.eligibilityCaveats.join(' ')).toMatch(/not a plastic credit/i);
    expect(data.eligibilityCaveats.join(' ')).toMatch(/not established/i);
  });

  test('has no surplus figure at all without a declaration', async () => {
    fs._store.delete(`putOnMarketDeclarations/${ORG}_${PERIOD}`);
    const { artefact } = await run({ reportType: 'surplusMass' });
    const data = JSON.parse(artefact).data;

    // Null, not zero. A zero would read as "no surplus", which is a different
    // claim from "no basis on which to compute one".
    expect(data.surplusMassMg).toBeNull();
    expect(data.surplusAbsenceReason).toMatch(/no denominator|no put-on-market/i);
  });

  test('has no surplus figure without an obligation year', async () => {
    fs._seed('organizations', ORG, {
      ...fs._store.get(`organizations/${ORG}`),
      obligationStartDate: null,
    });
    const { artefact } = await run({ reportType: 'surplusMass' });
    const data = JSON.parse(artefact).data;

    expect(data.applicableCollectionTarget).toBeNull();
    expect(data.surplusMassMg).toBeNull();
    expect(data.surplusAbsenceReason).toMatch(/no obligation start date/i);
  });
});

describe('the DoE annual progress report', () => {
  test('runs on the producer’s registration clock, not the calendar year', async () => {
    // EPR-33: "annual, on the producer's registration clock". An obligation
    // beginning 1 July 2026 has a first year of July 2026 to June 2027.
    const periods = reportJobs.twelvePeriodsFrom(
      { obligationStartDate: { toDate: () => new Date('2026-07-01T00:00:00Z') } },
      1,
    );

    expect(periods).toHaveLength(12);
    expect(periods[0]).toBe('2026-07');
    expect(periods[11]).toBe('2027-06');
  });

  test('the second obligation year starts at the anniversary', () => {
    const periods = reportJobs.twelvePeriodsFrom(
      { obligationStartDate: { toDate: () => new Date('2026-07-01T00:00:00Z') } },
      2,
    );
    expect(periods[0]).toBe('2027-07');
  });

  test('states the recycling gap rather than a recycling rate', async () => {
    const { artefact } = await run({
      reportType: 'doeAnnualProgress',
      periodId: null,
      year: 1,
    });
    const data = JSON.parse(artefact).data;

    // §6.6: Chokro records collection and holds no recycling evidence at all.
    // The gap is a statement, not a figure.
    expect(data.recyclingGapStatement).toMatch(/no recycling rate is stated/i);
    expect(data).not.toHaveProperty('recyclingRate');
    expect(data.methodology.knownLimits.join(' ')).toMatch(/cannot prove/i);
  });

  test('includes the passport register', async () => {
    fs._seed('plasticPassports', 'CHKR-PP-9F2K-7T4D', {
      serial: 'CHKR-PP-9F2K-7T4D',
      orgId: ORG,
      periodId: PERIOD,
      status: 'issued',
      contentHash: 'a'.repeat(64),
      issuedAt: { toDate: () => new Date('2026-10-03T05:12:00Z') },
    });

    const { artefact } = await run({
      reportType: 'doeAnnualProgress',
      periodId: null,
      year: 1,
    });
    const register = JSON.parse(artefact).data.passportRegister;

    expect(register).toHaveLength(1);
    expect(register[0].serial).toBe('CHKR-PP-9F2K-7T4D');
  });
});

// ---------------------------------------------------------------------------
// CSV safety
// ---------------------------------------------------------------------------

describe('CSV cells', () => {
  test('neutralise formula injection', () => {
    // These exports carry producer-supplied product names and brands, and
    // `=HYPERLINK(...)` in a brand name executes when an auditor opens the
    // file in Excel or Sheets.
    for (const payload of ['=1+1', '+cmd', '-cmd', '@SUM(A1)', '\tx', '\rx']) {
      expect(reportJobs.csvCell(payload)).toMatch(/^"'/);
    }
  });

  test('leave an ordinary value alone but still quote it', () => {
    expect(reportJobs.csvCell('Coca-Cola')).toBe('"Coca-Cola"');
    expect(reportJobs.csvCell(0)).toBe('"0"');
    expect(reportJobs.csvCell(false)).toBe('"false"');
  });

  test('escape an embedded quote and survive a comma', () => {
    expect(reportJobs.csvCell('say "hi"')).toBe('"say ""hi"""');
    expect(reportJobs.csvCell('Dhaka, Bangladesh')).toBe('"Dhaka, Bangladesh"');
  });

  test('render null and undefined as empty, not as the word', () => {
    expect(reportJobs.csvCell(null)).toBe('');
    expect(reportJobs.csvCell(undefined)).toBe('');
  });
});

// ---------------------------------------------------------------------------
// Jobs and delivery (EPR-35, SEC-6)
// ---------------------------------------------------------------------------

describe('the job lifecycle', () => {
  test('enqueues queued and finishes ready', async () => {
    const { jobId } = await enqueue();
    expect(fs._store.get(`reportJobs/${jobId}`).status).toBe('queued');

    await reportJobs.runJob(jobId);
    const job = fs._store.get(`reportJobs/${jobId}`);
    expect(job.status).toBe('ready');
    expect(job.storagePath).toMatch(/^epr-reports\/org_cola\//);
    expect(job.byteSize).toBeGreaterThan(0);
  });

  test('is idempotent: a re-run does not produce a second artefact', async () => {
    // A retry, a double-fire, or a resume of something that finished. An
    // auditor holding two files for one job id has no way to know which is the
    // report.
    const { jobId } = await enqueue();
    await reportJobs.runJob(jobId);
    const first = { ...fs._store.get(`reportJobs/${jobId}`) };
    firebase.__saved.clear();

    await reportJobs.runJob(jobId);

    expect(firebase.__saved.size).toBe(0);
    expect(fs._store.get(`reportJobs/${jobId}`).contentHash).toBe(first.contentHash);
  });

  test('records a failure on the job rather than throwing', async () => {
    // The route fires `runJob` without awaiting it, so a rejection here would
    // be an unhandled promise rejection that takes the instance down — turning
    // one producer's report fault into an outage for every tenant.
    const { jobId } = await enqueue({ reportType: 'doeAnnualProgress', periodId: null, year: 1 });
    fs._store.delete(`organizations/${ORG}`);

    await expect(reportJobs.runJob(jobId)).resolves.toBeUndefined();

    const job = fs._store.get(`reportJobs/${jobId}`);
    expect(job.status).toBe('failed');
    expect(job.error).toMatch(/does not exist/i);
  });

  test('reports a long-running job as stalled', async () => {
    // There is no scheduler to notice (§3.3), so this is evaluated at read
    // time. A job left `running` forever is a progress bar that never
    // finishes, which is worse than a failure the producer can retry.
    const { jobId } = await enqueue();
    fs._store.set(`reportJobs/${jobId}`, {
      ...fs._store.get(`reportJobs/${jobId}`),
      status: 'running',
      startedAt: { toDate: () => new Date(Date.now() - 60 * 60 * 1000) },
    });

    const job = await reportJobs.getJob({ jobId, orgId: ORG });
    expect(job.status).toBe('stalled');
    // Reported, not rewritten: the job may still be alive on another instance,
    // and flipping the stored status could race a legitimate completion.
    expect(fs._store.get(`reportJobs/${jobId}`).status).toBe('running');
  });

  test('refuses another organisation’s job as not found', async () => {
    // SEC-1, and returned as a null rather than a distinguishable error so a
    // caller cannot probe for job ids.
    const { jobId } = await enqueue();
    await expect(
      reportJobs.getJob({ jobId, orgId: 'org_pran' }),
    ).resolves.toBeNull();
  });

  test('refuses a report type it does not produce', async () => {
    await expect(enqueue({ reportType: 'plasticCredits' }))
      .rejects.toThrow(/not a report/i);
  });

  test('refuses a format the report is not produced in', async () => {
    await expect(
      enqueue({ reportType: 'surplusMass', format: 'csv' }),
    ).rejects.toThrow(/not produced as csv/i);
  });

  test('refuses a period-scoped report with no period', async () => {
    await expect(enqueue({ periodId: null })).rejects.toThrow(/needs a reporting period/i);
    await expect(enqueue({ periodId: '2026-9' })).rejects.toThrow(/needs a reporting period/i);
  });

  test('records the request in the audit chain', async () => {
    await enqueue();
    expect(
      fs._find(audit.COLLECTION).some(
        (e) => e.action === audit.ACTIONS.REPORT_GENERATED,
      ),
    ).toBe(true);
  });
});

describe('delivery (SEC-6)', () => {
  test('hands back a short-lived signed URL, never a permanent path', async () => {
    const { jobId } = await run();

    const result = await reportJobs.signedUrlFor({
      jobId,
      orgId: ORG,
      actorUid: 'uid_owner',
      actorRole: 'orgOwner',
    });

    expect(result.url).toMatch(/^https:\/\//);
    expect(result.expiresInSeconds).toBeLessThanOrEqual(15 * 60);
    expect(result.contentHash).toMatch(/^[0-9a-f]{64}$/);
  });

  test('logs every download with actor, org and artefact', async () => {
    const { jobId } = await run();
    await reportJobs.signedUrlFor({
      jobId,
      orgId: ORG,
      actorUid: 'uid_owner',
      actorName: 'Nasrin Akhter',
      actorRole: 'orgOwner',
    });

    const entry = fs._find(audit.COLLECTION).find(
      (e) => e.action === audit.ACTIONS.REPORT_DOWNLOADED,
    );
    expect(entry).toBeTruthy();
    expect(entry.orgId).toBe(ORG);
    expect(entry.actorUid).toBe('uid_owner');
    expect(entry.targetId).toBe(jobId);
  });

  test('re-checks the report’s minimum role at delivery, not only at enqueue', async () => {
    // SEC-11's "org member exfiltrates data" row, reached by the one route that
    // hands over the actual bytes. `listJobs` returns every job for the
    // organisation, so a viewer can see the row-level export an owner
    // requested yesterday — and an authorisation enforced only at the point of
    // request is not enforced.
    const { jobId } = await run({ reportType: 'chainOfCustody' });

    await expect(
      reportJobs.signedUrlFor({
        jobId,
        orgId: ORG,
        actorUid: 'uid_viewer',
        actorRole: 'orgViewer',
      }),
    ).rejects.toThrow(/only be downloaded by an owner/i);

    // The owner who asked for it still can.
    await expect(
      reportJobs.signedUrlFor({
        jobId, orgId: ORG, actorUid: 'uid_owner', actorRole: 'orgOwner',
      }),
    ).resolves.toHaveProperty('url');
  });

  test('lets a viewer download a viewer-level report', async () => {
    const { jobId } = await run();
    await expect(
      reportJobs.signedUrlFor({
        jobId, orgId: ORG, actorUid: 'uid_viewer', actorRole: 'orgViewer',
      }),
    ).resolves.toHaveProperty('url');
  });

  test('refuses to sign for a job that is not ready', async () => {
    const { jobId } = await enqueue();
    await expect(
      reportJobs.signedUrlFor({ jobId, orgId: ORG, actorUid: 'u', actorRole: 'orgOwner' }),
    ).rejects.toThrow(/not ready/i);
  });

  test('refuses to sign for another organisation’s job', async () => {
    const { jobId } = await run();
    await expect(
      reportJobs.signedUrlFor({
        jobId,
        orgId: 'org_pran',
        actorUid: 'uid_pran',
        actorRole: 'orgOwner',
      }),
    ).rejects.toThrow(/does not exist/i);
  });

  test('refuses at enqueue time when there is no bucket', async () => {
    // A signed URL is the only delivery EPR-35 permits. Without a bucket the
    // alternative is streaming the report in the response, which is the thing
    // EPR-35 exists to prevent — so this fails loudly and names the variable.
    delete process.env.FIREBASE_STORAGE_BUCKET;

    await expect(enqueue()).rejects.toThrow(/FIREBASE_STORAGE_BUCKET/);
    // And nothing was written, so there is no job to poll forever.
    expect(fs._find('reportJobs')).toHaveLength(0);
  });

  test('refuses when the variable is set but the BUCKET does not exist', async () => {
    // The state this project was actually in. `FIREBASE_STORAGE_BUCKET` held a
    // perfectly good name and Cloud Storage had never been provisioned, so the
    // old preflight passed and the failure arrived later as an opaque GCS
    // error from inside a running job — with no mention of the remedy.
    process.env.FIREBASE_STORAGE_BUCKET = 'chokro-30887.firebasestorage.app';
    reportJobs.resetStorageCheck();
    firebase.bucket.mockReturnValueOnce({ exists: async () => [false] });

    await expect(enqueue()).rejects.toThrow(/has not been set up/);
    expect(fs._find('reportJobs')).toHaveLength(0);
  });

  test('the refusal names the remedy, not just the symptom', async () => {
    process.env.FIREBASE_STORAGE_BUCKET = 'chokro-30887.firebasestorage.app';
    reportJobs.resetStorageCheck();
    firebase.bucket.mockReturnValueOnce({ exists: async () => [false] });

    // An operator reading this has to know what to do. "Bucket not found" does
    // not tell them that Storage needs billing enabled first.
    await expect(enqueue()).rejects.toThrow(/Blaze/);
    // And that the rest of the product is fine, so nobody treats it as an
    // outage.
    await expect(
      (async () => {
        reportJobs.resetStorageCheck();
        firebase.bucket.mockReturnValueOnce({ exists: async () => [false] });
        return enqueue();
      })(),
    ).rejects.toThrow(/Plastic Passports/);
  });

  test('an unreachable bucket is an outage, not a misconfiguration', async () => {
    process.env.FIREBASE_STORAGE_BUCKET = 'chokro-30887.firebasestorage.app';
    reportJobs.resetStorageCheck();
    firebase.bucket.mockReturnValueOnce({
      exists: async () => { throw new Error('ECONNRESET'); },
    });

    // A network failure must not be reported to a producer as "your Chokro
    // instance is misconfigured" — the remedy is to try again, not to call an
    // operator.
    await expect(enqueue()).rejects.toThrow(/could not be reached/);
  });
});

describe('the report catalogue', () => {
  test('scopes row-level and annual reports to an owner', () => {
    // SEC-11's "org member exfiltrates data" row. A viewer can read the
    // dashboard; the row-level export is a deliberate act.
    expect(reportJobs.REPORT_TYPES.chainOfCustody.minRole).toBe('orgOwner');
    expect(reportJobs.REPORT_TYPES.doeAnnualProgress.minRole).toBe('orgOwner');
    expect(reportJobs.REPORT_TYPES.surplusMass.minRole).toBe('orgOwner');
    expect(reportJobs.REPORT_TYPES.periodCollectionStatement.minRole).toBe('orgViewer');
  });

  test('names no report Chokro cannot produce', () => {
    // Listing a type with no builder would let a client enqueue a job that
    // fails after the producer has been told it was accepted.
    for (const key of Object.keys(reportJobs.REPORT_TYPES)) {
      expect(() =>
        reportJobs.buildReport({
          reportType: key, orgId: ORG, periodId: PERIOD, year: 1,
          format: reportJobs.REPORT_TYPES[key].formats[0],
          label: reportJobs.REPORT_TYPES[key].label,
        }),
      ).not.toThrow();
    }
  });
});

// ---------------------------------------------------------------------------
// The audit pack (EPR-33)
// ---------------------------------------------------------------------------

describe('the audit pack', () => {
  const { execFileSync } = require('child_process');
  const nodeFs = require('fs');
  const os = require('os');
  const nodePath = require('path');

  async function buildPack() {
    const { jobId } = await enqueue({ reportType: 'auditPack', format: 'zip' });
    await reportJobs.runJob(jobId);
    return {
      job: fs._store.get(`reportJobs/${jobId}`),
      bytes: [...firebase.__saved.values()].pop(),
    };
  }

  test('is a real ZIP the system unzip accepts', async () => {
    // A compliance artefact a regulator cannot open is a bad failure, and the
    // writer is hand-rolled — so this extracts with the real binary rather
    // than asserting anything about bytes.
    const { bytes } = await buildPack();

    const dir = nodeFs.mkdtempSync(nodePath.join(os.tmpdir(), 'chokro-pack-'));
    const file = nodePath.join(dir, 'pack.zip');
    nodeFs.writeFileSync(file, bytes);

    try {
      expect(execFileSync('unzip', ['-t', file], { encoding: 'utf8' }))
        .toMatch(/No errors detected/);
    } finally {
      nodeFs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('carries every document EPR-33 names', async () => {
    const { bytes } = await buildPack();

    const dir = nodeFs.mkdtempSync(nodePath.join(os.tmpdir(), 'chokro-pack-'));
    const file = nodePath.join(dir, 'pack.zip');
    nodeFs.writeFileSync(file, bytes);

    try {
      const listed = execFileSync('unzip', ['-Z1', file], { encoding: 'utf8' })
        .trim().split('\n');

      // "The above plus mass-audit records, SKU revision history,
      // accuracy-audit results, recompute reconciliation, passport register".
      for (const name of [
        'manifest.json',
        'period-collection-statement.json',
        'chain-of-custody.json',
        'reconciliation.json',
        'sku-revision-history.json',
        'mass-audit-records.json',
        'accuracy-audit.json',
        'passport-register.json',
        'methodology.json',
        'boundary-statements.txt',
      ]) {
        expect(listed).toContain(name);
      }
    } finally {
      nodeFs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('hashes every entry in its manifest', async () => {
    // A pack is the artefact most likely to be forwarded, split up and re-sent.
    // A recipient holding three of its files needs a way to confirm they are
    // the three Chokro produced.
    const { bytes } = await buildPack();

    const dir = nodeFs.mkdtempSync(nodePath.join(os.tmpdir(), 'chokro-pack-'));
    const file = nodePath.join(dir, 'pack.zip');
    nodeFs.writeFileSync(file, bytes);

    try {
      execFileSync('unzip', ['-q', file, '-d', nodePath.join(dir, 'out')]);
      const manifest = JSON.parse(
        nodeFs.readFileSync(nodePath.join(dir, 'out', 'manifest.json'), 'utf8'),
      );

      expect(manifest.files.length).toBeGreaterThanOrEqual(10);

      for (const entry of manifest.files) {
        const content = nodeFs.readFileSync(
          nodePath.join(dir, 'out', entry.name), 'utf8',
        );
        const digest = require('crypto')
          .createHash('sha256').update(content, 'utf8').digest('hex');
        expect(digest).toBe(entry.sha256);
        expect(Buffer.byteLength(content, 'utf8')).toBe(entry.bytes);
      }
    } finally {
      nodeFs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('the job’s content hash covers the manifest, which covers everything', async () => {
    const { job, bytes } = await buildPack();

    const dir = nodeFs.mkdtempSync(nodePath.join(os.tmpdir(), 'chokro-pack-'));
    const file = nodePath.join(dir, 'pack.zip');
    nodeFs.writeFileSync(file, bytes);

    try {
      execFileSync('unzip', ['-q', file, '-d', nodePath.join(dir, 'out')]);
      const manifestText = nodeFs.readFileSync(
        nodePath.join(dir, 'out', 'manifest.json'), 'utf8',
      );

      // Hashing the ZIP bytes directly would be equivalent today and would
      // break the moment anything about the container changed — a different
      // entry order, a different writer.
      expect(
        require('crypto').createHash('sha256').update(manifestText, 'utf8').digest('hex'),
      ).toBe(job.contentHash);
    } finally {
      nodeFs.rmSync(dir, { recursive: true, force: true });
    }
  });

  test('is stored as a ZIP, not wrapped in a text header', async () => {
    // Prepending the `# system:` header to an archive would corrupt it. The
    // header's content lives inside, in the manifest, where a recipient who
    // extracts one file can still find it.
    const { job, bytes } = await buildPack();

    expect(bytes.subarray(0, 4)).toEqual(Buffer.from([0x50, 0x4b, 0x03, 0x04]));
    expect(job.byteSize).toBe(bytes.length);
  });

  test('is owner-only', async () => {
    // The most complete export Chokro produces: row-level attributions, SKU
    // revision history, mass-audit records and the register in one file.
    // SEC-11's "org member exfiltrates data" row is about exactly this.
    expect(reportJobs.REPORT_TYPES.auditPack.minRole).toBe('orgOwner');

    const { jobId } = await enqueue({ reportType: 'auditPack', format: 'zip' });
    await reportJobs.runJob(jobId);

    await expect(
      reportJobs.signedUrlFor({
        jobId, orgId: ORG, actorUid: 'uid_viewer', actorRole: 'orgViewer',
      }),
    ).rejects.toThrow(/only be downloaded by an owner/i);
  });

  test('carries the boundary statements as their own file', async () => {
    // A pack gets split up. The statements have to survive being separated
    // from the reports they qualify.
    const { bytes } = await buildPack();

    const dir = nodeFs.mkdtempSync(nodePath.join(os.tmpdir(), 'chokro-pack-'));
    const file = nodePath.join(dir, 'pack.zip');
    nodeFs.writeFileSync(file, bytes);

    try {
      execFileSync('unzip', ['-q', file, '-d', nodePath.join(dir, 'out')]);
      const statements = nodeFs.readFileSync(
        nodePath.join(dir, 'out', 'boundary-statements.txt'), 'utf8',
      );
      expect(statements).toMatch(/does not state a recycling rate/i);
      expect(statements).toMatch(/not a statement of compliance/i);
    } finally {
      nodeFs.rmSync(dir, { recursive: true, force: true });
    }
  });
});

// ---------------------------------------------------------------------------
// Two findings recovered from the audit journals, fixed 2026-09-17
// ---------------------------------------------------------------------------

describe('a job as a client sees it (SEC-6)', () => {
  /**
   * `storagePath` — the object's path in the private bucket — was stripped on
   * the single-job poll route with `{ ...job, storagePath: undefined }` and
   * returned verbatim by `listJobs`. The list leaked exactly what the poll was
   * careful to hide, because a rule enforced in one route is a rule the next
   * route does not know about.
   */
  const raw = {
    jobId: 'job-1',
    orgId: 'org-1',
    reportType: 'chainOfCustody',
    status: 'ready',
    storagePath: 'reports/org-1/job-1.csv',
    contentHash: 'a'.repeat(64),
  };

  test('the bucket path never reaches a client', () => {
    const out = reportJobs.projectJob(raw);
    expect(out.storagePath).toBeUndefined();
    expect(JSON.stringify(out)).not.toContain('reports/org-1');
  });

  test('it is an allowlist, so a new field cannot leak by default', () => {
    // The property that matters more than the one field. A key added to the
    // job document later must not reach a client because nobody remembered.
    const out = reportJobs.projectJob({
      ...raw,
      internalCursor: 'page-42',
      signedUrlLastMinted: '2026-09-17T00:00:00Z',
    });
    expect(out.internalCursor).toBeUndefined();
    expect(out.signedUrlLastMinted).toBeUndefined();
  });

  test('what a client needs still arrives', () => {
    const out = reportJobs.projectJob(raw);
    expect(out.jobId).toBe('job-1');
    expect(out.status).toBe('ready');
    expect(out.reportType).toBe('chainOfCustody');
    expect(out.contentHash).toBe('a'.repeat(64));
  });

  test('a null job projects to null rather than an empty shell', () => {
    expect(reportJobs.projectJob(null)).toBeNull();
  });
});

describe('report row order does not depend on the runtime (NFR-E-8)', () => {
  /**
   * Every sort in this module sat under a comment promising output
   * "byte-identical across runs", and used `localeCompare` — which reads the
   * process locale and the ICU data compiled into Node.
   *
   * On real Bangladeshi district names that is not a subtle difference: the
   * default locale sorts Latin before Bengali and `bn` sorts Bengali before
   * Latin. A report carries a `contentHash`, so the order decides the hash,
   * and the same rows would hash differently on a deploy where nothing but
   * `LANG` had changed.
   */
  const DISTRICTS = ['ঢাকা', 'চট্টগ্রাম', 'খুলনা', 'Dhaka', 'Khulna', 'রাজশাহী'];

  test('it matches code-point order, not collation order', () => {
    const sorted = [...DISTRICTS].sort(reportJobs.byCodePoint);
    const expected = [...DISTRICTS].sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));
    expect(sorted).toEqual(expected);
  });

  test('it disagrees with a locale sort, which is the point', () => {
    // If these ever agreed, the test would be passing for the wrong reason and
    // the bug could return unnoticed.
    const byCode = [...DISTRICTS].sort(reportJobs.byCodePoint);
    const byBengali = [...DISTRICTS].sort((a, b) => a.localeCompare(b, 'bn'));
    expect(byCode).not.toEqual(byBengali);
  });

  test('it is stable and total', () => {
    expect(reportJobs.byCodePoint('a', 'b')).toBe(-1);
    expect(reportJobs.byCodePoint('b', 'a')).toBe(1);
    expect(reportJobs.byCodePoint('a', 'a')).toBe(0);
  });

  test('null and undefined sort as empty rather than throwing', () => {
    // A district key that is missing must not crash a report mid-build.
    expect(reportJobs.byCodePoint(null, 'a')).toBe(-1);
    expect(reportJobs.byCodePoint(undefined, '')).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// Third triage pass: four MEDIUM findings against this module
// ---------------------------------------------------------------------------

describe('a report says what it means (MEDIUM triage, 2026-09-17)', () => {
  test('a chain-of-custody row is dated by the disposal, not by the write', async () => {
    // `attribute.js` derives the period from `decidedAt` and stores it as
    // `disposalDecidedAt`; `createdAt` is merely when the document was
    // written. Across a period boundary they differ — a disposal decided at
    // 23:50 on the last of the month and attributed minutes later belongs to
    // the month that ended — and dating the row from `createdAt` put a date in
    // the export that falls OUTSIDE the period the export covers.
    // Chosen so the two fields give DIFFERENT Dhaka dates, which is the whole
    // point — 17:00Z is 23:00 on the 30th in Dhaka, 02:10Z is 08:10 on the
    // 1st. A fixture where both land on the same day cannot tell the two
    // readings apart and passes whichever field the code uses.
    fs._seed('attributions', 'attr_a', {
      ...fs._store.get('attributions/attr_a'),
      disposalDecidedAt: { toDate: () => new Date('2026-09-30T17:00:00Z') },
      createdAt: { toDate: () => new Date('2026-10-01T02:10:00Z') },
    });

    const { artefact } = await run({ reportType: 'chainOfCustody' });
    const rows = JSON.parse(artefact).data.rows;
    const row = rows.find((r) => r.attributionId === 'attr_a');

    // September, which is the period this report covers.
    expect(row.date).toBe('2026-09-30');
    // Not the October write date, which would fall outside it.
    expect(row.date).not.toBe('2026-10-01');
  });

  test('a row with no disposalDecidedAt still carries a date', async () => {
    // Rows written before the field existed must not export blank.
    const existing = { ...fs._store.get('attributions/attr_a') };
    delete existing.disposalDecidedAt;
    fs._seed('attributions', 'attr_a', existing);

    const { artefact } = await run({ reportType: 'chainOfCustody' });
    const row = JSON.parse(artefact).data.rows.find(
      (r) => r.attributionId === 'attr_a',
    );

    expect(row.date).toBe('2026-09-14');
  });

  test('a unit mass that changed mid-period is stated, not picked', async () => {
    // EPR-12 makes a re-verification an ordinary event. `units` and `massMg`
    // accumulate across every attribution for the SKU while `unitMassMgUsed`
    // was taken from whichever was read first, so units × unitMassMgUsed did
    // not equal massMg — an arithmetic inconsistency in a report an auditor
    // checks by multiplying the columns.
    fs._seed('attributions', 'attr_b', {
      ...fs._store.get('attributions/attr_b'),
      unitMassMgUsed: 10400,
      skuRevision: 2,
    });

    const { artefact } = await run({ reportType: 'skuPerformance' });
    const skuA = JSON.parse(artefact).data.rows.find((r) => r.skuId === 'sku_a');

    expect(skuA.unitMassVaried).toBe(true);
    expect(skuA.revisionVaried).toBe(true);
    // Blanked rather than showing one of the two, which would read as "this is
    // the mass" with no way to know it is one of several.
    expect(skuA.unitMassMgUsed).toBeNull();
    expect(skuA.skuRevision).toBeNull();
    // The totals still accumulate — the figures are right, it is the per-unit
    // column that cannot be stated.
    expect(skuA.units).toBe(4);
  });

  test('an unchanged unit mass is still reported as a figure', async () => {
    // The guard must not blank the ordinary case.
    const { artefact } = await run({ reportType: 'skuPerformance' });
    const skuA = JSON.parse(artefact).data.rows.find((r) => r.skuId === 'sku_a');

    expect(skuA.unitMassVaried).toBe(false);
    expect(skuA.unitMassMgUsed).toBe(9800);
    expect(skuA.skuRevision).toBe(1);
  });

  test('a suppressed district breakdown says so in the CSV too', async () => {
    // `projectForProducer` returns an empty district map when the k-anonymity
    // floor bites (SEC-3), so the CSV was a header line and nothing under it —
    // which `eprPeriods.js` is explicit must not happen: "a quietly absent
    // district list reads as 'no geography recorded', which is a different and
    // false claim." The JSON edition stated it; the CSV edition did not.
    fs._seed('eprPeriods', `${ORG}_${PERIOD}`, {
      ...fs._store.get(`eprPeriods/${ORG}_${PERIOD}`),
      disposalCount: 1,
      attributionCount: 1,
    });

    const { artefact } = await run({
      reportType: 'geographicRecovery',
      format: 'csv',
    });

    // The suppression sentence itself, not merely "a # line" — the CSV always
    // opens with a # header block, so a looser assertion would pass on the
    // generator banner and prove nothing.
    expect(artefact).toContain('# Some districts are withheld');
    // Above the data, where it qualifies what follows.
    expect(artefact.indexOf('# Some districts are withheld'))
      .toBeLessThan(artefact.indexOf('district,massMg'));
    // Still a CSV.
    expect(artefact).toContain('district,massMg');
    // And the rows really are gone, so the note is not decorating a full
    // table. Checked on the data section only: the `#` header carries
    // "Asia/Dhaka", so searching the whole artefact for a district name finds
    // the timezone.
    const body = artefact.slice(artefact.indexOf('district,massMg'));
    expect(body.trim()).toBe('district,massMg');
  });

  test('the suppression note is inside the hashed body', async () => {
    // Deliberately not in the `#` generator header, which is excluded from the
    // content hash. A qualification that can be stripped without changing the
    // hash is one an intermediary can strip and still present the report as
    // verified.
    const suppressed = await run({
      reportType: 'geographicRecovery',
      format: 'csv',
    });

    fs._seed('eprPeriods', `${ORG}_${PERIOD}`, {
      ...fs._store.get(`eprPeriods/${ORG}_${PERIOD}`),
      disposalCount: 40,
      attributionCount: 40,
    });
    const open = await run({ reportType: 'geographicRecovery', format: 'csv' });

    expect(suppressed.job.contentHash).not.toBe(open.job.contentHash);
  });

  test('an unsuppressed geographic CSV carries no note line', async () => {
    // The shared fixture seeds `disposalCount: 3`, under the default floor of
    // 5 — so the suppressed case is the DEFAULT here and this one has to be
    // asked for. Worth stating: a note that appeared unconditionally would
    // have passed the test above while telling every reader their districts
    // were withheld when they were not.
    fs._seed('eprPeriods', `${ORG}_${PERIOD}`, {
      ...fs._store.get(`eprPeriods/${ORG}_${PERIOD}`),
      disposalCount: 40,
      attributionCount: 40,
    });

    const { artefact } = await run({
      reportType: 'geographicRecovery',
      format: 'csv',
    });

    expect(artefact).not.toContain('Some districts are withheld');
    // The rows are actually there, so this is not passing on an empty report.
    expect(artefact).toContain('Dhaka');
    expect(artefact).toContain('Chattogram');
  });
});

describe('the DoE annual return registers the year it reports on', () => {
  test('a passport from outside the twelve periods is not listed', async () => {
    // The register was `listPassports({ orgId, limit: 50 })` — the fifty most
    // recent across ALL time, in a document that reports one registration
    // year. For a producer past its first year that lists certificates from
    // outside the year while omitting ones inside it, in the return a
    // regulator reads.
    //
    // Obligation starts 2026-07, so year 1 is 2026-07 .. 2027-06.
    fs._seed('plasticPassports', 'CHKR-PP-INSIDE-01', {
      serial: 'CHKR-PP-INSIDE-01',
      orgId: ORG,
      periodId: '2026-09',
      status: 'issued',
      contentHash: 'a'.repeat(64),
      issuedAt: { toDate: () => new Date('2026-10-03T05:12:00Z') },
    });
    fs._seed('plasticPassports', 'CHKR-PP-BEFORE-01', {
      serial: 'CHKR-PP-BEFORE-01',
      orgId: ORG,
      periodId: '2026-05',
      status: 'issued',
      contentHash: 'b'.repeat(64),
      issuedAt: { toDate: () => new Date('2026-06-03T05:12:00Z') },
    });
    fs._seed('plasticPassports', 'CHKR-PP-AFTER-01', {
      serial: 'CHKR-PP-AFTER-01',
      orgId: ORG,
      periodId: '2027-08',
      status: 'issued',
      contentHash: 'c'.repeat(64),
      issuedAt: { toDate: () => new Date('2027-09-03T05:12:00Z') },
    });

    const { artefact } = await run({
      reportType: 'doeAnnualProgress',
      periodId: null,
      year: 1,
    });
    const serials = JSON.parse(artefact).data.passportRegister.map(
      (p) => p.serial,
    );

    expect(serials).toContain('CHKR-PP-INSIDE-01');
    expect(serials).not.toContain('CHKR-PP-BEFORE-01');
    expect(serials).not.toContain('CHKR-PP-AFTER-01');
  });
});
