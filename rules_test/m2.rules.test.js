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
  serverTimestamp,
  setLogLevel,
} = require('firebase/firestore');

let testEnv;

const ALICE = 'alice_uid';
const BOB = 'bob_uid';
const ADMIN = 'admin_uid';

const OPEN_BIN = 'bin_open';
const CLOSED_BIN = 'bin_closed';

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

async function seedWallet(uid, balance = 0) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'wallets', uid), {
      userId: uid,
      balance,
      updatedAt: new Date(),
    });
  });
}

async function seedTransaction(txId, uid) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'transactions', txId), {
      userId: uid,
      delta: 50,
      source: 'disposal',
      refId: 'disposal_1',
      balanceAfter: 50,
      createdAt: new Date(),
    });
  });
}

async function seedDisposal(disposalId, uid, status = 'pending') {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'disposals', disposalId), {
      userId: uid,
      binId: OPEN_BIN,
      photoUrl: `https://res.cloudinary.com/chokro-test/image/upload/v1/chokro/disposals/${uid}/abc123.jpg`,
      photoPublicId: `chokro/disposals/${uid}/abc123`,
      capturedLat: 23.7809,
      capturedLng: 90.4074,
      distanceMeters: 11.2,
      declaredItemCount: 2,
      itemType: 'plasticBottle',
      status,
      flags: [],
      createdAt: new Date(),
    });
  });
}

async function seedLockout(uid, binId, expiresAt) {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'lockouts', `${uid}_${binId}`), {
      expiresAt,
    });
  });
}

async function seedConfig() {
  await testEnv.withSecurityRulesDisabled(async (ctx) => {
    await setDoc(doc(ctx.firestore(), 'config', 'points'), {
      disposalAward: 50,
      claimAward: 15,
    });
  });
}

/**
 * A disposal payload that satisfies every rule. Individual tests spread this
 * and override one field, so a failure points at exactly one constraint.
 */
function validDisposal(uid, binId = OPEN_BIN) {
  return {
    userId: uid,
    binId,
    photoUrl: `https://res.cloudinary.com/chokro-test/image/upload/v1/chokro/disposals/${uid}/abc123.jpg`,
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

function db(uid) {
  return testEnv.authenticatedContext(uid).firestore();
}

function anonDb() {
  return testEnv.unauthenticatedContext().firestore();
}

// ---------------------------------------------------------------------------

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
  await seedUser(ALICE, 'buyer');
  await seedUser(BOB, 'buyer');
  await seedUser(ADMIN, 'admin');
  await seedBin(OPEN_BIN, true);
  await seedBin(CLOSED_BIN, false);
});

// ===========================================================================
// wallets
// ===========================================================================

describe('wallets', () => {
  test('a user reads their own wallet', async () => {
    await seedWallet(ALICE, 120);
    await assertSucceeds(getDoc(doc(db(ALICE), 'wallets', ALICE)));
  });

  test("a user cannot read another user's wallet", async () => {
    await seedWallet(BOB, 120);
    await assertFails(getDoc(doc(db(ALICE), 'wallets', BOB)));
  });

  test('an admin reads any wallet', async () => {
    await seedWallet(ALICE, 120);
    await assertSucceeds(getDoc(doc(db(ADMIN), 'wallets', ALICE)));
  });

  test('registration may open an empty wallet', async () => {
    await assertSucceeds(
      setDoc(doc(db(ALICE), 'wallets', ALICE), {
        userId: ALICE,
        balance: 0,
        updatedAt: serverTimestamp(),
      }),
    );
  });

  test('registration cannot add fields to a wallet', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'wallets', ALICE), {
        userId: ALICE,
        balance: 0,
        updatedAt: serverTimestamp(),
        bonus: 500,
      }),
    );
  });

  test('a wallet cannot be born holding a balance', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'wallets', ALICE), {
        userId: ALICE,
        balance: 500,
        updatedAt: serverTimestamp(),
      }),
    );
  });

  test('a user cannot open a wallet for someone else', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'wallets', BOB), {
        userId: BOB,
        balance: 0,
        updatedAt: serverTimestamp(),
      }),
    );
  });

  test('a user cannot credit their own wallet', async () => {
    await seedWallet(ALICE, 0);
    await assertFails(
      updateDoc(doc(db(ALICE), 'wallets', ALICE), { balance: 9999 }),
    );
  });

  test('AN ADMIN cannot credit a wallet either', async () => {
    // The load-bearing test in this file. If an admin can write a balance,
    // there are two code paths that pay out and the rules only police one.
    await seedWallet(ALICE, 0);
    await assertFails(
      updateDoc(doc(db(ADMIN), 'wallets', ALICE), { balance: 9999 }),
    );
  });

  test('nobody deletes a wallet', async () => {
    await seedWallet(ALICE, 50);
    await assertFails(deleteDoc(doc(db(ALICE), 'wallets', ALICE)));
    await assertFails(deleteDoc(doc(db(ADMIN), 'wallets', ALICE)));
  });
});

// ===========================================================================
// transactions — the ledger
// ===========================================================================

describe('transactions', () => {
  test('a user reads their own ledger entries', async () => {
    await seedTransaction('tx1', ALICE);
    await assertSucceeds(getDoc(doc(db(ALICE), 'transactions', 'tx1')));
  });

  test("a user cannot read another user's ledger", async () => {
    await seedTransaction('tx1', BOB);
    await assertFails(getDoc(doc(db(ALICE), 'transactions', 'tx1')));
  });

  test('an admin reads any ledger entry', async () => {
    await seedTransaction('tx1', ALICE);
    await assertSucceeds(getDoc(doc(db(ADMIN), 'transactions', 'tx1')));
  });

  test('a user cannot write a ledger entry, however well-formed', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'transactions', 'forged'), {
        userId: ALICE,
        delta: 50,
        source: 'disposal',
        refId: 'disposal_1',
        balanceAfter: 50,
        createdAt: serverTimestamp(),
      }),
    );
  });

  test('an admin cannot write a ledger entry', async () => {
    await assertFails(
      setDoc(doc(db(ADMIN), 'transactions', 'forged'), {
        userId: ALICE,
        delta: 50,
        source: 'disposal',
        refId: 'disposal_1',
        balanceAfter: 50,
        createdAt: serverTimestamp(),
      }),
    );
  });

  test('a ledger entry cannot be amended or removed', async () => {
    await seedTransaction('tx1', ALICE);
    await assertFails(
      updateDoc(doc(db(ADMIN), 'transactions', 'tx1'), { delta: 5000 }),
    );
    await assertFails(deleteDoc(doc(db(ADMIN), 'transactions', 'tx1')));
  });
});

// ===========================================================================
// bins
// ===========================================================================

describe('bins', () => {
  test('a signed-in user resolves a scanned bin', async () => {
    await assertSucceeds(getDoc(doc(db(ALICE), 'bins', OPEN_BIN)));
  });

  test('an inactive bin is still readable, so the app can explain itself',
    async () => {
      await assertSucceeds(getDoc(doc(db(ALICE), 'bins', CLOSED_BIN)));
    });

  test('an anonymous visitor reads nothing', async () => {
    await assertFails(getDoc(doc(anonDb(), 'bins', OPEN_BIN)));
  });

  test('an admin cannot register a bin from the client', async () => {
    await assertFails(
      setDoc(doc(db(ADMIN), 'bins', 'bin_new'), {
        label: 'New bin',
        lat: 23.78,
        lng: 90.4,
        radiusMeters: 50,
        qrPayload: 'chokro:bin:new',
        active: true,
        createdBy: ADMIN,
        createdAt: serverTimestamp(),
      }),
    );
  });

  test('an admin cannot widen a geofence from the client', async () => {
    // radiusMeters is an input the server trusts when deciding a payout.
    await assertFails(
      updateDoc(doc(db(ADMIN), 'bins', OPEN_BIN), { radiusMeters: 100000 }),
    );
  });
});

// ===========================================================================
// disposals — create
// ===========================================================================

describe('disposal submission', () => {
  test('a valid submission is accepted', async () => {
    await assertSucceeds(
      setDoc(doc(db(ALICE), 'disposals', 'd1'), validDisposal(ALICE)),
    );
  });

  test('cannot arrive already approved', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd1'), {
        ...validDisposal(ALICE),
        status: 'autoApproved',
      }),
    );
  });

  test('cannot arrive carrying an award', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd1'), {
        ...validDisposal(ALICE),
        pointsAwarded: 9999,
      }),
    );
  });

  test('cannot arrive carrying a photo hash', async () => {
    // Duplicate detection is worthless if the client supplies the fingerprint.
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd1'), {
        ...validDisposal(ALICE),
        photoHash: 'forged',
      }),
    );
  });

  test('cannot arrive carrying screening results', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd1'), {
        ...validDisposal(ALICE),
        screenConfidence: 1.0,
      }),
    );
  });

  test('cannot arrive pre-reviewed', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd1'), {
        ...validDisposal(ALICE),
        reviewedBy: ADMIN,
      }),
    );
  });

  test('cannot arrive pre-flagged', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd1'), {
        ...validDisposal(ALICE),
        flags: ['lowConfidence'],
      }),
    );
  });

  test('cannot claim that server verification already completed', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd-verified'), {
        ...validDisposal(ALICE),
        verificationCompleted: true,
      }),
    );
  });

  test('cannot be submitted on behalf of another user', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd1'), validDisposal(BOB)),
    );
  });

  test('rejects a zero or negative item count', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd1'), {
        ...validDisposal(ALICE),
        declaredItemCount: 0,
      }),
    );
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd2'), {
        ...validDisposal(ALICE),
        declaredItemCount: -5,
      }),
    );
  });

  test('rejects an implausible item count', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd1'), {
        ...validDisposal(ALICE),
        declaredItemCount: 5000,
      }),
    );
  });

  test('rejects a non-integer item count', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd1'), {
        ...validDisposal(ALICE),
        declaredItemCount: 2.5,
      }),
    );
  });

  test('rejects an item type outside the Dart enum', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd-type'), {
        ...validDisposal(ALICE),
        itemType: 'ignorePreviousInstructions',
      }),
    );
  });

  test('rejects an image outside the signed-in user upload folder', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd-photo'), {
        ...validDisposal(ALICE),
        photoPublicId: `chokro/disposals/${BOB}/abc123`,
      }),
    );
  });

  test('rejects out-of-range and failed-fix coordinates', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd-lat'), {
        ...validDisposal(ALICE),
        capturedLat: 91,
      }),
    );
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd-zero'), {
        ...validDisposal(ALICE),
        capturedLat: 0,
        capturedLng: 0,
      }),
    );
  });

  test('rejects a client-authored timestamp', async () => {
    // §7.4: the lockout window is worthless if the client supplies the clock.
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd1'), {
        ...validDisposal(ALICE),
        createdAt: new Date(),
      }),
    );
  });

  test('rejects a submission at an inactive bin', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd1'),
        validDisposal(ALICE, CLOSED_BIN)),
    );
  });

  test('rejects a submission at a bin that does not exist', async () => {
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd1'),
        validDisposal(ALICE, 'bin_imaginary')),
    );
  });

  test('a suspended user cannot submit', async () => {
    await seedUser(ALICE, 'buyer', 'suspended');
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd1'), validDisposal(ALICE)),
    );
  });

  test('an anonymous visitor cannot submit', async () => {
    await assertFails(
      setDoc(doc(anonDb(), 'disposals', 'd1'), validDisposal(ALICE)),
    );
  });
});

// ===========================================================================
// disposals — lockout window (F2.6)
// ===========================================================================

describe('duplicate-claim lockout', () => {
  test('refuses a second submission inside the window', async () => {
    await seedLockout(ALICE, OPEN_BIN, new Date(Date.now() + 3600 * 1000));
    await assertFails(
      setDoc(doc(db(ALICE), 'disposals', 'd2'), validDisposal(ALICE)),
    );
  });

  test('allows a submission once the window has passed', async () => {
    await seedLockout(ALICE, OPEN_BIN, new Date(Date.now() - 3600 * 1000));
    await assertSucceeds(
      setDoc(doc(db(ALICE), 'disposals', 'd2'), validDisposal(ALICE)),
    );
  });

  test('a lockout at one bin does not block another bin', async () => {
    await seedBin('bin_other', true);
    await seedLockout(ALICE, OPEN_BIN, new Date(Date.now() + 3600 * 1000));
    await assertSucceeds(
      setDoc(doc(db(ALICE), 'disposals', 'd2'),
        validDisposal(ALICE, 'bin_other')),
    );
  });

  test("one user's lockout does not block another user", async () => {
    await seedLockout(ALICE, OPEN_BIN, new Date(Date.now() + 3600 * 1000));
    await assertSucceeds(
      setDoc(doc(db(BOB), 'disposals', 'd2'), validDisposal(BOB)),
    );
  });

  test('a user may read their own lockout to see when it lifts', async () => {
    await seedLockout(ALICE, OPEN_BIN, new Date(Date.now() + 3600 * 1000));
    await assertSucceeds(
      getDoc(doc(db(ALICE), 'lockouts', `${ALICE}_${OPEN_BIN}`)),
    );
  });

  test("a user cannot read another user's lockout", async () => {
    await seedLockout(BOB, OPEN_BIN, new Date(Date.now() + 3600 * 1000));
    await assertFails(
      getDoc(doc(db(ALICE), 'lockouts', `${BOB}_${OPEN_BIN}`)),
    );
  });

  test('a user cannot clear their own lockout', async () => {
    await seedLockout(ALICE, OPEN_BIN, new Date(Date.now() + 3600 * 1000));
    await assertFails(
      deleteDoc(doc(db(ALICE), 'lockouts', `${ALICE}_${OPEN_BIN}`)),
    );
    await assertFails(
      updateDoc(doc(db(ALICE), 'lockouts', `${ALICE}_${OPEN_BIN}`), {
        expiresAt: new Date(Date.now() - 1000),
      }),
    );
  });
});

// ===========================================================================
// disposals — read and transition
// ===========================================================================

describe('disposal read and transition', () => {
  test('a user reads their own submission', async () => {
    await seedDisposal('d1', ALICE);
    await assertSucceeds(getDoc(doc(db(ALICE), 'disposals', 'd1')));
  });

  test("a user cannot read another user's submission", async () => {
    await seedDisposal('d1', BOB);
    await assertFails(getDoc(doc(db(ALICE), 'disposals', 'd1')));
  });

  test('an admin reads any submission, for the review queue', async () => {
    await seedDisposal('d1', ALICE);
    await assertSucceeds(getDoc(doc(db(ADMIN), 'disposals', 'd1')));
  });

  test('a user cannot approve their own submission', async () => {
    await seedDisposal('d1', ALICE);
    await assertFails(
      updateDoc(doc(db(ALICE), 'disposals', 'd1'), {
        status: 'autoApproved',
        pointsAwarded: 50,
      }),
    );
  });

  test('AN ADMIN cannot approve from the client either', async () => {
    // The admin's approve button calls the server. There is no client
    // transition out of pending, for anyone.
    await seedDisposal('d1', ALICE);
    await assertFails(
      updateDoc(doc(db(ADMIN), 'disposals', 'd1'), {
        status: 'manualApproved',
        pointsAwarded: 50,
        reviewedBy: ADMIN,
      }),
    );
  });

  test('nobody deletes a submission', async () => {
    await seedDisposal('d1', ALICE);
    await assertFails(deleteDoc(doc(db(ALICE), 'disposals', 'd1')));
    await assertFails(deleteDoc(doc(db(ADMIN), 'disposals', 'd1')));
  });
});

// ===========================================================================
// config — the points policy
// ===========================================================================

describe('points policy config', () => {
  test('any signed-in user reads the policy', async () => {
    await seedConfig();
    await assertSucceeds(getDoc(doc(db(ALICE), 'config', 'points')));
  });

  test('an anonymous visitor does not', async () => {
    await seedConfig();
    await assertFails(getDoc(doc(anonDb(), 'config', 'points')));
  });

  test('a user cannot raise their own award', async () => {
    await seedConfig();
    await assertFails(
      updateDoc(doc(db(ALICE), 'config', 'points'), { disposalAward: 100000 }),
    );
  });

  test('an admin cannot write the policy from the client', async () => {
    // Rules cannot express "claim award must stay below disposal award", so the
    // write goes where PointsPolicy.validate() can actually run.
    await seedConfig();
    await assertFails(
      updateDoc(doc(db(ADMIN), 'config', 'points'), { claimAward: 90 }),
    );
  });
});

// ===========================================================================
// claim quotas
// ===========================================================================

describe('claim quotas', () => {
  test('a user may read a quota counter', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'claimQuotas', `${ALICE}_2026-W31`), {
        count: 3,
      });
    });
    await assertSucceeds(
      getDoc(doc(db(ALICE), 'claimQuotas', `${ALICE}_2026-W31`)),
    );
  });

  test("a user cannot read another user's quota counter", async () => {
    await assertFails(
      getDoc(doc(db(ALICE), 'claimQuotas', `${BOB}_2026-W31`)),
    );
  });

  test('a user cannot reset their own quota', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'claimQuotas', `${ALICE}_2026-W31`), {
        count: 3,
      });
    });
    await assertFails(
      updateDoc(doc(db(ALICE), 'claimQuotas', `${ALICE}_2026-W31`), {
        count: 0,
      }),
    );
  });
});

// ===========================================================================
// M1 regression — these blocks must be untouched by the M2 revision
// ===========================================================================

describe('M1 regression', () => {
  test('a user still cannot promote themselves to admin', async () => {
    await assertFails(
      updateDoc(doc(db(ALICE), 'users', ALICE), { role: 'admin' }),
    );
  });

  test('an admin still approves a seller application', async () => {
    await testEnv.withSecurityRulesDisabled(async (ctx) => {
      await setDoc(doc(ctx.firestore(), 'sellerApplications', 'app1'), {
        userId: ALICE,
        businessName: 'Alice Handmade',
        description: 'Recycled paper goods',
        status: 'pending',
        createdAt: new Date(),
      });
    });
    await assertSucceeds(
      updateDoc(doc(db(ADMIN), 'sellerApplications', 'app1'), {
        status: 'approved',
        reviewedBy: ADMIN,
        reviewedAt: serverTimestamp(),
        reason: 'Looks good',
      }),
    );
  });

  test('an admin may now also set a temporary suspension', async () => {
    await assertSucceeds(
      updateDoc(doc(db(ADMIN), 'users', ALICE), {
        status: 'suspended',
        suspendedUntil: new Date(Date.now() + 7 * 24 * 3600 * 1000),
      }),
    );
  });
});
