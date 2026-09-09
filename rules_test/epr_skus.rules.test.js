/**
 * The product registry's rules (EPR-9, EPR-11, EPR-12, SEC-4, QA-2).
 *
 * `producerSkus` is the one EPR collection a client really writes, so its
 * allowlist is the boundary that matters. Every denial here has a named
 * consequence: if a client can write the mass a report uses, every control in
 * §6.2 is decoration.
 */

const fs = require('fs');
const path = require('path');
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');

const {
  deleteField,
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
const COLA_REPORTER = 'uid_cola_reporter';
const COLA_VIEWER = 'uid_cola_viewer';
const PRAN_REPORTER = 'uid_pran_reporter';
const CHAMPION = 'uid_champion';
const ADMIN = 'uid_admin';

/** Appendix A's bottle, as a client would propose it. */
function draft(overrides = {}) {
  return {
    orgId: COLA,
    name: 'Coca-Cola 250 ml PET bottle',
    brand: 'Coca-Cola',
    gazetteCategory: 'rigid',
    polymer: 'pet',
    components: [
      { part: 'body', polymer: 'pet', massMg: 8200 },
      { part: 'cap', polymer: 'pp', massMg: 1300 },
      { part: 'label', polymer: 'pet', massMg: 500 },
    ],
    declaredUnitMassMg: 10000,
    declaredUnitMassG: 10,
    sampleImageUrls: ['https://a/1.jpg', 'https://a/2.jpg'],
    status: 'draft',
    ...overrides,
  };
}

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

async function seedOrg(orgId) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'organizations', orgId), {
      legalName: `${orgId} Ltd`,
      tradeName: orgId,
      status: 'active',
      createdAt: new Date(),
    });
  });
}

async function seedMember(orgId, uid, orgRole, status = 'active') {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(
      doc(ctx.firestore(), 'organizationMembers', `${orgId}_${uid}`),
      { orgId, uid, orgRole, status },
    );
  });
}

/** A stored SKU, written past the rules the way the service would. */
async function seedSku(skuId, orgId, overrides = {}) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'producerSkus', skuId), {
      ...draft({ orgId }),
      massStatus: 'draft',
      verifiedUnitMassMg: null,
      revision: 0,
      createdAt: new Date(),
      ...overrides,
    });
  });
}

async function seedRevision(skuId, orgId, revision = 1) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'skuRevisions', `${skuId}_${revision}`), {
      skuId,
      orgId,
      revision,
      declaredUnitMassMg: 10000,
      verifiedUnitMassMg: 9800,
      reason: 'initialVerification',
      changedBy: ADMIN,
      activeFrom: new Date(),
      activeTo: null,
    });
  });
}

async function seedMassAudit(auditId, skuId, orgId) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'skuMassAudits', auditId), {
      skuId,
      orgId,
      sampleSize: 5,
      measuredMeanMg: 9800,
      declaredUnitMassMg: 10000,
      verdict: 'withinTolerance',
      operatorUid: ADMIN,
      toleranceFraction: 0.1,
      createdAt: new Date(),
    });
  });
}

const db = (uid) => testEnv.authenticatedContext(uid).firestore();

beforeAll(async () => {
  setLogLevel('error');
  testEnv = await initializeTestEnvironment({
    projectId: 'chokro-rules-test-epr-skus',
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
  await seedUser(COLA_REPORTER, 'producer');
  await seedUser(COLA_VIEWER, 'producer');
  await seedUser(PRAN_REPORTER, 'producer');
  await seedUser(CHAMPION, 'buyer');
  await seedUser(ADMIN, 'admin');

  await seedOrg(COLA);
  await seedOrg(PRAN);

  await seedMember(COLA, COLA_OWNER, 'orgOwner');
  await seedMember(COLA, COLA_REPORTER, 'orgReporter');
  await seedMember(COLA, COLA_VIEWER, 'orgViewer');
  await seedMember(PRAN, PRAN_REPORTER, 'orgReporter');
});

// ===========================================================================
// Who may write a product
// ===========================================================================

describe('producerSkus: every client write is denied', () => {
  // §5.1 called this "the one collection with a real client write path". It is
  // not, and the reason is in the rules comment: EPR-9's governing constraint is
  // that the component masses SUM to the declared unit mass, and rules have no
  // fold — so a create rule here could check that `components` is a list of one
  // to twelve things and nothing at all about what is in them.
  //
  // These denials are what closing that path looks like. The write goes to the
  // trusted service, which validates the sum on integers, writes the audit entry
  // in the same transaction (EPR-44) and applies the EPR-12 invalidation.

  test('a reporter cannot create one', async () => {
    await assertFails(
      setDoc(doc(db(COLA_REPORTER), 'producerSkus', 'sku_1'), draft()),
    );
  });

  test('an owner cannot create one', async () => {
    await assertFails(
      setDoc(doc(db(COLA_OWNER), 'producerSkus', 'sku_2'), draft()),
    );
  });

  test('a viewer cannot create one', async () => {
    await assertFails(
      setDoc(doc(db(COLA_VIEWER), 'producerSkus', 'sku_3'), draft()),
    );
  });

  test('an administrator cannot create one', async () => {
    // Admins verify masses through the service; they do not author a
    // producer's declaration. Same sentence as `wallets`.
    await assertFails(
      setDoc(doc(db(ADMIN), 'producerSkus', 'sku_4'), draft()),
    );
  });

  test('a Champion cannot create one', async () => {
    await assertFails(
      setDoc(doc(db(CHAMPION), 'producerSkus', 'sku_5'), draft()),
    );
  });

  test('a plausible-looking declaration whose parts do not sum is still denied', async () => {
    // The specific hole a client write would have left open: 5 kg declared
    // against a single 0.1 g body. Rules cannot sum the list, so they cannot
    // refuse it on the merits — they refuse the write instead.
    await assertFails(
      setDoc(
        doc(db(COLA_REPORTER), 'producerSkus', 'sku_sum'),
        draft({
          declaredUnitMassMg: 5000000,
          declaredUnitMassG: 5000,
          components: [{ part: 'body', polymer: 'pet', massMg: 100 }],
        }),
      ),
    );
  });

  test('no client edits a stored product', async () => {
    await seedSku('sku_edit', COLA);
    for (const uid of [COLA_REPORTER, COLA_OWNER, COLA_VIEWER, ADMIN]) {
      await assertFails(
        updateDoc(doc(db(uid), 'producerSkus', 'sku_edit'), { name: 'Changed' }),
      );
    }
  });

  test('no client can smuggle a verified mass in, by create or by update', async () => {
    // If a client could write the mass a report uses, every control in §6.2
    // would be decoration.
    await assertFails(
      setDoc(
        doc(db(COLA_REPORTER), 'producerSkus', 'sku_smuggle'),
        draft({ massStatus: 'verified', verifiedUnitMassMg: 25000 }),
      ),
    );

    await seedSku('sku_smuggle2', COLA);
    await assertFails(
      updateDoc(doc(db(COLA_REPORTER), 'producerSkus', 'sku_smuggle2'), {
        massStatus: 'verified',
        verifiedUnitMassMg: 25000,
      }),
    );
  });

  test('no client DELETES a server-owned field either', async () => {
    // The attack a key-shape validator could not see: `hasOnly` accepts a
    // smaller key set, so removing `revision` passed. `revision` absent means
    // the next verification computes nextRevision = 1 and OVERWRITES
    // skuRevisions/{skuId}_1 — destroying the append-only row a passport
    // issued last quarter was built on.
    await seedSku('sku_del', COLA, {
      massStatus: 'rejected',
      verifiedUnitMassMg: 9800,
      revision: 1,
    });

    for (const field of ['revision', 'verifiedUnitMassMg', 'massStatus']) {
      await assertFails(
        updateDoc(doc(db(COLA_REPORTER), 'producerSkus', 'sku_del'), {
          [field]: deleteField(),
        }),
      );
    }
  });

  test('nobody deletes a product — past attributions reference it', async () => {
    await seedSku('sku_rm', COLA);
    for (const uid of [COLA_REPORTER, COLA_OWNER, ADMIN]) {
      await assertFails(deleteDoc(doc(db(uid), 'producerSkus', 'sku_rm')));
    }
  });
});

describe('producerSkus: reads are tenant-scoped', () => {
  test('a member reads its own catalogue', async () => {
    await seedSku('sku_r1', COLA);
    await assertSucceeds(getDoc(doc(db(COLA_VIEWER), 'producerSkus', 'sku_r1')));
  });

  test("a rival cannot read another company's catalogue", async () => {
    // A producer's registered SKUs are its packaging portfolio.
    await seedSku('sku_r2', COLA);
    await assertFails(getDoc(doc(db(PRAN_REPORTER), 'producerSkus', 'sku_r2')));
  });

  test('a Champion cannot read one', async () => {
    await seedSku('sku_r3', COLA);
    await assertFails(getDoc(doc(db(CHAMPION), 'producerSkus', 'sku_r3')));
  });

  test('an administrator can', async () => {
    await seedSku('sku_r4', COLA);
    await assertSucceeds(getDoc(doc(db(ADMIN), 'producerSkus', 'sku_r4')));
  });

  test('a scoped query succeeds; an unscoped one does not', async () => {
    await seedSku('sku_r5', COLA);
    await seedSku('sku_r6', PRAN);

    await assertSucceeds(
      getDocs(
        query(collection(db(COLA_REPORTER), 'producerSkus'), where('orgId', '==', COLA)),
      ),
    );
    await assertFails(getDocs(collection(db(COLA_REPORTER), 'producerSkus')));
  });
});

// ===========================================================================
// EPR-12 — the history that keeps last quarter true
// ===========================================================================

describe('skuRevisions and skuMassAudits', () => {
  test('a producer reads the basis of the figures Chokro certifies for it', async () => {
    await seedSku('sku_h1', COLA);
    await seedRevision('sku_h1', COLA);
    await seedMassAudit('audit_h1', 'sku_h1', COLA);

    await assertSucceeds(getDoc(doc(db(COLA_VIEWER), 'skuRevisions', 'sku_h1_1')));
    await assertSucceeds(getDoc(doc(db(COLA_VIEWER), 'skuMassAudits', 'audit_h1')));
  });

  test("a rival cannot read another company's revisions or audits", async () => {
    await seedRevision('sku_h2', COLA);
    await seedMassAudit('audit_h2', 'sku_h2', COLA);

    await assertFails(getDoc(doc(db(PRAN_REPORTER), 'skuRevisions', 'sku_h2_1')));
    await assertFails(getDoc(doc(db(PRAN_REPORTER), 'skuMassAudits', 'audit_h2')));
  });

  test('nobody writes a revision — a revision a client could author is a mass a client could set', async () => {
    for (const uid of [COLA_OWNER, COLA_REPORTER, ADMIN]) {
      await assertFails(
        setDoc(doc(db(uid), 'skuRevisions', 'sku_forged_1'), {
          skuId: 'sku_forged',
          orgId: COLA,
          revision: 1,
          verifiedUnitMassMg: 25000,
        }),
      );
    }
  });

  test('a revision cannot be amended or deleted, administrators included', async () => {
    // Without this, September's passport stops being reproducible.
    await seedRevision('sku_h3', COLA);
    await assertFails(
      updateDoc(doc(db(ADMIN), 'skuRevisions', 'sku_h3_1'), {
        verifiedUnitMassMg: 25000,
      }),
    );
    await assertFails(deleteDoc(doc(db(ADMIN), 'skuRevisions', 'sku_h3_1')));
    await assertFails(deleteDoc(doc(db(COLA_OWNER), 'skuRevisions', 'sku_h3_1')));
  });

  test('nobody writes, amends or deletes a mass audit', async () => {
    await seedMassAudit('audit_h4', 'sku_h4', COLA);
    for (const uid of [COLA_OWNER, ADMIN]) {
      await assertFails(
        setDoc(doc(db(uid), 'skuMassAudits', 'audit_forged'), {
          skuId: 'sku_h4',
          orgId: COLA,
          measuredMeanMg: 25000,
        }),
      );
      await assertFails(
        updateDoc(doc(db(uid), 'skuMassAudits', 'audit_h4'), { verdict: 'withinTolerance' }),
      );
      await assertFails(deleteDoc(doc(db(uid), 'skuMassAudits', 'audit_h4')));
    }
  });
});
