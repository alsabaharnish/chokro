/**
 * Declaration and passport rules (EPR-28 to EPR-31, EPR-40 to EPR-43, SEC-1,
 * SEC-7, QA-2).
 *
 * QA-2 asks for a proven denial per rule. The denial that matters most here is
 * the one on `plasticPassports`, and it matters for a reason that is easy to
 * miss:
 *
 *   A SERIAL IS UNGUESSABLE BUT NOT SECRET.
 *
 * It is printed on a PDF that gets emailed to customers and filed with a
 * regulator. So the tempting rule — "anyone signed in who knows the serial can
 * read it" — would turn every certificate a producer sends out into a read
 * handle on its own stored figure snapshot: the declared denominator, the
 * evidence counts, the polymer split. A rival who received one Coca-Cola
 * certificate would hold a live read on Coca-Cola's compliance position.
 *
 * Hence membership, not knowledge of the id, and hence the unauthenticated
 * `GET /passports/verify/{serial}` endpoint, which exists precisely so this
 * rule can stay closed.
 */

const fs = require('fs');
const path = require('path');
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');

const {
  setDoc,
  getDoc,
  getDocs,
  updateDoc,
  deleteDoc,
  doc,
  collection,
  query,
  where,
  setLogLevel,
} = require('firebase/firestore');

let testEnv;

const COLA = 'org_cola';
const PRAN = 'org_pran';
const COLA_OWNER = 'uid_cola_owner';
const COLA_VIEWER = 'uid_cola_viewer';
const PRAN_OWNER = 'uid_pran_owner';
const CHAMPION = 'uid_champion';
const ADMIN = 'uid_admin';

const PERIOD = '2026-09';
const COLA_SERIAL = 'CHKR-PP-9F2K-7T4D';
const PRAN_SERIAL = 'CHKR-PP-M4XT-2W7B';

async function seedUser(uid, role, status = 'active') {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'users', uid), {
      name: uid,
      email: `${uid}@test.com`,
      role,
      status,
      createdAt: new Date(),
    });
  });
}

async function seedOrgAndMember(orgId, uid, orgRole) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'organizations', orgId), {
      legalName: `${orgId} Ltd`,
      tradeName: orgId,
      status: 'active',
      createdAt: new Date(),
    });
    await setDoc(doc(ctx.firestore(), 'organizationMembers', `${orgId}_${uid}`), {
      orgId,
      uid,
      orgRole,
      status: 'active',
    });
  });
}

async function seedDeclaration(orgId, periodId = PERIOD, status = 'submitted') {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(
      doc(ctx.firestore(), 'putOnMarketDeclarations', `${orgId}_${periodId}`),
      {
        orgId,
        periodId,
        status,
        version: 1,
        lines: [{ category: 'rigid', units: 720000, massMg: 18000000000 }],
        totalMassMg: 18000000000,
        attestedByName: 'Nasrin Akhter',
        createdAt: new Date(),
      },
    );
    await setDoc(
      doc(ctx.firestore(), 'putOnMarketVersions', `${orgId}_${periodId}_1`),
      {
        orgId,
        periodId,
        version: 1,
        totalMassMg: 18000000000,
        lines: [{ category: 'rigid', units: 720000, massMg: 18000000000 }],
        createdAt: new Date(),
      },
    );
  });
}

async function seedPassport(serial, orgId, status = 'issued') {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'plasticPassports', serial), {
      serial,
      orgId,
      periodId: PERIOD,
      scope: 'period',
      status,
      contentHash: 'a'.repeat(64),
      figures: {
        orgId,
        periodId: PERIOD,
        organizationLegalName: `${orgId} Ltd`,
        organizationTradeName: orgId,
        collectedMassMg: 5000000000,
        declaredMassMg: 18000000000,
        collectionRate: 0.2777,
        attributionCount: 224200,
      },
      issuedBy: ADMIN,
      issuedAt: new Date(),
      createdAt: new Date(),
    });
  });
}

const db = (uid) => testEnv.authenticatedContext(uid).firestore();
const anon = () => testEnv.unauthenticatedContext().firestore();

beforeAll(async () => {
  setLogLevel('error');
  testEnv = await initializeTestEnvironment({
    projectId: 'chokro-rules-test-epr-passports',
    firestore: {
      rules: fs.readFileSync(path.resolve(__dirname, '../firestore.rules'), 'utf8'),
      host: '127.0.0.1',
      port: 8080,
    },
  });
});

afterAll(async () => {
  await testEnv.cleanup();
});

beforeEach(async () => {
  await testEnv.clearFirestore();
  await seedUser(COLA_OWNER, 'producer');
  await seedUser(COLA_VIEWER, 'producer');
  await seedUser(PRAN_OWNER, 'producer');
  await seedUser(CHAMPION, 'buyer');
  await seedUser(ADMIN, 'admin');
  await seedOrgAndMember(COLA, COLA_OWNER, 'orgOwner');
  await seedOrgAndMember(COLA, COLA_VIEWER, 'orgViewer');
  await seedOrgAndMember(PRAN, PRAN_OWNER, 'orgOwner');
});

// ===========================================================================
// putOnMarketDeclarations
// ===========================================================================

describe('putOnMarketDeclarations', () => {
  beforeEach(async () => {
    await seedDeclaration(COLA);
    await seedDeclaration(PRAN);
  });

  test('a member reads its own filing, at any org role', async () => {
    for (const uid of [COLA_OWNER, COLA_VIEWER]) {
      await assertSucceeds(
        getDoc(doc(db(uid), 'putOnMarketDeclarations', `${COLA}_${PERIOD}`)),
      );
    }
  });

  test('an administrator reads any filing', async () => {
    await assertSucceeds(
      getDoc(doc(db(ADMIN), 'putOnMarketDeclarations', `${COLA}_${PERIOD}`)),
    );
  });

  test('another producer cannot read it (SEC-1)', async () => {
    // The declared denominator is the most commercially sensitive figure a
    // producer files: it is that company's annual volume, by category.
    await assertFails(
      getDoc(doc(db(PRAN_OWNER), 'putOnMarketDeclarations', `${COLA}_${PERIOD}`)),
    );
  });

  test('a Champion cannot read it', async () => {
    await assertFails(
      getDoc(doc(db(CHAMPION), 'putOnMarketDeclarations', `${COLA}_${PERIOD}`)),
    );
  });

  test('nobody signed out can read it', async () => {
    await assertFails(
      getDoc(doc(anon(), 'putOnMarketDeclarations', `${COLA}_${PERIOD}`)),
    );
  });

  test('a query cannot escape the membership boundary', async () => {
    // A collection query is evaluated per document, so a filter naming another
    // organisation fails on the first row it cannot read rather than returning
    // a filtered set.
    await assertFails(
      getDocs(
        query(
          collection(db(PRAN_OWNER), 'putOnMarketDeclarations'),
          where('orgId', '==', COLA),
        ),
      ),
    );
  });

  test('not even the owner can write one', async () => {
    // §5.1's preference is to enforce a constraint where it is expressed, and
    // its own test is whether the constraint is expressible in rules. Here it
    // is not: submission must append an immutable version row and an audit
    // entry in the same transaction, and a correction must supersede every
    // passport for the period. Rules can do none of the three, so a rule
    // permitting the write would check the shape of `lines` while everything
    // that makes the filing trustworthy happened elsewhere, or not at all.
    await assertFails(
      updateDoc(doc(db(COLA_OWNER), 'putOnMarketDeclarations', `${COLA}_${PERIOD}`), {
        totalMassMg: 1000,
      }),
    );
    await assertFails(
      setDoc(doc(db(COLA_OWNER), 'putOnMarketDeclarations', `${COLA}_2026-10`), {
        orgId: COLA,
        periodId: '2026-10',
        status: 'submitted',
        totalMassMg: 1,
      }),
    );
    await assertFails(
      deleteDoc(doc(db(COLA_OWNER), 'putOnMarketDeclarations', `${COLA}_${PERIOD}`)),
    );
  });

  test('an administrator cannot write one either', async () => {
    // Chokro changing a producer's attested figure from a client would be
    // indistinguishable from the producer doing it, and the attestation names
    // the producer.
    await assertFails(
      updateDoc(doc(db(ADMIN), 'putOnMarketDeclarations', `${COLA}_${PERIOD}`), {
        totalMassMg: 1000,
      }),
    );
  });
});

// ===========================================================================
// putOnMarketVersions
// ===========================================================================

describe('putOnMarketVersions', () => {
  beforeEach(async () => {
    await seedDeclaration(COLA);
  });

  test('a member reads its own history', async () => {
    await assertSucceeds(
      getDoc(doc(db(COLA_VIEWER), 'putOnMarketVersions', `${COLA}_${PERIOD}_1`)),
    );
  });

  test('another producer cannot', async () => {
    await assertFails(
      getDoc(doc(db(PRAN_OWNER), 'putOnMarketVersions', `${COLA}_${PERIOD}_1`)),
    );
  });

  test('a withdrawn version cannot be deleted', async () => {
    // The point of retaining it. A producer able to remove the version it
    // withdrew could file a flattering figure, be asked about it, and make the
    // question unanswerable — and EPR-43's correction variance reads exactly
    // this row.
    await assertFails(
      deleteDoc(doc(db(COLA_OWNER), 'putOnMarketVersions', `${COLA}_${PERIOD}_1`)),
    );
    await assertFails(
      deleteDoc(doc(db(ADMIN), 'putOnMarketVersions', `${COLA}_${PERIOD}_1`)),
    );
  });

  test('a withdrawn version cannot be amended', async () => {
    await assertFails(
      updateDoc(doc(db(COLA_OWNER), 'putOnMarketVersions', `${COLA}_${PERIOD}_1`), {
        totalMassMg: 1,
      }),
    );
  });
});

// ===========================================================================
// plasticPassports
// ===========================================================================

describe('plasticPassports', () => {
  beforeEach(async () => {
    await seedPassport(COLA_SERIAL, COLA);
    await seedPassport(PRAN_SERIAL, PRAN);
  });

  test('a member reads its own certificate', async () => {
    for (const uid of [COLA_OWNER, COLA_VIEWER]) {
      await assertSucceeds(getDoc(doc(db(uid), 'plasticPassports', COLA_SERIAL)));
    }
  });

  test('an administrator reads any certificate', async () => {
    await assertSucceeds(getDoc(doc(db(ADMIN), 'plasticPassports', COLA_SERIAL)));
  });

  test('knowing the serial is not authorisation to read the record (SEC-1)', async () => {
    // THE TEST THIS FILE EXISTS FOR.
    //
    // A serial is unguessable but not secret: it is printed on a PDF that gets
    // emailed to customers and filed with a regulator. `PRAN_OWNER` here stands
    // for a competitor who received a Coca-Cola certificate in the ordinary
    // course of business and now knows its serial exactly.
    //
    // The stored document carries the full figure snapshot — the declared
    // denominator, the collected mass, the evidence counts. A rule of the form
    // "anyone signed in who knows the serial" would make every certificate a
    // producer sends out a live read handle on its own compliance position.
    await assertFails(getDoc(doc(db(PRAN_OWNER), 'plasticPassports', COLA_SERIAL)));
    await assertFails(getDoc(doc(db(CHAMPION), 'plasticPassports', COLA_SERIAL)));
    await assertFails(getDoc(doc(anon(), 'plasticPassports', COLA_SERIAL)));
  });

  test('a producer cannot forge a certificate for itself', async () => {
    // EPR-31: "a certificate a user's device produced is a certificate a user's
    // device can alter". Denied not because a client write would be badly
    // shaped, but because a client-authored certificate would not be a
    // certificate.
    await assertFails(
      setDoc(doc(db(COLA_OWNER), 'plasticPassports', 'CHKR-PP-0000-0001'), {
        serial: 'CHKR-PP-0000-0001',
        orgId: COLA,
        periodId: PERIOD,
        status: 'issued',
        contentHash: 'b'.repeat(64),
        figures: { collectionRate: 0.95 },
      }),
    );
  });

  test('a producer cannot forge one for a rival', async () => {
    await assertFails(
      setDoc(doc(db(PRAN_OWNER), 'plasticPassports', 'CHKR-PP-0000-0002'), {
        serial: 'CHKR-PP-0000-0002',
        orgId: COLA,
        periodId: PERIOD,
        status: 'issued',
      }),
    );
  });

  test('a producer cannot raise its own figures on an issued certificate', async () => {
    await assertFails(
      updateDoc(doc(db(COLA_OWNER), 'plasticPassports', COLA_SERIAL), {
        'figures.collectionRate': 0.95,
      }),
    );
    await assertFails(
      updateDoc(doc(db(COLA_OWNER), 'plasticPassports', COLA_SERIAL), {
        contentHash: 'c'.repeat(64),
      }),
    );
  });

  test('a producer cannot un-supersede or un-revoke its certificate', async () => {
    // EPR-30. A superseded certificate stays in circulation, and the whole
    // value of the verification endpoint is that it says so. A producer able to
    // flip the status back would make a withdrawn figure verifiable again.
    await seedPassport('CHKR-PP-0000-0003', COLA, 'superseded');
    await assertFails(
      updateDoc(doc(db(COLA_OWNER), 'plasticPassports', 'CHKR-PP-0000-0003'), {
        status: 'issued',
      }),
    );

    await seedPassport('CHKR-PP-0000-0004', COLA, 'revoked');
    await assertFails(
      updateDoc(doc(db(COLA_OWNER), 'plasticPassports', 'CHKR-PP-0000-0004'), {
        status: 'issued',
      }),
    );
  });

  test('a producer cannot delete a certificate that embarrasses it', async () => {
    await assertFails(
      deleteDoc(doc(db(COLA_OWNER), 'plasticPassports', COLA_SERIAL)),
    );
  });

  test('an administrator cannot write one from a client either', async () => {
    // Issuance goes through the service, which mints the serial, computes the
    // hash and appends to the audit chain in one transaction. An Admin path
    // that bypassed that would produce a certificate with no audit entry — the
    // insider abuse SEC-12 names.
    await assertFails(
      setDoc(doc(db(ADMIN), 'plasticPassports', 'CHKR-PP-0000-0005'), {
        serial: 'CHKR-PP-0000-0005',
        orgId: COLA,
        periodId: PERIOD,
        status: 'issued',
      }),
    );
    await assertFails(
      updateDoc(doc(db(ADMIN), 'plasticPassports', COLA_SERIAL), { status: 'revoked' }),
    );
    await assertFails(
      deleteDoc(doc(db(ADMIN), 'plasticPassports', COLA_SERIAL)),
    );
  });

  test('a query cannot enumerate another organisation’s certificates', async () => {
    await assertFails(
      getDocs(
        query(collection(db(PRAN_OWNER), 'plasticPassports'), where('orgId', '==', COLA)),
      ),
    );
  });

  test('a member can list its own', async () => {
    await assertSucceeds(
      getDocs(
        query(collection(db(COLA_VIEWER), 'plasticPassports'), where('orgId', '==', COLA)),
      ),
    );
  });

  test('a removed member loses access to the certificates', async () => {
    // Membership is resolved by a single `get()` on `organizationMembers`, so
    // revoking it revokes the read with no separate step to forget.
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await updateDoc(
        doc(ctx.firestore(), 'organizationMembers', `${COLA}_${COLA_VIEWER}`),
        { status: 'removed' },
      );
    });

    await assertFails(getDoc(doc(db(COLA_VIEWER), 'plasticPassports', COLA_SERIAL)));
    await assertFails(
      getDoc(doc(db(COLA_VIEWER), 'putOnMarketDeclarations', `${COLA}_${PERIOD}`)),
    );
  });

  test('a suspended workspace keeps its certificates readable', async () => {
    // EPR-30 and the suspension wording both depend on this: suspension makes a
    // workspace read-only, and "existing records and documents stay available".
    // A certificate a third party is holding must stay verifiable and readable
    // by the producer that has to answer questions about it.
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await updateDoc(doc(ctx.firestore(), 'organizations', COLA), {
        status: 'suspended',
      });
    });

    await assertSucceeds(getDoc(doc(db(COLA_OWNER), 'plasticPassports', COLA_SERIAL)));
  });
});
