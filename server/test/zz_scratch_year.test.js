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


test('scratch: calendar year 2026 annual return', async () => {
  const { job, artefact } = await run({ reportType: 'doeAnnualProgress', periodId: null, year: 2026 });
  console.log('STATUS', job.status, 'ERR', job.error);
  const parsed = JSON.parse(artefact);
  console.log('HEADER year', parsed._header.year, '| period', parsed._header.period);
  console.log('HEADER lines scope:', parsed._header.lines[3]);
  console.log('PERIODS', JSON.stringify(parsed.data.periods.slice(0,2)));
  console.log('GAZETTE', JSON.stringify(parsed.data.gazetteTargets.slice(0,2)));
});

test('scratch: obligation year 1 for contrast', async () => {
  const { job, artefact } = await run({ reportType: 'doeAnnualProgress', periodId: null, year: 1 });
  const parsed = JSON.parse(artefact);
  console.log('Y1 STATUS', job.status);
  console.log('Y1 PERIODS', JSON.stringify(parsed.data.periods.filter(p=>p.collectedMassMg>0)));
});
