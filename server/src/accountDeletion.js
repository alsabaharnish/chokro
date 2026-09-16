/**
 * Chokro — Champion account deletion (SEC-13).
 *
 * ## WHY THIS COULD BE BUILT BEFORE COUNSEL ANSWERED
 *
 * Open decision 9 is unresolved, and `retention.js` refuses to delete anything
 * because of it. This module deletes things anyway, and the difference is not
 * inconsistency — it is that the two halves of an erasure request have very
 * different legal temperatures.
 *
 * Four answers to decision 9 are on the table (`docs/RETENTION_SCHEDULE.md`
 * §3, §3.1): purge everything, retain everything, sever the link, or refuse
 * outright. They disagree completely about disposals. **They agree entirely
 * about the account.** Every one of them has `users: purge`. A name, an email
 * address, a profile photograph and a push token have no compliance role under
 * any reading — they are not evidence of anything a certificate claims.
 *
 * So this module does the half that all four answers share, and touches
 * nothing the answers disagree about. What it retains, it retains loudly:
 * `deleteAccount` returns the list and the reason, and `planDeletion` shows it
 * before anything happens.
 *
 * ## WHY THE USER DOCUMENT IS TOMBSTONED AND NOT DELETED
 *
 * Retained records reference the account: `disposals.userId`, orders,
 * transactions. Deleting the document would turn every one of those into a
 * dangling pointer — and a dangling pointer does not read as "this person
 * asked to be erased". It reads as corruption, which invites somebody to go
 * looking for the missing record and makes the erasure LESS final rather than
 * more.
 *
 * A tombstone answers the question. The identifying fields are gone; what
 * remains says an account existed, was erased, and when.
 *
 * ## WHY AN ADMIN RUNS IT
 *
 * Irreversible, and the legal basis is unsettled. §3.3 of the spec has no
 * scheduler and every destructive job in this codebase is Admin-triggered. A
 * self-service button is the right destination and the wrong first step.
 */

const { db, auth, serverTimestamp } = require('./firebase');
const cloudinary = require('./cloudinary');

const USERS = 'users';
const CARTS = 'carts';
const DEVICES = 'devices';

/**
 * What an erasure request removes. Agreed by all four answers to decision 9.
 *
 * Each entry says what it is, so the plan can explain itself rather than
 * listing collection names at somebody who has to decide whether to proceed.
 */
const ERASED = Object.freeze([
  { what: 'Name, email address and profile photograph', where: 'users' },
  { what: 'The sign-in account itself', where: 'Firebase Auth' },
  { what: 'The profile photograph file', where: 'Cloudinary' },
  { what: 'Push notification tokens', where: 'users/{uid}/devices' },
  { what: 'Any open shopping cart', where: 'carts' },
]);

/**
 * What survives, and why. Reported rather than assumed.
 *
 * Every line here is a thing somebody asking to be forgotten would reasonably
 * expect to go. Telling them is the point; a deletion that quietly kept six
 * collections would be worse than one that refused.
 */
const RETAINED = Object.freeze([
  {
    what: 'Disposal records and their photographs',
    why: 'The evidence behind certificates already issued to producers. '
      + 'Chokro proposes to refuse erasure of these (decision 9, pending '
      + 'counsel). They carry no name once this deletion has run.',
    contested: true,
  },
  {
    what: 'Attributions — the gram figures',
    why: 'They hold no account reference at all. Nothing in them identifies '
      + 'anyone, before or after this deletion.',
    contested: false,
  },
  {
    what: 'Points, wallet balance and transactions',
    why: 'Financial records with retention obligations of their own, '
      + 'unrelated to EPR. Pending the same counsel review.',
    contested: true,
  },
  {
    what: 'Orders and donations',
    why: 'Each has a counterparty — a seller or a recipient organisation — '
      + 'whose own record of the transaction cannot be erased by one side.',
    contested: true,
  },
  {
    what: 'Eco-action claims',
    why: 'Outside the attribution path entirely (EPR-27). Erasable in '
      + 'principle; left alone here because a claim can carry a published '
      + 'photocard, and withdrawing a publication is its own flow.',
    contested: false,
  },
]);

function badRequest(message) {
  const error = new Error(message);
  error.code = 'bad_request';
  return error;
}

/**
 * What a deletion would do, without doing it.
 *
 * Read-only, and meant to be shown to whoever is about to press the button.
 */
async function planDeletion(uid) {
  if (typeof uid !== 'string' || uid.length === 0) {
    throw badRequest('A deletion plan needs an account.');
  }

  const snap = await db().collection(USERS).doc(uid).get();
  if (!snap.exists) {
    return {
      uid,
      accountExists: false,
      alreadyDeleted: false,
      erased: ERASED,
      retained: RETAINED,
      note: 'No account document. There may still be retained records that '
        + 'reference this uid.',
    };
  }

  const user = snap.data();
  return {
    uid,
    accountExists: true,
    alreadyDeleted: user.deletedAt != null,
    name: user.name ?? null,
    email: user.email ?? null,
    role: user.role ?? null,
    hasProfilePhoto: Boolean(user.profilePhotoPublicId),
    erased: ERASED,
    retained: RETAINED,
  };
}

/**
 * Erases the account. Irreversible.
 *
 * Ordered so that a failure partway through leaves the account MORE erased
 * rather than less: identity first, then the sign-in, then the incidentals. A
 * run that dies after step one has removed the name and left a working login,
 * which is recoverable by running it again. The reverse order would delete the
 * login and leave the name, which is the worst of both.
 */
async function deleteAccount({ uid, actorUid, actorName = '', reason = '' }) {
  if (typeof uid !== 'string' || uid.length === 0) {
    throw badRequest('A deletion must name the account.');
  }
  if (typeof actorUid !== 'string' || actorUid.length === 0) {
    throw badRequest('A deletion must name the Admin performing it.');
  }
  if (uid === actorUid) {
    // Not a moral position — a practical one. An Admin who erases their own
    // account mid-session leaves the request unfinishable and the record
    // written by an account that no longer exists.
    throw badRequest('An Admin cannot delete their own account this way.');
  }

  const userRef = db().collection(USERS).doc(uid);
  const snap = await userRef.get();
  if (!snap.exists) throw badRequest('There is no such account.');

  const user = snap.data();
  if (user.deletedAt != null) {
    return { uid, alreadyDeleted: true, erased: [], retained: RETAINED };
  }

  const done = [];
  const failed = [];

  // 1. Identity. The part that actually matters, and therefore first.
  await userRef.update({
    name: null,
    email: null,
    profilePhotoUrl: null,
    profilePhotoPublicId: null,
    status: 'deleted',
    deletedAt: serverTimestamp(),
    deletedBy: actorUid,
    deletedByName: actorName,
    deletionReason: typeof reason === 'string' ? reason.slice(0, 500) : '',
  });
  done.push('Identity fields cleared and the account tombstoned');

  // 2. The sign-in. After the identity, so a failure here leaves a nameless
  // account rather than a named one nobody can reach.
  try {
    await auth().deleteUser(uid);
    done.push('Sign-in account deleted');
  } catch (err) {
    // `auth/user-not-found` is a success in disguise — the account is already
    // unreachable, which is the outcome being asked for.
    if (err.code === 'auth/user-not-found') {
      done.push('Sign-in account was already absent');
    } else {
      failed.push(`Sign-in account: ${err.message}`);
    }
  }

  // 3. The photograph file. Reported rather than thrown: Cloudinary being
  // unreachable must not leave the account half-erased with no record of
  // which half.
  if (user.profilePhotoPublicId) {
    try {
      await cloudinary.deleteImage(user.profilePhotoPublicId);
      done.push('Profile photograph deleted');
    } catch (err) {
      failed.push(`Profile photograph: ${err.message}`);
    }
  }

  // 4. Push tokens.
  try {
    const devices = await userRef.collection(DEVICES).get();
    await Promise.all(devices.docs.map((d) => d.ref.delete()));
    done.push(`Push tokens deleted (${devices.size})`);
  } catch (err) {
    failed.push(`Push tokens: ${err.message}`);
  }

  // 5. Cart.
  try {
    await db().collection(CARTS).doc(uid).delete();
    done.push('Shopping cart deleted');
  } catch (err) {
    failed.push(`Shopping cart: ${err.message}`);
  }

  return {
    uid,
    alreadyDeleted: false,
    // `complete` is false whenever anything failed, and the caller is expected
    // to say so. A deletion reported as done with a silent partial failure is
    // how somebody is told they were forgotten when they were not.
    complete: failed.length === 0,
    erased: done,
    failed,
    retained: RETAINED,
  };
}

module.exports = {
  planDeletion,
  deleteAccount,
  ERASED,
  RETAINED,
};
