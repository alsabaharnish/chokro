// Firestore security rules, exercised against the emulator.
//
// Run serially. Jest defaults to one worker per test file, and all four suites
// here share a single emulator and a single projectId — so one file's
// `clearFirestore()` in `beforeEach` wipes the documents another file has just
// seeded, mid-test. That produced failures that moved between runs and between
// files, including in suites nobody had touched. `npm test` now passes
// `--runInBand`; isolating them properly would mean a projectId per file.

const fs = require('fs');
const path = require('path');
const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');

const { setDoc, getDoc, updateDoc, doc, serverTimestamp, setLogLevel } =
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
        createdAt: serverTimestamp(),
      }),
    );
  });

  test('a user can register as buyer', async () => {
    const db = testEnv.authenticatedContext(ALICE, {
      email: 'alice@test.com',
    }).firestore();
    await assertSucceeds(
      setDoc(doc(db, 'users', ALICE), {
        name: 'Alice',
        email: 'alice@test.com',
        role: 'buyer',
        status: 'active',
        createdAt: serverTimestamp(),
      }),
    );
  });

  test('registration cannot inject a profile picture', async () => {
    const db = testEnv.authenticatedContext(ALICE, {
      email: 'alice@test.com',
    }).firestore();
    await assertFails(
      setDoc(doc(db, 'users', ALICE), {
        name: 'Alice',
        email: 'alice@test.com',
        role: 'buyer',
        status: 'active',
        createdAt: serverTimestamp(),
        profilePhotoUrl:
          `https://res.cloudinary.com/chokro-test/image/upload/v1/` +
          `chokro/profiles/${ALICE}/portrait.jpg`,
        profilePhotoPublicId: `chokro/profiles/${ALICE}/portrait`,
      }),
    );
  });

  test('a user cannot put a different email in their profile', async () => {
    const db = testEnv.authenticatedContext(ALICE, {
      email: 'alice@test.com',
    }).firestore();
    await assertFails(
      setDoc(doc(db, 'users', ALICE), {
        name: 'Alice',
        email: 'someone-else@test.com',
        role: 'buyer',
        status: 'active',
        createdAt: serverTimestamp(),
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

  // ── profile management (F1.1) ──────────────────────────────────────────────
  //
  // The rename permission these cover was deployed long before anything in the
  // app could reach it. The suite tested every way a self-update must fail and
  // never the one way it must succeed, so nothing would have caught the rule
  // being tightened out from under the feature.

  test('a user can change their own name', async () => {
    await seedUser(ALICE, 'buyer');
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertSucceeds(
      updateDoc(doc(db, 'users', ALICE), { name: 'Alice Rahman' }),
    );
  });

  test('a client cannot attach or replace its own profile image reference', async () => {
    await seedUser(ALICE, 'buyer');
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, 'users', ALICE), {
        profilePhotoUrl:
          `https://res.cloudinary.com/chokro-test/image/upload/v1/` +
          `chokro/profiles/${ALICE}/portrait.jpg`,
        profilePhotoPublicId: `chokro/profiles/${ALICE}/portrait`,
      }),
    );
  });

  test('trusted profile fields do not break later rename or admin updates', async () => {
    await seedUser(ALICE, 'buyer');
    await seedUser(ADMIN, 'admin');
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await updateDoc(doc(ctx.firestore(), 'users', ALICE), {
        profilePhotoUrl:
          `https://res.cloudinary.com/chokro-test/image/upload/v1/` +
          `chokro/profiles/${ALICE}/portrait.jpg`,
        profilePhotoPublicId: `chokro/profiles/${ALICE}/portrait`,
      });
    });

    const aliceDb = testEnv.authenticatedContext(ALICE).firestore();
    const adminDb = testEnv.authenticatedContext(ADMIN).firestore();
    await assertSucceeds(
      updateDoc(doc(aliceDb, 'users', ALICE), { name: 'Alice Rahman' }),
    );
    await assertSucceeds(
      updateDoc(doc(adminDb, 'users', ALICE), { role: 'seller' }),
    );
  });

  test('a user cannot rename someone else', async () => {
    await seedUser(ALICE, 'buyer');
    await seedUser(BOB, 'buyer');
    const db = testEnv.authenticatedContext(BOB).firestore();
    await assertFails(
      updateDoc(doc(db, 'users', ALICE), { name: 'Not Alice' }),
    );
  });

  test('a rename carrying any companion field is refused', async () => {
    // `hasOnly(['name'])` means the diff may contain nothing else, so the
    // reflexive `updatedAt` alongside a write like this would fail every rename
    // — and the failure reads as permission-denied, which looks like a broken
    // rule rather than an extra field. `UserService.updateName` writes the one
    // key on purpose; this is what keeps that honest.
    await seedUser(ALICE, 'buyer');
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, 'users', ALICE), {
        name: 'Alice Rahman',
        updatedAt: serverTimestamp(),
      }),
    );
  });

  test('a rename smuggling a role change is refused', async () => {
    await seedUser(ALICE, 'buyer');
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, 'users', ALICE), {
        name: 'Alice Rahman',
        role: 'admin',
      }),
    );
  });

  test('a suspended user may still change their own name', async () => {
    // Deliberately asserting the rule as written: the self-update branch checks
    // `isSelf` and the affected keys, and does *not* call `isActive()`. A
    // suspension withholds submitting and claiming, not the spelling of a name.
    // Pinned here because the app tells the user which of those is true.
    await seedUser(ALICE, 'buyer', 'suspended');
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertSucceeds(
      updateDoc(doc(db, 'users', ALICE), { name: 'Alice Rahman' }),
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
        updatedAt: serverTimestamp(),
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
        createdAt: serverTimestamp(),
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
        createdAt: serverTimestamp(),
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
        reviewedAt: serverTimestamp(),
      }),
    );
  });
});

// ── catch-all ───────────────────────────────────────────────────────────────

describe('unmatched collections', () => {
  test('a Champion cannot write a donation receipt or debit', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'donations', 'alice_request'), {
        userId: ALICE,
        initiative: 'treePlanting',
        points: 100,
        balanceAfter: 200,
        status: 'received',
        createdAt: serverTimestamp(),
      }),
    );
  });

  test('a donation receipt stays server-only', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'donations', 'alice_request'), {
        userId: ALICE,
        initiative: 'treePlanting',
        points: 100,
        balanceAfter: 200,
        status: 'received',
        createdAt: new Date(),
      });
    });
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(getDoc(doc(db, 'donations', 'alice_request')));
  });

  test('a collection with no rule is denied', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'disposals', 'd1'), { userId: ALICE }),
    );
  });
});
