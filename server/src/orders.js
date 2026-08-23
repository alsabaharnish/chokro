/**
 * Chokro — order fulfilment and the purchase award (F4.6, F4.7, F4.8).
 *
 * §6.3 assigns the transitions by party: `pending` on creation, `shipped` and
 * `delivered` set by the seller, `confirmed` set by the buyer — and only
 * `confirmed` releases purchase points.
 *
 * WHY ALL THREE TRANSITIONS LIVE HERE RATHER THAN IN THE RULES
 * Two of them are expressible in `firestore.rules`; the third is not.
 * `confirmed` credits a wallet, and a rule permitting the buyer to write it
 * would be a rule permitting a client to trigger a payout — the one thing this
 * system does not allow anywhere else. Splitting the machine so that two states
 * were rules-enforced and one was server-enforced would state a single
 * invariant in two places with different reasoning behind each, and the seam
 * would be exactly where the money is.
 *
 * So the whole machine is here, `orders` is denied to every client including
 * administrators, and `nextStatusFor` below is the only thing that decides.
 *
 * THE SPEND LOOP TERMINATES BY CREDITING
 * This file is what makes the earn and spend paths a *cycle* rather than a
 * pipeline (§7.1): a buyer confirms receipt and is credited `source=purchase`,
 * which is the fourth ledger source and the one that closes the demonstration.
 */

const { db, admin, serverTimestamp } = require('./firebase');
const policyModule = require('./pointsPolicy');
const { creditWalletInTransaction, SOURCES } = require('./award');

const STATUSES = Object.freeze(['pending', 'shipped', 'delivered', 'confirmed']);

/**
 * The next status this party may set, or null if there is nothing for them.
 *
 * Mirrors `OrderStatus.nextFor` in `lib/models/order_model.dart`, which exists
 * so a button that would be refused is never drawn. This copy is the one that
 * enforces.
 *
 * The seller's branch stopping at `delivered` is the rule that a seller cannot
 * confirm their own delivery. Without it, one party would control both ends of
 * a two-party confirmation, and the purchase award would rest on nothing.
 */
function nextStatusFor(current, { isSeller }) {
  if (isSeller) {
    if (current === 'pending') return 'shipped';
    if (current === 'shipped') return 'delivered';
    return null;
  }
  return current === 'delivered' ? 'confirmed' : null;
}

/**
 * Advances an order along the seller's half of the machine.
 *
 * Marking a cash-on-delivery order `delivered` also records payment. A prototype
 * online order is already marked paid at checkout, so the same update is
 * harmless and keeps legacy records moving toward a settled state.
 */
async function advanceOrder({ orderId, actorUid, status }) {
  if (!STATUSES.includes(status)) {
    throw new Error('That is not an order status.');
  }

  const firestore = db();
  const orderRef = firestore.collection('orders').doc(orderId);

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(orderRef);
    if (!snap.exists) throw new Error('That order no longer exists.');

    const order = snap.data();

    if (order.sellerId !== actorUid) {
      throw new Error('Only the Greenpreneur can update this order.');
    }

    const expected = nextStatusFor(order.status, { isSeller: true });

    if (expected === null) {
      throw new Error(
        `There is nothing more for you to do on this order (${order.status}).`,
      );
    }
    // Naming the expected step rather than accepting whatever was asked for is
    // what keeps the machine ordered: a seller cannot jump straight to
    // delivered, and a stale screen cannot replay a transition.
    if (status !== expected) {
      throw new Error(
        `This order is ${order.status}; the next step is ${expected}.`,
      );
    }

    const update = {
      status,
      [status === 'shipped' ? 'shippedAt' : 'deliveredAt']: serverTimestamp(),
    };

    if (status === 'delivered') update.paymentStatus = 'paid';

    txn.update(orderRef, update);

    return { orderId, status, paymentStatus: update.paymentStatus ?? order.paymentStatus };
  });
}

/**
 * The buyer confirms receipt, closing the order and releasing purchase points.
 *
 * The award is computed from the order's **payable** figure, not its subtotal:
 * points already redeemed do not earn points back, which would otherwise be a
 * slow leak out of the economy (§7.3). It is then snapshotted onto the order, so
 * an administrator lowering `purchaseAwardPercent` next month does not rewrite
 * what this order was worth (§6.2).
 *
 * Idempotent through the status check: a confirmed order cannot be confirmed
 * again, so a retried request after a lost response cannot credit twice.
 */
async function confirmOrder({ orderId, buyerUid }) {
  const firestore = db();
  const orderRef = firestore.collection('orders').doc(orderId);
  const walletRef = firestore.collection('wallets').doc(buyerUid);
  const configRef = firestore.collection('config').doc('points');

  return firestore.runTransaction(async (txn) => {
    // ---- reads first ----
    const [orderSnap, walletSnap, configSnap] = await txn.getAll(
      orderRef,
      walletRef,
      configRef,
    );

    if (!orderSnap.exists) throw new Error('That order no longer exists.');

    const order = orderSnap.data();

    if (order.buyerId !== buyerUid) {
      throw new Error('Only the Champion can confirm this order.');
    }
    // Belt and braces against a document written before self-dealing was
    // refused at checkout. One party on both sides of a two-party confirmation
    // is exactly the shape the purchase award must not reward.
    if (order.sellerId === buyerUid) {
      throw new Error('An order cannot be confirmed by its own Greenpreneur.');
    }
    if (nextStatusFor(order.status, { isSeller: false }) !== 'confirmed') {
      throw new Error(
        order.status === 'confirmed'
          ? 'You have already confirmed this order.'
          : 'Confirm this once the Greenpreneur has marked it delivered.',
      );
    }
    if (!walletSnap.exists) throw new Error('No wallet exists for this account.');

    const policy = policyModule.fromDoc(
      configSnap.exists ? configSnap.data() : null,
    );

    if (!Number.isSafeInteger(order.payable) || order.payable < 0) {
      throw new Error('That order has an invalid payable amount.');
    }
    const payable = order.payable;
    const award = policyModule.purchaseAward(policy, payable);

    // ---- writes ----
    let balanceAfter = walletSnap.data().balance;
    if (!Number.isSafeInteger(balanceAfter) || balanceAfter < 0) {
      throw new Error('This wallet has an invalid balance.');
    }

    if (award > 0) {
      // Through `award.js`, like every other credit in the system.
      balanceAfter = creditWalletInTransaction(txn, {
        uid: buyerUid,
        delta: award,
        source: SOURCES.PURCHASE,
        refId: orderId,
        currentBalance: balanceAfter,
      });
    }
    // An award of zero is legitimate — 5% of a ৳15 order rounds down to nothing
    // — and must not write a ledger entry, because `creditWalletInTransaction`
    // refuses a zero delta and a zero-value entry would say nothing anyway. The
    // order still closes.

    txn.update(orderRef, {
      status: 'confirmed',
      confirmedAt: serverTimestamp(),
      // Snapshotted at decision time (§6.2).
      pointsAwarded: award,
      // A confirmed order has been paid by definition. This is already true for
      // prototype online records and repairs a cash order whose delivery step
      // somehow did not record it.
      paymentStatus: 'paid',
    });

    txn.set(
      firestore.collection('stats').doc('platform'),
      {
        ordersConfirmed: admin.firestore.FieldValue.increment(1),
        pointsIssued: admin.firestore.FieldValue.increment(award),
      },
      { merge: true },
    );

    return {
      orderId,
      status: 'confirmed',
      pointsAwarded: award,
      balanceAfter,
    };
  });
}

module.exports = {
  STATUSES,
  nextStatusFor,
  advanceOrder,
  confirmOrder,
};
