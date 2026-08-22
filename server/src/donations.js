/**
 * Champion point donations.
 *
 * A donation is a wallet debit, so it belongs behind the same trusted boundary
 * as checkout. The wallet, ledger entry, donation receipt and platform counter
 * move in one Firestore transaction. The caller supplies an idempotency key;
 * repeating an identical request returns the first receipt and never debits
 * twice.
 */

const { db, admin, serverTimestamp } = require('./firebase');
const { creditWalletInTransaction, SOURCES } = require('./award');

const INITIATIVES = Object.freeze([
  'wasteRecovery',
  'treePlanting',
  'greenEntrepreneurship',
]);

const MIN_POINTS = 10;
const MAX_POINTS = 1000000;

class DonationError extends Error {
  constructor(code, message, status = 400) {
    super(message);
    this.name = 'DonationError';
    this.code = code;
    this.status = status;
  }
}

function validateDonation({ donationId, initiative, points }) {
  if (
    typeof donationId !== 'string' ||
    !/^[A-Za-z0-9_-]{10,128}$/.test(donationId)
  ) {
    throw new DonationError(
      'invalid_donation_id',
      'This donation request is invalid. Refresh the page and try again.',
    );
  }
  if (!INITIATIVES.includes(initiative)) {
    throw new DonationError(
      'invalid_initiative',
      'Choose one of the available green initiatives.',
    );
  }
  if (
    !Number.isSafeInteger(points) ||
    points < MIN_POINTS ||
    points > MAX_POINTS
  ) {
    throw new DonationError(
      'invalid_points',
      `Choose a whole-point donation between ${MIN_POINTS} and ${MAX_POINTS}.`,
    );
  }
}

async function donatePoints({ uid, donationId, initiative, points }) {
  validateDonation({ donationId, initiative, points });

  const firestore = db();
  // Scope the idempotency key to the authenticated uid. Two Champions may
  // generate the same random key without conflicting, and a caller cannot
  // reserve a key that blocks somebody else's donation.
  const donationDocId = `${uid}_${donationId}`;
  const donationRef = firestore.collection('donations').doc(donationDocId);
  const walletRef = firestore.collection('wallets').doc(uid);

  return firestore.runTransaction(async (txn) => {
    // Read the receipt first. A network retry with the same id returns the
    // committed result without touching the wallet again.
    const existingSnap = await txn.get(donationRef);
    if (existingSnap.exists) {
      const existing = existingSnap.data();
      if (
        existing.userId !== uid ||
        existing.initiative !== initiative ||
        existing.points !== points
      ) {
        throw new DonationError(
          'donation_id_conflict',
          'This donation request conflicts with an earlier one. Start a new donation.',
          409,
        );
      }
      return {
        donationId,
        initiative,
        points,
        balanceAfter: existing.balanceAfter,
        repeated: true,
      };
    }

    const walletSnap = await txn.get(walletRef);
    if (!walletSnap.exists) {
      throw new DonationError(
        'wallet_missing',
        'Your points wallet could not be found.',
        409,
      );
    }

    const balance = walletSnap.data().balance;
    if (!Number.isSafeInteger(balance) || balance < 0) {
      throw new DonationError(
        'wallet_invalid',
        'Your wallet needs review before points can be donated.',
        409,
      );
    }
    if (balance < points) {
      throw new DonationError(
        'insufficient_points',
        `You have ${balance} points available. Choose a smaller amount.`,
        409,
      );
    }

    const balanceAfter = creditWalletInTransaction(txn, {
      uid,
      delta: -points,
      source: SOURCES.DONATION,
      refId: donationId,
      currentBalance: balance,
    });

    txn.set(donationRef, {
      userId: uid,
      initiative,
      points,
      balanceAfter,
      status: 'received',
      createdAt: serverTimestamp(),
    });

    txn.set(
      firestore.collection('stats').doc('platform'),
      {
        pointsDonated: admin.firestore.FieldValue.increment(points),
        donationsReceived: admin.firestore.FieldValue.increment(1),
      },
      { merge: true },
    );

    return {
      donationId,
      initiative,
      points,
      balanceAfter,
      repeated: false,
    };
  });
}

module.exports = {
  DonationError,
  INITIATIVES,
  MAX_POINTS,
  MIN_POINTS,
  donatePoints,
  validateDonation,
};
