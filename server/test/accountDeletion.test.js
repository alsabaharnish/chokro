/**
 * Champion account deletion (SEC-13).
 *
 * The tests that matter here are about what deletion does NOT do, and about
 * failure. A deletion that quietly kept six collections, or reported success
 * after half of it failed, is how somebody gets told they were forgotten when
 * they were not.
 */

jest.mock('../src/firebase', () => ({
  db: jest.fn(),
  auth: jest.fn(),
  serverTimestamp: jest.fn(() => '__TS__'),
}));

jest.mock('../src/cloudinary', () => ({
  deleteImage: jest.fn().mockResolvedValue({ result: 'ok' }),
}));

const firebase = require('../src/firebase');
const cloudinary = require('../src/cloudinary');
const accountDeletion = require('../src/accountDeletion');

const ADMIN = { actorUid: 'admin-1', actorName: 'Ayesha Rahman' };

function fakeDb({ user = undefined, devices = [], onUpdate, cartDelete } = {}) {
  const update = onUpdate || jest.fn().mockResolvedValue(undefined);
  const userRef = {
    get: jest.fn().mockResolvedValue({
      exists: user !== undefined,
      data: () => user,
    }),
    update,
    collection: () => ({
      get: jest.fn().mockResolvedValue({
        size: devices.length,
        docs: devices.map((id) => ({
          ref: { delete: jest.fn().mockResolvedValue(undefined) },
          id,
        })),
      }),
    }),
  };

  return {
    __update: update,
    collection: (name) => {
      if (name === 'users') return { doc: () => userRef };
      if (name === 'carts') {
        return {
          doc: () => ({
            delete: cartDelete || jest.fn().mockResolvedValue(undefined),
          }),
        };
      }
      throw new Error(`unexpected collection ${name}`);
    },
  };
}

function fakeAuth(deleteUser) {
  return () => ({ deleteUser: deleteUser || jest.fn().mockResolvedValue(undefined) });
}

const CHAMPION = {
  name: 'Rahim Uddin',
  email: 'rahim@example.com',
  role: 'buyer',
  status: 'active',
  profilePhotoPublicId: 'chokro/profiles/champion-1/abc',
};

beforeEach(() => {
  jest.clearAllMocks();
  cloudinary.deleteImage.mockResolvedValue({ result: 'ok' });
  firebase.auth.mockImplementation(fakeAuth());
});

// ---------------------------------------------------------------------------

describe('what is retained is declared, not inferred', () => {
  test('the retained list names the disposal records first', () => {
    // The thing somebody asking to be forgotten would most expect to go. If it
    // is not the first line they read, the disclosure has failed.
    expect(accountDeletion.RETAINED[0].what).toMatch(/Disposal/);
    expect(accountDeletion.RETAINED[0].contested).toBe(true);
  });

  test('every retained entry gives a reason', () => {
    for (const entry of accountDeletion.RETAINED) {
      expect(typeof entry.why).toBe('string');
      expect(entry.why.length).toBeGreaterThan(30);
      expect(typeof entry.contested).toBe('boolean');
    }
  });

  test('the erased list covers identity, sign-in, photo, tokens and cart', () => {
    const joined = accountDeletion.ERASED.map((e) => e.what).join(' | ');
    expect(joined).toMatch(/email/i);
    expect(joined).toMatch(/sign-in/i);
    expect(joined).toMatch(/photograph/i);
    expect(joined).toMatch(/[Pp]ush/);
    expect(joined).toMatch(/cart/i);
  });

  test('a plan reports both lists before anything happens', async () => {
    firebase.db.mockReturnValue(fakeDb({ user: CHAMPION }));

    const plan = await accountDeletion.planDeletion('champion-1');

    expect(plan.accountExists).toBe(true);
    expect(plan.alreadyDeleted).toBe(false);
    expect(plan.retained).toBe(accountDeletion.RETAINED);
    expect(plan.erased).toBe(accountDeletion.ERASED);
  });
});

// ---------------------------------------------------------------------------

describe('deletion tombstones rather than removing the document', () => {
  test('identity fields are nulled and the account is marked deleted', async () => {
    const db = fakeDb({ user: CHAMPION, devices: ['d1', 'd2'] });
    firebase.db.mockReturnValue(db);

    await accountDeletion.deleteAccount({ uid: 'champion-1', ...ADMIN });

    const written = db.__update.mock.calls[0][0];
    expect(written.name).toBeNull();
    expect(written.email).toBeNull();
    expect(written.profilePhotoUrl).toBeNull();
    expect(written.profilePhotoPublicId).toBeNull();
    expect(written.status).toBe('deleted');
    expect(written.deletedBy).toBe('admin-1');
  });

  test('the document itself is never deleted', async () => {
    // Retained records reference the uid. A dangling pointer does not read as
    // "this person asked to be erased" — it reads as corruption, which invites
    // somebody to go looking for the missing record.
    const userDelete = jest.fn();
    const db = fakeDb({ user: CHAMPION });
    db.collection = ((original) => (name) => {
      const col = original(name);
      if (name === 'users') {
        const ref = col.doc();
        ref.delete = userDelete;
        return { doc: () => ref };
      }
      return col;
    })(db.collection);
    firebase.db.mockReturnValue(db);

    await accountDeletion.deleteAccount({ uid: 'champion-1', ...ADMIN });

    expect(userDelete).not.toHaveBeenCalled();
  });

  test('identity is cleared BEFORE the sign-in is deleted', async () => {
    const order = [];
    const db = fakeDb({
      user: CHAMPION,
      onUpdate: jest.fn(async () => { order.push('identity'); }),
    });
    firebase.db.mockReturnValue(db);
    firebase.auth.mockImplementation(fakeAuth(
      jest.fn(async () => { order.push('signin'); }),
    ));

    await accountDeletion.deleteAccount({ uid: 'champion-1', ...ADMIN });

    // A run that dies after step one leaves a nameless account with a working
    // login, which re-running fixes. The reverse leaves a named account nobody
    // can reach — the worst of both.
    expect(order).toEqual(['identity', 'signin']);
  });

  test('a second deletion is a no-op rather than an error', async () => {
    firebase.db.mockReturnValue(
      fakeDb({ user: { ...CHAMPION, deletedAt: '2026-09-01' } }),
    );

    const result = await accountDeletion.deleteAccount({
      uid: 'champion-1',
      ...ADMIN,
    });

    expect(result.alreadyDeleted).toBe(true);
    expect(result.erased).toEqual([]);
  });
});

// ---------------------------------------------------------------------------

describe('partial failure is never reported as success', () => {
  test('a Cloudinary failure marks the deletion incomplete and names it', async () => {
    firebase.db.mockReturnValue(fakeDb({ user: CHAMPION }));
    cloudinary.deleteImage.mockRejectedValue(new Error('cloudinary down'));

    const result = await accountDeletion.deleteAccount({
      uid: 'champion-1',
      ...ADMIN,
    });

    expect(result.complete).toBe(false);
    expect(result.failed.join(' ')).toMatch(/Profile photograph/);
    // And the rest still ran — a photo service outage must not leave the name
    // in place.
    expect(result.erased.join(' ')).toMatch(/Identity fields cleared/);
  });

  test('a sign-in deletion failure marks it incomplete', async () => {
    firebase.db.mockReturnValue(fakeDb({ user: CHAMPION }));
    firebase.auth.mockImplementation(fakeAuth(
      jest.fn().mockRejectedValue(new Error('auth unavailable')),
    ));

    const result = await accountDeletion.deleteAccount({
      uid: 'champion-1',
      ...ADMIN,
    });

    expect(result.complete).toBe(false);
    expect(result.failed.join(' ')).toMatch(/Sign-in account/);
  });

  test('an already-absent sign-in is a success, not a failure', async () => {
    firebase.db.mockReturnValue(fakeDb({ user: CHAMPION }));
    const notFound = new Error('no user');
    notFound.code = 'auth/user-not-found';
    firebase.auth.mockImplementation(fakeAuth(
      jest.fn().mockRejectedValue(notFound),
    ));

    const result = await accountDeletion.deleteAccount({
      uid: 'champion-1',
      ...ADMIN,
    });

    // The outcome being asked for is that the account is unreachable. It
    // already is.
    expect(result.complete).toBe(true);
    expect(result.erased.join(' ')).toMatch(/already absent/);
  });

  test('a clean run reports complete', async () => {
    firebase.db.mockReturnValue(fakeDb({ user: CHAMPION, devices: ['d1'] }));

    const result = await accountDeletion.deleteAccount({
      uid: 'champion-1',
      ...ADMIN,
    });

    expect(result.complete).toBe(true);
    expect(result.failed).toEqual([]);
    expect(result.retained).toBe(accountDeletion.RETAINED);
  });

  test('an account with no photograph does not report a photo step', async () => {
    firebase.db.mockReturnValue(
      fakeDb({ user: { ...CHAMPION, profilePhotoPublicId: null } }),
    );

    const result = await accountDeletion.deleteAccount({
      uid: 'champion-1',
      ...ADMIN,
    });

    expect(cloudinary.deleteImage).not.toHaveBeenCalled();
    expect(result.complete).toBe(true);
  });
});

// ---------------------------------------------------------------------------

describe('refusals', () => {
  test('an Admin cannot delete their own account this way', async () => {
    await expect(
      accountDeletion.deleteAccount({ uid: 'admin-1', actorUid: 'admin-1' }),
    ).rejects.toThrow(/own account/);
  });

  test('a deletion must name the Admin performing it', async () => {
    await expect(
      accountDeletion.deleteAccount({ uid: 'champion-1', actorUid: '' }),
    ).rejects.toThrow(/Admin/);
  });

  test('an unknown account is refused rather than silently succeeding', async () => {
    firebase.db.mockReturnValue(fakeDb({ user: undefined }));

    await expect(
      accountDeletion.deleteAccount({ uid: 'nobody', ...ADMIN }),
    ).rejects.toThrow(/no such account/);
  });

  test('a plan for a missing account still lists what would be retained', async () => {
    firebase.db.mockReturnValue(fakeDb({ user: undefined }));

    const plan = await accountDeletion.planDeletion('nobody');

    expect(plan.accountExists).toBe(false);
    // Because records referencing the uid can outlive the account document.
    expect(plan.retained).toBe(accountDeletion.RETAINED);
    expect(plan.note).toMatch(/retained records/);
  });
});
