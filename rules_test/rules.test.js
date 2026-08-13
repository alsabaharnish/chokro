const fs = require('fs');
const path = require('path');
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');

const { setDoc, getDoc, updateDoc, doc, setLogLevel } =
  require('firebase/firestore');

let testEnv;

const ALICE = 'alice_uid';
const BOB = 'bob_uid';
const ADMIN = 'admin_uid';

// helper: seed a user document bypassing rules
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

beforeAll(async () => {
  setLogLevel('error');
  testEnv = await initializeTestEnvironment({
    projectId: 'chokro-rules-test-m2',
    firestore: {
      rules: fs.readFileSync(
        path.resolve(__dirname, '../firestore.rules'),
        'utf8',
      ),
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
});

// ── users ───────────────────────────────────────────────────────────────────

describe('users', () => {
  test('a user cannot register themselves as admin', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'users', ALICE), {
        name: 'Alice',
        email: 'alice@test.com',
        role: 'admin',
        status: 'active',
        createdAt: new Date(),
      }),
    );
  });

  test('a user can register as buyer', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertSucceeds(
      setDoc(doc(db, 'users', ALICE), {
        name: 'Alice',
        email: 'alice@test.com',
        role: 'buyer',
        status: 'active',
        createdAt: new Date(),
      }),
    );
  });

  test('a user cannot promote their own role', async () => {
    await seedUser(ALICE, 'buyer');
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, 'users', ALICE), { role: 'seller' }),
    );
  });

  test('a user cannot un-suspend themselves', async () => {
    await seedUser(ALICE, 'buyer', 'suspended');
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, 'users', ALICE), { status: 'active' }),
    );
  });

  test('a user cannot read another user profile', async () => {
    await seedUser(ALICE, 'buyer');
    await seedUser(BOB, 'buyer');
    const db = testEnv.authenticatedContext(BOB).firestore();
    await assertFails(getDoc(doc(db, 'users', ALICE)));
  });

  test('an admin can read any user profile', async () => {
    await seedUser(ALICE, 'buyer');
    await seedUser(ADMIN, 'admin');
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertSucceeds(getDoc(doc(db, 'users', ALICE)));
  });

  test('an admin can change a user role', async () => {
    await seedUser(ALICE, 'buyer');
    await seedUser(ADMIN, 'admin');
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertSucceeds(
      updateDoc(doc(db, 'users', ALICE), { role: 'seller' }),
    );
  });
});

// ── wallets ─────────────────────────────────────────────────────────────────

describe('wallets', () => {
  test('a wallet must be created with a zero balance', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'wallets', ALICE), {
        userId: ALICE,
        balance: 5000,
        updatedAt: new Date(),
      }),
    );
  });

  test('a wallet can be created at zero', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertSucceeds(
      setDoc(doc(db, 'wallets', ALICE), {
        userId: ALICE,
        balance: 0,
        updatedAt: new Date(),
      }),
    );
  });

  test('a user cannot write their own balance', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'wallets', ALICE), {
        userId: ALICE,
        balance: 0,
        updatedAt: new Date(),
      });
    });
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, 'wallets', ALICE), { balance: 9999 }),
    );
  });

  test('a user cannot read another wallet', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'wallets', ALICE), {
        userId: ALICE,
        balance: 0,
        updatedAt: new Date(),
      });
    });
    const db = testEnv.authenticatedContext(BOB).firestore();
    await assertFails(getDoc(doc(db, 'wallets', ALICE)));
  });
});

// ── seller applications ─────────────────────────────────────────────────────

describe('sellerApplications', () => {
  test('a suspended user cannot apply', async () => {
    await seedUser(ALICE, 'buyer', 'suspended');
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'sellerApplications', 'app1'), {
        userId: ALICE,
        businessName: 'Test',
        description: 'A description long enough',
        status: 'pending',
        createdAt: new Date(),
      }),
    );
  });

  test('a user cannot apply on behalf of someone else', async () => {
    await seedUser(ALICE, 'buyer');
    await seedUser(BOB, 'buyer');
    const db = testEnv.authenticatedContext(BOB).firestore();
    await assertFails(
      setDoc(doc(db, 'sellerApplications', 'app1'), {
        userId: ALICE,
        businessName: 'Test',
        description: 'A description long enough',
        status: 'pending',
        createdAt: new Date(),
      }),
    );
  });

  test('a user cannot self-approve their application', async () => {
    await seedUser(ALICE, 'buyer');
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'sellerApplications', 'app1'), {
        userId: ALICE,
        businessName: 'Test',
        description: 'A description long enough',
        status: 'pending',
        createdAt: new Date(),
      });
    });
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, 'sellerApplications', 'app1'), {
        status: 'approved',
      }),
    );
  });

  test('an admin can approve an application', async () => {
    await seedUser(ALICE, 'buyer');
    await seedUser(ADMIN, 'admin');
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'sellerApplications', 'app1'), {
        userId: ALICE,
        businessName: 'Test',
        description: 'A description long enough',
        status: 'pending',
        createdAt: new Date(),
      });
    });
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertSucceeds(
      updateDoc(doc(db, 'sellerApplications', 'app1'), {
        status: 'approved',
        reviewedBy: ADMIN,
        reviewedAt: new Date(),
      }),
    );
  });
});

// ── catch-all ───────────────────────────────────────────────────────────────

describe('unmatched collections', () => {
  test('a collection with no rule is denied', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'disposals', 'd1'), { userId: ALICE }),
    );
  });
});
