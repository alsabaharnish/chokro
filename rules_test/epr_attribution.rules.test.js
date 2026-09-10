/**
 * Attribution rules (EPR-6, EPR-19, EPR-22, SEC-3, SEC-4, QA-2).
 *
 * QA-2 asks for a proven denial per rule, and names one regression explicitly:
 * "that the `disposals` client allowlist has **not** grown". That test is the
 * last one in this file and it is the one that matters most — EPR-6's sentence
 * is "if a client can write a mass, the mass is worthless".
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
  deleteField,
  doc,
  collection,
  query,
  where,
  serverTimestamp,
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
const OPEN_BIN = 'bin_open';

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

async function seedAttribution(id, orgId) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'attributions', id), {
      disposalId: 'disposal_anik',
      orgId,
      skuId: 'sku_cola',
      skuRevision: 1,
      units: 2,
      unitMassMgUsed: 9800,
      massMg: 19600,
      massMgByPolymer: { pet: 17052, pp: 2548 },
      method: 'aiSku',
      confidence: 0.91,
      confidenceTier: 'high',
      periodId: '2026-09',
      binId: OPEN_BIN,
      district: 'Dhaka',
      gazetteCategory: 'rigid',
      createdAt: new Date(),
    });
  });
}

async function seedPeriod(orgId, periodId = '2026-09') {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'eprPeriods', `${orgId}_${periodId}`), {
      orgId,
      periodId,
      massMgByCategory: { rigid: 19600 },
      attributionCount: 1,
    });
  });
}

async function seedBin(binId) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'bins', binId), {
      label: binId,
      lat: 23.7808,
      lng: 90.4074,
      radiusMeters: 50,
      qrPayload: `chokro:bin:${binId}`,
      active: true,
      createdBy: ADMIN,
      createdAt: new Date(),
    });
  });
}

const db = (uid) => testEnv.authenticatedContext(uid).firestore();

beforeAll(async () => {
  setLogLevel('error');
  testEnv = await initializeTestEnvironment({
    projectId: 'chokro-rules-test-epr-attribution',
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
  await seedBin(OPEN_BIN);
});

// ===========================================================================
// attributions
// ===========================================================================

describe('attributions', () => {
  test('a producer cannot read its OWN evidence rows (SEC-3)', async () => {
    // The grant this replaces let a producer's members read their own rows,
    // with a comment conceding no screen rendered them. "No screen renders it"
    // is a statement about the product, not a control: a producer holds its own
    // Firebase credentials, the composite index is shipped, and the Firestore
    // SDK is a public API.
    //
    // Each row carries `binId`, `disposalDecidedAt` at second precision and the
    // real `disposalId`. `bins` is readable by any signed-in account and
    // carries lat/lng, so joining the two reconstructs SEC-3's stated failure
    // mode: "a map of who throws what where, to a commercial party".
    //
    // Row-level access needs a per-organisation pseudonymous reference and a
    // k-anonymity floor, neither of which rules can provide. Both belong to the
    // Phase D export.
    await seedAttribution('attr_1', COLA);
    await assertFails(getDoc(doc(db(COLA_OWNER), 'attributions', 'attr_1')));
    await assertFails(getDoc(doc(db(COLA_VIEWER), 'attributions', 'attr_1')));
  });

  test("a rival cannot read another company's evidence", async () => {
    await seedAttribution('attr_1', COLA);
    await assertFails(getDoc(doc(db(PRAN_OWNER), 'attributions', 'attr_1')));
  });

  test('a Champion cannot read attributions', async () => {
    await seedAttribution('attr_1', COLA);
    await assertFails(getDoc(doc(db(CHAMPION), 'attributions', 'attr_1')));
  });

  test('an administrator can', async () => {
    await seedAttribution('attr_1', COLA);
    await assertSucceeds(getDoc(doc(db(ADMIN), 'attributions', 'attr_1')));
  });

  test('no producer query reaches the collection, scoped or not', async () => {
    // The specific attack the shipped index makes cheap:
    // attributions.where(orgId).where(periodId).orderBy(createdAt).
    await seedAttribution('attr_1', COLA);
    await seedAttribution('attr_2', PRAN);

    await assertFails(
      getDocs(query(collection(db(COLA_OWNER), 'attributions'), where('orgId', '==', COLA))),
    );
    await assertFails(getDocs(collection(db(COLA_OWNER), 'attributions')));
    // An Admin still can, which is what the reconciliation console needs.
    await assertSucceeds(
      getDocs(query(collection(db(ADMIN), 'attributions'), where('orgId', '==', COLA))),
    );
  });

  test('nobody writes an attribution — a client that could would author a kilogram', async () => {
    for (const uid of [COLA_OWNER, CHAMPION, ADMIN]) {
      await assertFails(
        setDoc(doc(db(uid), 'attributions', 'forged'), {
          orgId: COLA,
          skuId: 'sku_cola',
          units: 1000,
          massMg: 9800000,
          periodId: '2026-09',
        }),
      );
    }
  });

  test('nobody edits or deletes one, administrators included', async () => {
    // A reversal is a server write with a recorded reason (EPR-21); it is
    // never a client edit and never a delete.
    await seedAttribution('attr_1', COLA);
    for (const uid of [COLA_OWNER, ADMIN]) {
      await assertFails(
        updateDoc(doc(db(uid), 'attributions', 'attr_1'), { massMg: 99999 }),
      );
      await assertFails(
        updateDoc(doc(db(uid), 'attributions', 'attr_1'), {
          reversedAt: serverTimestamp(),
        }),
      );
      await assertFails(deleteDoc(doc(db(uid), 'attributions', 'attr_1')));
    }
  });
});

// ===========================================================================
// eprPeriods
// ===========================================================================

describe('eprPeriods', () => {
  test('a member reads its own period', async () => {
    await seedPeriod(COLA);
    await assertSucceeds(
      getDoc(doc(db(COLA_VIEWER), 'eprPeriods', `${COLA}_2026-09`)),
    );
  });

  test("a rival cannot read another company's period", async () => {
    // A rival reading this learns a competitor's collection position.
    await seedPeriod(COLA);
    await assertFails(
      getDoc(doc(db(PRAN_OWNER), 'eprPeriods', `${COLA}_2026-09`)),
    );
  });

  test('the platform unattributed pool is Admin-only', async () => {
    // An unrecognised item belongs to nobody (EPR-19), so this is a platform
    // figure — and a producer reading it would learn how much of every other
    // company's packaging goes unrecognised.
    await seedPeriod('__platform');

    await assertFails(
      getDoc(doc(db(COLA_OWNER), 'eprPeriods', '__platform_2026-09')),
    );
    await assertSucceeds(
      getDoc(doc(db(ADMIN), 'eprPeriods', '__platform_2026-09')),
    );
  });

  test('no client writes a rollup, not even its own', async () => {
    await seedPeriod(COLA);
    for (const uid of [COLA_OWNER, ADMIN]) {
      await assertFails(
        setDoc(doc(db(uid), 'eprPeriods', `${COLA}_2026-10`), {
          orgId: COLA,
          periodId: '2026-10',
          massMgByCategory: { rigid: 999999 },
        }),
      );
      await assertFails(
        updateDoc(doc(db(uid), 'eprPeriods', `${COLA}_2026-09`), {
          'massMgByCategory.rigid': 999999,
        }),
      );
      await assertFails(
        deleteDoc(doc(db(uid), 'eprPeriods', `${COLA}_2026-09`)),
      );
    }
  });

  test('a producer cannot forge a recompute verdict', async () => {
    // The match/mismatch flag is itself a reportable control (EPR-22). A
    // producer that could set it could report its own reconciliation as clean.
    await seedPeriod(COLA);
    await assertFails(
      updateDoc(doc(db(COLA_OWNER), 'eprPeriods', `${COLA}_2026-09`), {
        recomputeMatched: true,
        recomputedAt: serverTimestamp(),
      }),
    );
  });
});

// ===========================================================================
// The queues and signals
// ===========================================================================

describe('attributionConfirmations and binSkuFrequency', () => {
  beforeEach(async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'attributionConfirmations', 'c1'), {
        disposalId: 'disposal_anik',
        skuId: 'sku_cola',
        orgId: COLA,
        confidenceTier: 'low',
        reason: 'lowConfidence',
        status: 'pending',
        createdAt: new Date(),
      });
      await setDoc(doc(ctx.firestore(), 'binSkuFrequency', OPEN_BIN), {
        binId: OPEN_BIN,
        counts: { sku_cola: 12 },
      });
    });
  });

  test('the confirmation queue is Admin-only', async () => {
    // A producer seeing "Chokro thinks it saw your bottle but is not sure"
    // would be seeing a figure explicitly not part of its evidence — and an
    // accuracy sample measures Chokro's recognition, not the producer's
    // collection.
    await assertFails(getDoc(doc(db(COLA_OWNER), 'attributionConfirmations', 'c1')));
    await assertFails(getDoc(doc(db(CHAMPION), 'attributionConfirmations', 'c1')));
    await assertSucceeds(getDoc(doc(db(ADMIN), 'attributionConfirmations', 'c1')));
  });

  test('per-bin brand frequency is Admin-only', async () => {
    // A map of what sells where, which is commercially interesting to exactly
    // the parties who must not have it.
    await assertFails(getDoc(doc(db(COLA_OWNER), 'binSkuFrequency', OPEN_BIN)));
    await assertSucceeds(getDoc(doc(db(ADMIN), 'binSkuFrequency', OPEN_BIN)));
  });

  test('no client writes either', async () => {
    for (const uid of [COLA_OWNER, ADMIN]) {
      await assertFails(
        updateDoc(doc(db(uid), 'attributionConfirmations', 'c1'), {
          status: 'confirmed',
        }),
      );
      await assertFails(
        updateDoc(doc(db(uid), 'binSkuFrequency', OPEN_BIN), {
          'counts.sku_cola': 9999,
        }),
      );
    }
  });
});

// ===========================================================================
// EPR-6 / QA-2 — the regression that matters most
// ===========================================================================

describe('the disposals client allowlist has NOT grown (EPR-6, QA-2)', () => {
  /** The exact payload the client has always been allowed to create. */
  function validDisposal(uid) {
    return {
      userId: uid,
      binId: OPEN_BIN,
      photoUrl: `https://res.cloudinary.com/ata3ir5d/image/upload/v1/chokro/disposals/${uid}/abc123.jpg`,
      photoPublicId: `chokro/disposals/${uid}/abc123`,
      capturedLat: 23.7809,
      capturedLng: 90.4074,
      distanceMeters: 11.2,
      declaredItemCount: 2,
      itemType: 'plasticBottle',
      status: 'pending',
      flags: [],
      createdAt: serverTimestamp(),
    };
  }

  test('the unchanged payload still creates', async () => {
    // The baseline. Without this the denials below could pass because the whole
    // create path had broken.
    await assertSucceeds(
      setDoc(doc(db(CHAMPION), 'disposals', 'd_ok'), validDisposal(CHAMPION)),
    );
  });

  test('every attribution field is refused on create', async () => {
    // "If a client can write a mass, the mass is worthless." Each of these is
    // server-owned, and each would let a Champion — or a script holding their
    // token — write a figure a regulator will read.
    const forbidden = {
      attributionStatus: 'attributed',
      skuMatchCount: 3,
      attributedMassGrams: 999999,
      gazetteCategoryResolved: 'rigid',
      skuMatches: [{ skuId: 'sku_cola', units: 99, confidence: 1 }],
      scannedGtin: '8901234567890',
      attributionPeriodId: '2026-09',
      attributedAt: serverTimestamp(),
    };

    for (const [field, value] of Object.entries(forbidden)) {
      await assertFails(
        setDoc(doc(db(CHAMPION), 'disposals', `d_${field}`), {
          ...validDisposal(CHAMPION),
          [field]: value,
        }),
      );
    }
  });

  test('a Champion cannot add an attribution field afterwards', async () => {
    // There is no client transition out of pending, and no client write to a
    // disposal at all after create.
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'disposals', 'd_after'), {
        ...validDisposal(CHAMPION),
        createdAt: new Date(),
        status: 'autoApproved',
        attributionStatus: 'pending',
      });
    });

    await assertFails(
      updateDoc(doc(db(CHAMPION), 'disposals', 'd_after'), {
        attributionStatus: 'attributed',
        attributedMassGrams: 999999,
      }),
    );
    await assertFails(
      updateDoc(doc(db(CHAMPION), 'disposals', 'd_after'), {
        scannedGtin: '8901234567890',
      }),
    );
  });

  test('an administrator cannot write an attribution field either', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'disposals', 'd_admin'), {
        ...validDisposal(CHAMPION),
        createdAt: new Date(),
        status: 'autoApproved',
      });
    });

    await assertFails(
      updateDoc(doc(db(ADMIN), 'disposals', 'd_admin'), {
        attributedMassGrams: 999999,
      }),
    );
  });

  test('a producer cannot read a disposal at all (SEC-3)', async () => {
    // No uid, name, email, photograph of a person, wallet balance or points
    // figure crosses into a producer-facing surface. The disposal read rule is
    // owner-or-admin, and a producer is neither.
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'disposals', 'd_priv'), {
        ...validDisposal(CHAMPION),
        createdAt: new Date(),
        status: 'autoApproved',
      });
    });

    await assertFails(getDoc(doc(db(COLA_OWNER), 'disposals', 'd_priv')));
    await assertFails(getDoc(doc(db(COLA_VIEWER), 'disposals', 'd_priv')));
  });

  test('a producer cannot read a Champion account or wallet', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'wallets', CHAMPION), {
        userId: CHAMPION,
        balance: 500,
        updatedAt: new Date(),
      });
    });

    await assertFails(getDoc(doc(db(COLA_OWNER), 'users', CHAMPION)));
    await assertFails(getDoc(doc(db(COLA_OWNER), 'wallets', CHAMPION)));
  });

  test('a Champion cannot delete a field to escape the allowlist', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'disposals', 'd_del'), {
        ...validDisposal(CHAMPION),
        createdAt: new Date(),
      });
    });

    await assertFails(
      updateDoc(doc(db(CHAMPION), 'disposals', 'd_del'), {
        flags: deleteField(),
      }),
    );
  });
});
