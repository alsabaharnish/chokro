/**
 * Champion point donations and prototype online support.
 *
 * A point donation is a wallet debit. Its wallet, ledger entry, receipt and
 * platform counter move in one transaction. A prototype online donation has no
 * wallet movement but uses the same trusted, idempotent receipt boundary. In
 * both cases, repeating an identical request returns the first result.
 */

const { db, admin, serverTimestamp } = require('./firebase');
const { creditWalletInTransaction, SOURCES } = require('./award');
const {
  PROTOTYPE_PAYMENT_METHODS,
  isPrototypePaymentMethod,
  prototypePaymentReference,
} = require('./prototypePayments');

const INITIATIVES = Object.freeze([
  'wasteRecovery',
  'treePlanting',
  'greenEntrepreneurship',
]);

const MIN_POINTS = 10;
const MAX_POINTS = 1000000;
const MIN_TAKA = 10;
const MAX_TAKA = 1000000;

class DonationError extends Error {
  constructor(code, message, status = 400) {
    super(message);
    this.name = 'DonationError';
    this.code = code;
    this.status = status;
  }
}

function validateIdentity({ donationId, initiative }) {
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
}

function validateDonation({ donationId, initiative, points }) {
  validateIdentity({ donationId, initiative });
  if (!Number.isSafeInteger(points) || points < MIN_POINTS || points > MAX_POINTS) {
    throw new DonationError(
      'invalid_points',
      `Choose a whole-point donation between ${MIN_POINTS} and ${MAX_POINTS}.`,
    );
  }
}

function validatePrototypeDonation({
  donationId,
  initiative,
  amountTaka,
  settlementMethod,
}) {
  validateIdentity({ donationId, initiative });
  if (
    !Number.isSafeInteger(amountTaka) ||
    amountTaka < MIN_TAKA ||
    amountTaka > MAX_TAKA
  ) {
    throw new DonationError(
      'invalid_amount',
      `Choose a whole-taka amount between ${MIN_TAKA} and ${MAX_TAKA}.`,
    );
  }
  if (!isPrototypePaymentMethod(settlementMethod)) {
    throw new DonationError(
      'invalid_settlement_method',
      'Choose one of the available prototype online payment methods.',
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
        existing.points !== points ||
        (existing.kind !== undefined && existing.kind !== 'points')
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
      kind: 'points',
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

/**
 * Records a simulated online donation without touching a wallet or ledger.
 *
 * This is intentionally not evidence that money reached Chokro. It is a
 * product-flow prototype whose receipt and counters are named accordingly.
 */
async function donatePrototypePayment({
  uid,
  donationId,
  initiative,
  amountTaka,
  settlementMethod,
}) {
  validatePrototypeDonation({
    donationId,
    initiative,
    amountTaka,
    settlementMethod,
  });

  const firestore = db();
  const donationRef = firestore
    .collection('donations')
    .doc(`${uid}_${donationId}`);
  const paymentReference = prototypePaymentReference({
    kind: 'donation',
    id: donationId,
    method: settlementMethod,
  });

  return firestore.runTransaction(async (txn) => {
    const existingSnap = await txn.get(donationRef);
    if (existingSnap.exists) {
      const existing = existingSnap.data();
      if (
        existing.kind !== 'prototypeOnline' ||
        existing.userId !== uid ||
        existing.initiative !== initiative ||
        existing.amountTaka !== amountTaka ||
        existing.settlementMethod !== settlementMethod ||
        existing.paymentStatus !== 'paid' ||
        existing.paymentPrototype !== true ||
        typeof existing.paymentReference !== 'string' ||
        existing.paymentReference.length === 0
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
        amountTaka,
        settlementMethod,
        paymentStatus: 'paid',
        paymentReference: existing.paymentReference,
        paymentPrototype: true,
        repeated: true,
      };
    }

    txn.set(donationRef, {
      kind: 'prototypeOnline',
      userId: uid,
      initiative,
      amountTaka,
      settlementMethod,
      paymentStatus: 'paid',
      paymentReference,
      paymentPrototype: true,
      status: 'received',
      createdAt: serverTimestamp(),
    });

    txn.set(
      firestore.collection('stats').doc('platform'),
      {
        prototypeDonationTaka: admin.firestore.FieldValue.increment(amountTaka),
        prototypeDonationsReceived: admin.firestore.FieldValue.increment(1),
      },
      { merge: true },
    );

    return {
      donationId,
      initiative,
      amountTaka,
      settlementMethod,
      paymentStatus: 'paid',
      paymentReference,
      paymentPrototype: true,
      repeated: false,
    };
  });
}

module.exports = {
  DonationError,
  INITIATIVES,
  MAX_POINTS,
  MAX_TAKA,
  MIN_POINTS,
  MIN_TAKA,
  PROTOTYPE_PAYMENT_METHODS,
  donatePoints,
  donatePrototypePayment,
  validateDonation,
  validatePrototypeDonation,
};
