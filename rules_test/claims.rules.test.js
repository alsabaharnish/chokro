/**
 * Chokro — security rules tests for self-reported claims (F6.1–F6.4).
 *
 * Own `projectId`: suites sharing one run against the same emulator namespace
 * in parallel and clear each other's seed data mid-test.
 *
 * The property under test is the same one that governs disposals — the client
 * may create a pending record and may do nothing else — with one addition
 * specific to this route: `claimQuotas` is server-owned, because the quota is
 * the only real safeguard a claim has and a client that could write it could
 * lift its own limit.
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
  updateDoc,
  deleteDoc,
  doc,
  collection,
  query,
  where,
  orderBy,
  limit,
  getDocs,
  serverTimestamp,
  setLogLevel,
} = require('firebase/firestore');

let testEnv;

const ALICE = 'alice_uid';
const BOB = 'bob_uid';
const ADMIN = 'admin_uid';

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

async function seedClaim(claimId, uid, status = 'pending') {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'claims', claimId), {
      userId: uid,
      actionType: 'treePlanting',
      photoUrl: `https://res.cloudinary.com/chokro-test/image/upload/v1/chokro/claims/${uid}/abc123.jpg`,
      photoPublicId: `chokro/claims/${uid}/abc123`,
      status,
      createdAt: new Date(),
    });
  });
}

function profilePhoto(uid) {
  return {
    url:
      `https://res.cloudinary.com/chokro-test/image/upload/v1/` +
      `chokro/profiles/${uid}/portrait.jpg`,
    publicId: `chokro/profiles/${uid}/portrait`,
  };
}

async function seedProfilePhoto(uid) {
  const photo = profilePhoto(uid);
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await updateDoc(doc(ctx.firestore(), 'users', uid), {
      profilePhotoUrl: photo.url,
      profilePhotoPublicId: photo.publicId,
    });
  });
  return photo;
}

/** A claim payload satisfying every rule, so a failure names one constraint. */
function validClaim(uid) {
  return {
    userId: uid,
    actionType: 'treePlanting',
    photoUrl: `https://res.cloudinary.com/chokro-test/image/upload/v1/chokro/claims/${uid}/abc123.jpg`,
    photoPublicId: `chokro/claims/${uid}/abc123`,
    status: 'pending',
    createdAt: serverTimestamp(),
  };
}

beforeAll(async () => {
  setLogLevel('error');
  testEnv = await initializeTestEnvironment({
    projectId: 'chokro-rules-test-claims',
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
  await seedUser(ADMIN, 'admin');
  await seedUser(ALICE, 'buyer');
  await seedUser(BOB, 'buyer');
});

describe('creating a claim', () => {
  it('an older client may create its legacy shape without publication permission', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertSucceeds(setDoc(doc(db, 'claims', 'c1'), validClaim(ALICE)));
  });

  it('accepts a bounded story with an explicit anonymous choice', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertSucceeds(
      setDoc(doc(db, 'claims', 'c1a'), {
        ...validClaim(ALICE),
        story: 'I started composting with my neighbours.',
        publicationMode: 'anonymous',
      }),
    );
  });

  it('accepts named publication only with the current profile snapshot', async () => {
    const photo = await seedProfilePhoto(ALICE);
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertSucceeds(
      setDoc(doc(db, 'claims', 'c1b'), {
        ...validClaim(ALICE),
        story: 'A small cleanup became a weekly habit.',
        publicationMode: 'named',
        championName: ALICE,
        championPhotoUrl: photo.url,
      }),
    );
  });

  it('refuses named publication when the user has no saved profile picture', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'claims', 'c1-no-profile'), {
        ...validClaim(ALICE),
        publicationMode: 'named',
        championName: ALICE,
        championPhotoUrl: profilePhoto(ALICE).url,
      }),
    );
  });

  it("refuses another user's saved profile picture", async () => {
    const bobPhoto = await seedProfilePhoto(BOB);
    await seedProfilePhoto(ALICE);
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'claims', 'c1-other-profile'), {
        ...validClaim(ALICE),
        publicationMode: 'named',
        championName: ALICE,
        championPhotoUrl: bobPhoto.url,
      }),
    );
  });

  it('refuses spoofed, partial, or anonymous identity snapshots', async () => {
    const photo = await seedProfilePhoto(ALICE);
    const db = testEnv.authenticatedContext(ALICE).firestore();

    await assertFails(
      setDoc(doc(db, 'claims', 'c1c'), {
        ...validClaim(ALICE),
        publicationMode: 'named',
        championName: 'Somebody Else',
        championPhotoUrl: photo.url,
      }),
    );
    await assertFails(
      setDoc(doc(db, 'claims', 'c1d'), {
        ...validClaim(ALICE),
        publicationMode: 'named',
        championName: ALICE,
      }),
    );
    await assertFails(
      setDoc(doc(db, 'claims', 'c1e'), {
        ...validClaim(ALICE),
        publicationMode: 'anonymous',
        championName: ALICE,
        championPhotoUrl: photo.url,
      }),
    );
  });

  it('bounds and trims story text and closes the publication enum', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    for (const [id, change] of [
      ['c1f', { story: 'x'.repeat(801), publicationMode: 'anonymous' }],
      ['c1g', { story: 7, publicationMode: 'anonymous' }],
      ['c1h', { story: ' padded ', publicationMode: 'anonymous' }],
      ['c1i', { publicationMode: 'public' }],
    ]) {
      await assertFails(
        setDoc(doc(db, 'claims', id), { ...validClaim(ALICE), ...change }),
      );
    }
  });

  it('a user may not create a claim for someone else', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(setDoc(doc(db, 'claims', 'c2'), validClaim(BOB)));
  });

  it('an anonymous caller may not create a claim', async () => {
    const db = testEnv.unauthenticatedContext().firestore();
    await assertFails(setDoc(doc(db, 'claims', 'c3'), validClaim(ALICE)));
  });

  it('a suspended user may not create a claim', async () => {
    await seedUser('susp_uid', 'buyer', 'suspended');
    const db = testEnv.authenticatedContext('susp_uid').firestore();
    await assertFails(setDoc(doc(db, 'claims', 'c4'), validClaim('susp_uid')));
  });

  it('a claim cannot arrive already approved', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'claims', 'c5'), {
        ...validClaim(ALICE),
        status: 'approved',
      }),
    );
  });

  it('a claim cannot arrive carrying its own points', async () => {
    // hasOnly is what keeps every server-owned field out. Without it, a
    // modified client could name its own award.
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'claims', 'c6'), {
        ...validClaim(ALICE),
        pointsAwarded: 5000,
      }),
    );
  });

  it('a claim cannot arrive with a client-computed hash', async () => {
    // A client-supplied fingerprint is worthless — a modified app would send a
    // fresh random value every time and duplicate detection would never fire.
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'claims', 'c7'), {
        ...validClaim(ALICE),
        photoHash: 'deadbeefdeadbeef',
      }),
    );
  });

  it('a claim cannot name its own reviewer', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'claims', 'c8'), {
        ...validClaim(ALICE),
        reviewedBy: ADMIN,
      }),
    );
  });

  it('an unrecognised action type is refused', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'claims', 'c9'), {
        ...validClaim(ALICE),
        actionType: 'somethingInvented',
      }),
    );
  });

  it('accepts the refusing-single-use-plastic action used by Dart', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertSucceeds(
      setDoc(doc(db, 'claims', 'c9b'), {
        ...validClaim(ALICE),
        actionType: 'refusingSingleUsePlastic',
      }),
    );
  });

  it('a client-authored createdAt is refused', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'claims', 'c10'), {
        ...validClaim(ALICE),
        createdAt: new Date(2020, 0, 1),
      }),
    );
  });

  it('a missing required field is refused', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    const { photoUrl, ...withoutPhoto } = validClaim(ALICE);
    expect(photoUrl).toBeTruthy();
    await assertFails(setDoc(doc(db, 'claims', 'c11'), withoutPhoto));
  });

  it('a claim cannot point at another user or disposal photo folder', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'claims', 'c12'), {
        ...validClaim(ALICE),
        photoPublicId: `chokro/claims/${BOB}/abc123`,
      }),
    );
    await assertFails(
      setDoc(doc(db, 'claims', 'c13'), {
        ...validClaim(ALICE),
        photoPublicId: `chokro/disposals/${ALICE}/abc123`,
      }),
    );
  });
});

describe('approved photocard query', () => {
  it('lets an active admin list newest approvals with a bounded query', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      for (const [id, reviewedAt] of [
        ['approved-old', new Date('2026-01-01T00:00:00Z')],
        ['approved-new', new Date('2026-02-01T00:00:00Z')],
      ]) {
        await setDoc(doc(ctx.firestore(), 'claims', id), {
          ...validClaim(ALICE),
          createdAt: new Date('2025-12-01T00:00:00Z'),
          status: 'approved',
          reviewedAt,
          reviewedBy: ADMIN,
          pointsAwarded: 15,
          publicationMode: 'anonymous',
        });
      }
    });

    const db = testEnv.authenticatedContext(ADMIN).firestore();
    const approved = query(
      collection(db, 'claims'),
      where('status', '==', 'approved'),
      orderBy('reviewedAt', 'desc'),
      limit(50),
    );
    const snapshot = await assertSucceeds(getDocs(approved));
    expect(snapshot.docs.map((item) => item.id)).toEqual([
      'approved-new',
      'approved-old',
    ]);
  });
});

describe('reading claims', () => {
  it('a user may read their own claim', async () => {
    await seedClaim('c20', ALICE);
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertSucceeds(
      getDoc(doc(db, 'claims', 'c20')),
    );
  });

  it('a user may not read someone else\u2019s claim', async () => {
    await seedClaim('c21', BOB);
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      getDoc(doc(db, 'claims', 'c21')),
    );
  });

  it('an admin may read any claim', async () => {
    await seedClaim('c22', BOB);
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertSucceeds(
      getDoc(doc(db, 'claims', 'c22')),
    );
  });
});

describe('deciding a claim', () => {
  it('a user may not approve their own claim', async () => {
    await seedClaim('c30', ALICE);
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      updateDoc(doc(db, 'claims', 'c30'), { status: 'approved' }),
    );
  });

  it('AN ADMIN MAY NOT APPROVE A CLAIM FROM THE CLIENT', async () => {
    // The property that matters most. Approval is a payout decision, so it
    // goes through the server like every other one — even for an admin.
    await seedClaim('c31', ALICE);
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertFails(
      updateDoc(doc(db, 'claims', 'c31'), {
        status: 'approved',
        pointsAwarded: 15,
      }),
    );
  });

  it('nobody may delete a claim', async () => {
    await seedClaim('c32', ALICE);
    const adminDb = testEnv.authenticatedContext(ADMIN).firestore();
    const userDb = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(deleteDoc(doc(adminDb, 'claims', 'c32')));
    await assertFails(deleteDoc(doc(userDb, 'claims', 'c32')));
  });
});

describe('the quota is server-owned', () => {
  it('a user may read their own quota', async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertSucceeds(
      getDoc(doc(db, 'claimQuotas', `${ALICE}_2026-W31`)),
    );
  });

  it("a user may not read another user's quota", async () => {
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      getDoc(doc(db, 'claimQuotas', `${BOB}_2026-W31`)),
    );
  });

  it('a user may not write their own quota', async () => {
    // Without a geofence the rate limit *is* the safeguard, so a client that
    // could edit this could lift its own limit.
    const db = testEnv.authenticatedContext(ALICE).firestore();
    await assertFails(
      setDoc(doc(db, 'claimQuotas', `${ALICE}_2026-W31`), { count: 0 }),
    );
  });

  it('an admin may not write a quota either', async () => {
    const db = testEnv.authenticatedContext(ADMIN).firestore();
    await assertFails(
      setDoc(doc(db, 'claimQuotas', `${ALICE}_2026-W31`), { count: 0 }),
    );
  });
});
