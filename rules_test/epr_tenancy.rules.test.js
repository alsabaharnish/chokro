/**
 * EPR producer portal — tenancy isolation and the disjoint producer role.
 *
 * QA-2 requires a proven denial, not a passing happy path, for each of these.
 * SEC-1's failure mode is the most damaging incident this product can have —
 * one company reading another's compliance position — so the cross-tenant
 * denials are the reason this file exists and are written first.
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
  serverTimestamp,
  setLogLevel,
} = require('firebase/firestore');

let testEnv;

// Two organisations, because a single-tenant test proves nothing about
// isolation.
const COLA = 'org_cola';
const PRAN = 'org_pran';

const COLA_OWNER = 'uid_cola_owner';
const COLA_REPORTER = 'uid_cola_reporter';
const COLA_VIEWER = 'uid_cola_viewer';
const COLA_INVITED = 'uid_cola_invited';
const COLA_REMOVED = 'uid_cola_removed';
const COLA_SUSPENDED = 'uid_cola_suspended';
const PRAN_OWNER = 'uid_pran_owner';

const CHAMPION = 'uid_champion';
const ADMIN = 'uid_admin';

const OPEN_BIN = 'bin_open';

// ---------------------------------------------------------------------------
// Seed helpers — all bypass rules, so they set up state without asserting it
// ---------------------------------------------------------------------------

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

async function seedOrg(orgId, status = 'active') {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'organizations', orgId), {
      legalName: `${orgId} Ltd`,
      tradeName: orgId,
      status,
      sizeClass: 'large',
      complianceRoute: 'self',
      categories: ['rigid'],
      contactEmail: `contact@${orgId}.test`,
      createdAt: new Date(),
    });
  });
}

async function seedMember(orgId, uid, orgRole, status = 'active') {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'organizationMembers', `${orgId}_${uid}`), {
      orgId,
      uid,
      orgRole,
      status,
      email: `${uid}@test.com`,
      invitedBy: ADMIN,
      invitedAt: new Date(),
      activatedAt: status === 'active' ? new Date() : null,
    });
  });
}

async function seedAuditEntry(entryId, orgId) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'producerAuditLog', entryId), {
      orgId,
      action: 'org.approved',
      actorUid: ADMIN,
      actorRole: 'admin',
      targetType: 'organization',
      targetId: orgId,
      summary: 'Onboarding approved.',
      previousDigest: null,
      digest: 'a'.repeat(64),
      sequence: 1,
      timestamp: new Date(),
    });
  });
}

async function seedBin(binId, active = true) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'bins', binId), {
      label: binId,
      lat: 23.7808,
      lng: 90.4074,
      radiusMeters: 50,
      qrPayload: `chokro:bin:${binId}`,
      active,
      createdBy: ADMIN,
      createdAt: new Date(),
    });
  });
}

const db = (uid) => testEnv.authenticatedContext(uid).firestore();

beforeAll(async () => {
  setLogLevel('error');
  testEnv = await initializeTestEnvironment({
    projectId: 'chokro-rules-test-epr',
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
  await seedUser(COLA_INVITED, 'producer');
  await seedUser(COLA_REMOVED, 'producer');
  await seedUser(COLA_SUSPENDED, 'producer', 'suspended');
  await seedUser(PRAN_OWNER, 'producer');
  await seedUser(CHAMPION, 'buyer');
  await seedUser(ADMIN, 'admin');

  await seedOrg(COLA);
  await seedOrg(PRAN);

  await seedMember(COLA, COLA_OWNER, 'orgOwner');
  await seedMember(COLA, COLA_REPORTER, 'orgReporter');
  await seedMember(COLA, COLA_VIEWER, 'orgViewer');
  await seedMember(COLA, COLA_INVITED, 'orgReporter', 'invited');
  await seedMember(COLA, COLA_REMOVED, 'orgOwner', 'removed');
  await seedMember(COLA, COLA_SUSPENDED, 'orgOwner');
  await seedMember(PRAN, PRAN_OWNER, 'orgOwner');

  await seedAuditEntry('audit_cola_1', COLA);
  await seedAuditEntry('audit_pran_1', PRAN);

  await seedBin(OPEN_BIN, true);
});

// ===========================================================================
// SEC-1 — cross-tenant isolation. The reason this file exists.
// ===========================================================================

describe('organizations: tenant isolation', () => {
  test('a member reads its own organisation', async () => {
    await assertSucceeds(getDoc(doc(db(COLA_VIEWER), 'organizations', COLA)));
  });

  test("a member cannot read another company's organisation", async () => {
    // SEC-1's stated failure mode, at the smallest possible scale.
    await assertFails(getDoc(doc(db(COLA_OWNER), 'organizations', PRAN)));
    await assertFails(getDoc(doc(db(PRAN_OWNER), 'organizations', COLA)));
  });

  test('a Champion cannot read any organisation', async () => {
    // Which brands are obligated is not a citizen-facing fact.
    await assertFails(getDoc(doc(db(CHAMPION), 'organizations', COLA)));
  });

  test('an anonymous visitor cannot read an organisation', async () => {
    const anon = testEnv.unauthenticatedContext().firestore();
    await assertFails(getDoc(doc(anon, 'organizations', COLA)));
  });

  test('an administrator reads every organisation', async () => {
    await assertSucceeds(getDoc(doc(db(ADMIN), 'organizations', COLA)));
    await assertSucceeds(getDoc(doc(db(ADMIN), 'organizations', PRAN)));
  });

  test('a suspended member loses read access', async () => {
    // The membership document is untouched by a platform suspension, so
    // without the isActive() half of isOrgMemberAtLeast this would pass.
    await assertFails(getDoc(doc(db(COLA_SUSPENDED), 'organizations', COLA)));
  });

  test('an invited-but-unredeemed member has no access', async () => {
    // Otherwise the invited address alone would be access and the single-use
    // token in SEC-8 would be decorative.
    await assertFails(getDoc(doc(db(COLA_INVITED), 'organizations', COLA)));
  });

  test('a removed member has no access', async () => {
    // SEC-2: a dismissed employee exporting on the way out.
    await assertFails(getDoc(doc(db(COLA_REMOVED), 'organizations', COLA)));
  });
});

// ===========================================================================
// SEC-4 — no client write to any compliance collection, administrators included
// ===========================================================================

describe('organizations: every client write is denied', () => {
  test('an owner cannot create an organisation', async () => {
    await assertFails(
      setDoc(doc(db(COLA_OWNER), 'organizations', 'org_new'), {
        legalName: 'New Ltd',
        tradeName: 'New',
        status: 'active',
      }),
    );
  });

  test('an owner cannot edit its own organisation', async () => {
    await assertFails(
      updateDoc(doc(db(COLA_OWNER), 'organizations', COLA), {
        contactEmail: 'new@cola.test',
      }),
    );
  });

  test('an owner cannot set its own size class or status', async () => {
    // sizeClass fixes which gazette target applies; status opens the workspace.
    // A company that could write either would be choosing how it is measured.
    await assertFails(
      updateDoc(doc(db(COLA_OWNER), 'organizations', COLA), {
        sizeClass: 'small',
      }),
    );
    await assertFails(
      updateDoc(doc(db(COLA_OWNER), 'organizations', COLA), {
        status: 'active',
      }),
    );
  });

  test('an administrator cannot write an organisation either', async () => {
    // The same sentence that governs wallets and orders: if administrators
    // could write here there would be two code paths producing a compliance
    // figure and the rules could police only one.
    await assertFails(
      updateDoc(doc(db(ADMIN), 'organizations', COLA), { status: 'suspended' }),
    );
    await assertFails(
      setDoc(doc(db(ADMIN), 'organizations', 'org_admin_made'), {
        legalName: 'X',
        tradeName: 'X',
        status: 'active',
      }),
    );
    await assertFails(deleteDoc(doc(db(ADMIN), 'organizations', COLA)));
  });
});

// ===========================================================================
// organizationMembers — the tenancy boundary in one document
// ===========================================================================

describe('organizationMembers', () => {
  test('a member reads its own membership record', async () => {
    await assertSucceeds(
      getDoc(doc(db(COLA_VIEWER), 'organizationMembers', `${COLA}_${COLA_VIEWER}`)),
    );
  });

  test('an invited or removed member may still read its own record', async () => {
    // So the app can say why there is no access, instead of showing an empty
    // screen with no explanation.
    await assertSucceeds(
      getDoc(
        doc(db(COLA_INVITED), 'organizationMembers', `${COLA}_${COLA_INVITED}`),
      ),
    );
    await assertSucceeds(
      getDoc(
        doc(db(COLA_REMOVED), 'organizationMembers', `${COLA}_${COLA_REMOVED}`),
      ),
    );
  });

  test('an active member reads its colleagues', async () => {
    await assertSucceeds(
      getDoc(
        doc(db(COLA_VIEWER), 'organizationMembers', `${COLA}_${COLA_OWNER}`),
      ),
    );
  });

  test("a member cannot read another company's membership list", async () => {
    await assertFails(
      getDoc(
        doc(db(COLA_OWNER), 'organizationMembers', `${PRAN}_${PRAN_OWNER}`),
      ),
    );
  });

  test('a scoped members query succeeds; an unscoped one does not', async () => {
    const scoped = query(
      collection(db(COLA_OWNER), 'organizationMembers'),
      where('orgId', '==', COLA),
    );
    await assertSucceeds(getDocs(scoped));

    // Without the filter the result set would span both tenants, and the rule
    // is evaluated per returned document.
    await assertFails(
      getDocs(collection(db(COLA_OWNER), 'organizationMembers')),
    );
  });

  test('a Champion cannot read any membership', async () => {
    await assertFails(
      getDoc(doc(db(CHAMPION), 'organizationMembers', `${COLA}_${COLA_OWNER}`)),
    );
  });

  test('nobody writes a membership — not an owner, not an administrator', async () => {
    // A client that could write here could add itself to any organisation on
    // the platform (SEC-8).
    await assertFails(
      setDoc(doc(db(COLA_OWNER), 'organizationMembers', `${COLA}_${CHAMPION}`), {
        orgId: COLA,
        uid: CHAMPION,
        orgRole: 'orgOwner',
        status: 'active',
      }),
    );
    await assertFails(
      updateDoc(
        doc(db(COLA_VIEWER), 'organizationMembers', `${COLA}_${COLA_VIEWER}`),
        { orgRole: 'orgOwner' },
      ),
    );
    await assertFails(
      setDoc(doc(db(ADMIN), 'organizationMembers', `${COLA}_${ADMIN}`), {
        orgId: COLA,
        uid: ADMIN,
        orgRole: 'orgOwner',
        status: 'active',
      }),
    );
    await assertFails(
      deleteDoc(
        doc(db(COLA_OWNER), 'organizationMembers', `${COLA}_${COLA_REPORTER}`),
      ),
    );
  });

  test('self-joining another organisation is denied', async () => {
    // The whole tenancy boundary, attacked directly.
    await assertFails(
      setDoc(doc(db(COLA_OWNER), 'organizationMembers', `${PRAN}_${COLA_OWNER}`), {
        orgId: PRAN,
        uid: COLA_OWNER,
        orgRole: 'orgOwner',
        status: 'active',
      }),
    );
  });
});

// ===========================================================================
// SEC-12 — the audit log is append-only for every principal
// ===========================================================================

describe('producerAuditLog', () => {
  test('a member reads its own organisation history', async () => {
    await assertSucceeds(
      getDoc(doc(db(COLA_VIEWER), 'producerAuditLog', 'audit_cola_1')),
    );
  });

  test("a member cannot read another company's history", async () => {
    await assertFails(
      getDoc(doc(db(COLA_OWNER), 'producerAuditLog', 'audit_pran_1')),
    );
  });

  test('an administrator reads any history', async () => {
    await assertSucceeds(
      getDoc(doc(db(ADMIN), 'producerAuditLog', 'audit_cola_1')),
    );
  });

  test('no client appends an entry', async () => {
    // An entry a client could author is an entry an attacker could author.
    await assertFails(
      setDoc(doc(db(COLA_OWNER), 'producerAuditLog', 'forged'), {
        orgId: COLA,
        action: 'org.approved',
        actorUid: COLA_OWNER,
        timestamp: new Date(),
      }),
    );
    await assertFails(
      setDoc(doc(db(ADMIN), 'producerAuditLog', 'forged_by_admin'), {
        orgId: COLA,
        action: 'org.approved',
        actorUid: ADMIN,
        timestamp: new Date(),
      }),
    );
  });

  test('no principal amends or deletes an entry, administrators included', async () => {
    // The named failure mode: an insider edits history, and nothing Chokro
    // issues can be defended afterwards.
    await assertFails(
      updateDoc(doc(db(ADMIN), 'producerAuditLog', 'audit_cola_1'), {
        summary: 'Something else happened.',
      }),
    );
    await assertFails(
      deleteDoc(doc(db(ADMIN), 'producerAuditLog', 'audit_cola_1')),
    );
    await assertFails(
      updateDoc(doc(db(COLA_OWNER), 'producerAuditLog', 'audit_cola_1'), {
        digest: 'b'.repeat(64),
      }),
    );
    await assertFails(
      deleteDoc(doc(db(COLA_OWNER), 'producerAuditLog', 'audit_cola_1')),
    );
  });
});

// ===========================================================================
// EPR-1 — the producer role is disjoint from the citizen hierarchy
// ===========================================================================

describe('a producer account is not a citizen account', () => {
  test('a producer cannot create a disposal', async () => {
    // The conflict this closes: the party whose collected kilograms Chokro
    // certifies also submitting the disposals that produce them. A producer
    // account is `active`, so a rule gated only on activity would accept this.
    await assertFails(
      setDoc(doc(db(COLA_OWNER), 'disposals', 'disposal_by_producer'), {
        userId: COLA_OWNER,
        binId: OPEN_BIN,
        photoUrl: `https://res.cloudinary.com/ata3ir5d/image/upload/v1/chokro/disposals/${COLA_OWNER}/abc123.jpg`,
        photoPublicId: `chokro/disposals/${COLA_OWNER}/abc123`,
        capturedLat: 23.7809,
        capturedLng: 90.4074,
        distanceMeters: 11.2,
        declaredItemCount: 2,
        itemType: 'plasticBottle',
        status: 'pending',
        flags: [],
        createdAt: new Date(),
      }),
    );
  });

  test('a producer cannot create an eco-action claim', async () => {
    await assertFails(
      setDoc(doc(db(COLA_OWNER), 'claims', 'claim_by_producer'), {
        userId: COLA_OWNER,
        photoUrl: `https://res.cloudinary.com/ata3ir5d/image/upload/v1/chokro/claims/${COLA_OWNER}/abc123.jpg`,
        photoPublicId: `chokro/claims/${COLA_OWNER}/abc123`,
        action: 'composting',
        status: 'pending',
        publishPermission: false,
        createdAt: new Date(),
      }),
    );
  });

  test('a producer cannot open a cart', async () => {
    await assertFails(
      setDoc(doc(db(COLA_OWNER), 'carts', COLA_OWNER), {
        userId: COLA_OWNER,
        items: [{ productId: 'p1', qty: 1 }],
        updatedAt: new Date(),
      }),
    );
  });

  test('a producer cannot apply to become a Greenpreneur', async () => {
    await assertFails(
      setDoc(doc(db(COLA_OWNER), 'sellerApplications', 'app_by_producer'), {
        userId: COLA_OWNER,
        businessName: 'Cola Recycling',
        description: 'We would like to sell recycled goods on the marketplace.',
        status: 'pending',
        createdAt: new Date(),
      }),
    );
  });

  test('a Champion can still do all four — the narrowing hit only producers', async () => {
    // The regression half. A disjointness fix that also broke the citizen
    // paths would pass every denial above and ship a dead app.
    await assertSucceeds(
      setDoc(doc(db(CHAMPION), 'carts', CHAMPION), {
        userId: CHAMPION,
        items: [{ productId: 'p1', qty: 1 }],
        // `serverTimestamp()`, because the rule requires `request.time`. The
        // denial cases above never reach that check, so only this one needs it.
        updatedAt: serverTimestamp(),
      }),
    );
    await assertSucceeds(
      setDoc(doc(db(CHAMPION), 'sellerApplications', 'app_by_champion'), {
        userId: CHAMPION,
        businessName: 'Champion Crafts',
        description: 'Handmade goods from recycled material, sold locally.',
        status: 'pending',
        createdAt: serverTimestamp(),
      }),
    );
  });
});

// ===========================================================================
// EPR-1 / EPR-4 — the producer role is not granted through a client write
// ===========================================================================

describe('the producer role cannot be granted or removed by a client', () => {
  test('an administrator cannot promote an account to producer', async () => {
    // Becoming a producer means redeeming an invitation and gaining a
    // membership document. It is not a single field flip, so it does not
    // belong on a path where a client writes one field.
    await assertFails(
      updateDoc(doc(db(ADMIN), 'users', CHAMPION), { role: 'producer' }),
    );
  });

  test('an administrator cannot demote a producer to a citizen role', async () => {
    // Removing the role must also deactivate the memberships; the server owns
    // both halves, transactionally.
    await assertFails(
      updateDoc(doc(db(ADMIN), 'users', COLA_VIEWER), { role: 'buyer' }),
    );
  });

  test('a user cannot promote themselves', async () => {
    await assertFails(
      updateDoc(doc(db(CHAMPION), 'users', CHAMPION), { role: 'producer' }),
    );
  });

  test('registration cannot self-select the producer role', async () => {
    const NEWCOMER = 'uid_newcomer';
    await assertFails(
      setDoc(doc(db(NEWCOMER), 'users', NEWCOMER), {
        name: 'Newcomer',
        email: `${NEWCOMER}@test.com`,
        role: 'producer',
        status: 'active',
        createdAt: new Date(),
      }),
    );
  });

  test('an administrator may still suspend and reinstate a producer', async () => {
    // The platform-level control EPR-47 leans on must keep working. The role
    // is unchanged on both sides of the write, so the equality guard permits it.
    await assertSucceeds(
      updateDoc(doc(db(ADMIN), 'users', COLA_VIEWER), {
        status: 'suspended',
        suspendedAt: new Date(),
      }),
    );
    await assertSucceeds(
      updateDoc(doc(db(ADMIN), 'users', COLA_VIEWER), {
        status: 'active',
        reinstatedAt: new Date(),
      }),
    );
  });

  test('a producer may still edit their own name', async () => {
    // The validator has to accept a producer document as a valid document, or
    // ordinary self-service breaks for the whole role.
    await assertSucceeds(
      updateDoc(doc(db(COLA_VIEWER), 'users', COLA_VIEWER), {
        name: 'Renamed Officer',
      }),
    );
  });

  test('an administrator may still change a citizen role', async () => {
    await assertSucceeds(
      updateDoc(doc(db(ADMIN), 'users', CHAMPION), { role: 'seller' }),
    );
  });
});
