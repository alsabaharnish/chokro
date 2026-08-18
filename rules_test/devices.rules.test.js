/**
 * Rules tests for `users/{uid}/devices` — push tokens (F7.1).
 *
 * The property under test is narrow but real: a push token is a capability, and
 * the person who owns the device is the only one who should be able to add,
 * read or retire it. Nobody — including an administrator — enumerates somebody
 * else's devices, and nobody registers a token against an account that is not
 * theirs.
 *
 * The one that matters most is the last block. A suspended user must still be
 * able to hold a registration, because the notification they most need is the
 * one telling them a submission was rejected. Gating this on isActive() would
 * have been the reflex, and it would have silenced exactly the people who are
 * owed an explanation.
 *
 * Its own projectId, per §9 — suites sharing one namespace clear each other's
 * seed data mid-run.
 */

const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require('@firebase/rules-unit-testing');
const {
  doc,
  getDoc,
  setDoc,
  deleteDoc,
  serverTimestamp,
} = require('firebase/firestore');
const fs = require('fs');

let testEnv;

const TOKEN = 'fMEbY3Qk:APA91bH_exampletoken_0123456789';
const OTHER_TOKEN = 'zzQx9Lm:APA91bH_anothertoken_9876543210';

/** A valid registration document. */
const validDevice = () => ({
  platform: 'android',
  updatedAt: serverTimestamp(),
});

const devicePath = (uid, token = TOKEN) => `users/${uid}/devices/${token}`;

beforeAll(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'chokro-devices-rules',
    firestore: {
      rules: fs.readFileSync('../firestore.rules', 'utf8'),
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

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();

    await setDoc(doc(db, 'users/owner_uid'), {
      name: 'Owner',
      email: 'owner@example.com',
      role: 'buyer',
      status: 'active',
      createdAt: new Date(),
    });

    await setDoc(doc(db, 'users/other_uid'), {
      name: 'Other',
      email: 'other@example.com',
      role: 'buyer',
      status: 'active',
      createdAt: new Date(),
    });

    await setDoc(doc(db, 'users/admin_uid'), {
      name: 'Admin',
      email: 'admin@example.com',
      role: 'admin',
      status: 'active',
      createdAt: new Date(),
    });

    await setDoc(doc(db, 'users/suspended_uid'), {
      name: 'Suspended',
      email: 'suspended@example.com',
      role: 'buyer',
      status: 'suspended',
      createdAt: new Date(),
    });
  });
});

const asOwner = () => testEnv.authenticatedContext('owner_uid').firestore();
const asOther = () => testEnv.authenticatedContext('other_uid').firestore();
const asAdmin = () => testEnv.authenticatedContext('admin_uid').firestore();
const asSuspended = () =>
  testEnv.authenticatedContext('suspended_uid').firestore();
const asAnon = () => testEnv.unauthenticatedContext().firestore();

describe('registering a device', () => {
  test('a user registers their own token', async () => {
    await assertSucceeds(
      setDoc(doc(asOwner(), devicePath('owner_uid')), validDevice()),
    );
  });

  test('a user cannot register a token against another account', async () => {
    // Otherwise anyone could subscribe their own phone to someone else's
    // decisions — every rejection reason, every award, delivered to a stranger.
    await assertFails(
      setDoc(doc(asOther(), devicePath('owner_uid')), validDevice()),
    );
  });

  test('an administrator cannot register a token for someone else', async () => {
    // Read access is generous throughout these rules; this is not read access.
    await assertFails(
      setDoc(doc(asAdmin(), devicePath('owner_uid')), validDevice()),
    );
  });

  test('an anonymous caller cannot register anything', async () => {
    await assertFails(
      setDoc(doc(asAnon(), devicePath('owner_uid')), validDevice()),
    );
  });

  test('re-registering the same token is allowed and idempotent', async () => {
    const db = asOwner();
    await assertSucceeds(
      setDoc(doc(db, devicePath('owner_uid')), validDevice()),
    );
    // App start and onTokenRefresh both write. The token is the document ID, so
    // the second write updates rather than duplicating.
    await assertSucceeds(
      setDoc(doc(db, devicePath('owner_uid')), validDevice()),
    );
  });
});

describe('the document shape is pinned', () => {
  test('an extra key is refused', async () => {
    // hasOnly, same discipline as disposals and claims. There is no
    // server-owned field here today; this is what stops one appearing under a
    // user's control tomorrow.
    await assertFails(
      setDoc(doc(asOwner(), devicePath('owner_uid')), {
        platform: 'android',
        updatedAt: serverTimestamp(),
        deviceName: "Arnish's phone",
      }),
    );
  });

  test('a missing key is refused', async () => {
    await assertFails(
      setDoc(doc(asOwner(), devicePath('owner_uid')), {
        updatedAt: serverTimestamp(),
      }),
    );
  });

  test('an unrecognised platform is refused', async () => {
    await assertFails(
      setDoc(doc(asOwner(), devicePath('owner_uid')), {
        platform: 'blackberry',
        updatedAt: serverTimestamp(),
      }),
    );
  });

  test('a client-authored timestamp is refused', async () => {
    // Same rule as every other timestamp in this file: the value must be the
    // server's, not the device's. A phone with a wrong clock would otherwise
    // sort itself to the top of the device list forever and crowd out the
    // user's real devices.
    await assertFails(
      setDoc(doc(asOwner(), devicePath('owner_uid')), {
        platform: 'android',
        updatedAt: new Date('2030-01-01'),
      }),
    );
  });
});

describe('reading a device list', () => {
  beforeEach(async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), devicePath('owner_uid')), {
        platform: 'android',
        updatedAt: new Date(),
      });
    });
  });

  test('the owner reads their own devices', async () => {
    await assertSucceeds(getDoc(doc(asOwner(), devicePath('owner_uid'))));
  });

  test('another user cannot', async () => {
    await assertFails(getDoc(doc(asOther(), devicePath('owner_uid'))));
  });

  test('an administrator cannot either', async () => {
    // Deliberate, and a departure from the read-generously pattern elsewhere in
    // this file. An administrator has no workflow that needs someone's device
    // list, and a token is a capability — least privilege applies.
    await assertFails(getDoc(doc(asAdmin(), devicePath('owner_uid'))));
  });
});

describe('retiring a device', () => {
  beforeEach(async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), devicePath('owner_uid')), {
        platform: 'android',
        updatedAt: new Date(),
      });
    });
  });

  test('the owner deletes their own token at sign-out', async () => {
    // This is what stops a borrowed phone delivering one user's rejection
    // reason to the next person who signs in on it.
    await assertSucceeds(deleteDoc(doc(asOwner(), devicePath('owner_uid'))));
  });

  test('another user cannot delete it', async () => {
    await assertFails(deleteDoc(doc(asOther(), devicePath('owner_uid'))));
  });

  test('an administrator cannot delete it', async () => {
    // The server prunes dead tokens through the Admin SDK, which bypasses these
    // rules. Nothing needs a client path for it.
    await assertFails(deleteDoc(doc(asAdmin(), devicePath('owner_uid'))));
  });
});

describe('a suspended user keeps their registration', () => {
  test('a suspended user may still register a device', async () => {
    // NOT gated on isActive(), and this is the test that says so out loud.
    //
    // A suspended user is precisely the person owed a notification: the message
    // explaining why a submission was rejected is the one they need most, and
    // the appeal path (F5.4) depends on them knowing a decision was made at all.
    // Silencing them would have been the reflexive reading of "suspended".
    await assertSucceeds(
      setDoc(doc(asSuspended(), devicePath('suspended_uid')), validDevice()),
    );
  });

  test('a suspended user may still retire a device', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), devicePath('suspended_uid', OTHER_TOKEN)),
        { platform: 'android', updatedAt: new Date() },
      );
    });

    await assertSucceeds(
      deleteDoc(doc(asSuspended(), devicePath('suspended_uid', OTHER_TOKEN))),
    );
  });

  test('suspension still bites where it is supposed to', async () => {
    // Sanity check that widening the devices path did not widen anything else:
    // the same suspended account is still refused a claim.
    await assertFails(
      setDoc(doc(asSuspended(), 'claims/c1'), {
        userId: 'suspended_uid',
        actionType: 'composting',
        photoUrl: 'https://example.com/a.jpg',
        photoPublicId: 'a',
        status: 'pending',
        createdAt: serverTimestamp(),
      }),
    );
  });
});
