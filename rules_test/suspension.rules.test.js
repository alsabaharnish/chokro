/**
 * Chokro — security rules tests for suspension and lazy expiry (F5.2, F5.3).
 *
 * Own `projectId`. Suites that share one run against the same emulator
 * namespace in parallel and clear each other's seed data mid-test.
 *
 * The property under test: a temporary suspension is over when
 * `suspendedUntil` is in the past, decided at request time by the rules
 * themselves. Nothing rewrites `status` when the date passes, because nothing
 * is running that could — there is no scheduler in this system.
 *
 * The mirror of this logic lives in `UserModel.isActiveAt`. If these tests pass
 * and the Dart tests pass, the two agree.
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
  updateDoc,
  doc,
  serverTimestamp,
  setLogLevel,
} = require('firebase/firestore');

let testEnv;

const ALICE = 'alice_uid';
const BOB = 'bob_uid';
const ADMIN = 'admin_uid';
const OPEN_BIN = 'bin_open';

const HOUR = 60 * 60 * 1000;

// ---------------------------------------------------------------------------
// Seeds — rules disabled, so they establish state without asserting anything
// ---------------------------------------------------------------------------

async function seedUser(uid, role, status = 'active', suspendedUntil = undefined) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    const data = {
      name: uid,
      email: `${uid}@test.com`,
      role,
      status,
      createdAt: new Date(),
    };
    if (suspendedUntil !== undefined) data.suspendedUntil = suspendedUntil;
    await setDoc(doc(ctx.firestore(), 'users', uid), data);
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

/** A disposal payload that satisfies every other constraint, so a failure
 *  points at the suspension check and nothing else. */
function validDisposal(uid, binId = OPEN_BIN) {
  return {
    userId: uid,
    binId,
    photoUrl: 'https://storage.example/p.jpg',
    photoPublicId: 'chokro/disposals/test/abc123',
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

beforeAll(async () => {
  setLogLevel('error');
  testEnv = await initializeTestEnvironment({
    projectId: 'chokro-rules-test-suspension',
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
  await seedBin(OPEN_BIN);
  await seedUser(ADMIN, 'admin');
});

// ---------------------------------------------------------------------------
// The expiry itself
// ---------------------------------------------------------------------------

describe('lazy suspension expiry', () => {
  it('an active user may submit a disposal', async () => {
    await seedUser(ALICE, 'buyer', 'active');
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertSucceeds(
      setDoc(doc(db, 'disposals', 'd1'), validDisposal(ALICE)),
    );
  });

  it('an indefinitely suspended user may not submit', async () => {
    await seedUser(ALICE, 'buyer', 'suspended');
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'disposals', 'd2'), validDisposal(ALICE)),
    );
  });

  it('a suspension ending in the future still blocks', async () => {
    await seedUser(ALICE, 'buyer', 'suspended', new Date(Date.now() + 24 * HOUR));
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'disposals', 'd3'), validDisposal(ALICE)),
    );
  });

  it('a suspension whose date has passed no longer blocks', async () => {
    // The load-bearing test. Status is still 'suspended' — nothing rewrote it —
    // and the user acts normally because the date is behind us.
    await seedUser(ALICE, 'buyer', 'suspended', new Date(Date.now() - HOUR));
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertSucceeds(
      setDoc(doc(db, 'disposals', 'd4'), validDisposal(ALICE)),
    );
  });

  it('an indefinite suspension never lapses, however long it has been', async () => {
    // suspendedUntil absent, not merely old. A missing date must not be read
    // as an expired one.
    await seedUser(ALICE, 'buyer', 'suspended');
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'disposals', 'd5'), validDisposal(ALICE)),
    );
  });

  it('the same expiry governs seller applications', async () => {
    await seedUser(ALICE, 'buyer', 'suspended', new Date(Date.now() - HOUR));
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertSucceeds(
      setDoc(doc(db, 'sellerApplications', 'app1'), {
        userId: ALICE,
        businessName: 'Test',
        description: 'Test',
        status: 'pending',
        createdAt: new Date(),
      }),
    );
  });

  it('a live suspension blocks seller applications too', async () => {
    await seedUser(ALICE, 'buyer', 'suspended', new Date(Date.now() + HOUR));
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'sellerApplications', 'app2'), {
        userId: ALICE,
        businessName: 'Test',
        description: 'Test',
        status: 'pending',
        createdAt: new Date(),
      }),
    );
  });
});

// ---------------------------------------------------------------------------
// Who may set a suspension
// ---------------------------------------------------------------------------

describe('writing a suspension', () => {
  it('an admin may suspend another user with an expiry', async () => {
    await seedUser(ALICE, 'buyer', 'active');
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertSucceeds(
      updateDoc(doc(db, 'users', ALICE), {
        status: 'suspended',
        suspendedUntil: new Date(Date.now() + 24 * HOUR),
        suspendedAt: new Date(),
      }),
    );
  });

  it('an admin may lift a suspension', async () => {
    await seedUser(ALICE, 'buyer', 'suspended', new Date(Date.now() + HOUR));
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertSucceeds(
      updateDoc(doc(db, 'users', ALICE), {
        status: 'active',
        reinstatedAt: new Date(),
      }),
    );
  });

  it('a user may not lift their own suspension', async () => {
    await seedUser(ALICE, 'buyer', 'suspended', new Date(Date.now() + HOUR));
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, 'users', ALICE), { status: 'active' }),
    );
  });

  it('a user may not shorten their own suspension', async () => {
    await seedUser(ALICE, 'buyer', 'suspended', new Date(Date.now() + 24 * HOUR));
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, 'users', ALICE), {
        suspendedUntil: new Date(Date.now() - HOUR),
      }),
    );
  });

  it('a non-admin may not suspend someone else', async () => {
    await seedUser(ALICE, 'buyer', 'active');
    await seedUser(BOB, 'buyer', 'active');
    const db = testEnv.authenticatedContext(BOB).firestore();
    await assertFails(
      updateDoc(doc(db, 'users', ALICE), {
        status: 'suspended',
        suspendedUntil: new Date(Date.now() + HOUR),
      }),
    );
  });

  it('a suspended admin cannot act as an admin', async () => {
    // isAdmin() reads role, not status, so this is worth pinning down: the
    // suspension has to bite on the write path, not on the role check.
    await seedUser('admin2_uid', 'admin', 'suspended');
    await seedUser(ALICE, 'buyer', 'active');
    const db = testEnv.authenticatedContext('admin2_uid').firestore();
    await assertFails(
      setDoc(doc(db, 'disposals', 'd6'), validDisposal('admin2_uid')),
    );
  });

  it('an admin may not edit unrelated fields through the suspension path',
    async () => {
      await seedUser(ALICE, 'buyer', 'active');
      const db = testEnv.authenticatedContext(ADMIN).firestore();
      await assertFails(
        updateDoc(doc(db, 'users', ALICE), {
          status: 'suspended',
          email: 'attacker@example.com',
        }),
      );
    });
});
