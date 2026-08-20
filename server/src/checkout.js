/**
 * Chokro — checkout (F4.4, F4.5).
 *
 * ONE TRANSACTION, OR NOTHING.
 *
 * A checkout is the only operation in this system that touches four kinds of
 * document at once: it decrements stock, debits a wallet, writes a ledger entry,
 * creates one order per seller and empties the cart. Every one of those has to
 * commit together. Stock decremented without an order is inventory destroyed;
 * an order without a debit is goods given away; a debit without a ledger entry
 * breaks NFR-4, under which a balance must be reconstructable from history.
 *
 * That is also what makes the stock race resolve cleanly (§7.4): the decrement
 * lives inside the same transaction as the order write, so two buyers going for
 * the last unit produce one success and one clean failure, never two orders and
 * a negative stock count.
 *
 * NOTHING IN THE REQUEST IS TRUSTED.
 * The client sends a points figure and a settlement method. Every price, every
 * stock level, every seller id and the wallet balance are read here, inside the
 * transaction, from stored documents. The client's own quote — computed by
 * `lib/core/checkout_math.dart` so the buyer can see a total before committing —
 * is display only, and this file recomputes all of it.
 */

const { db, admin, serverTimestamp } = require('./firebase');
const policyModule = require('./pointsPolicy');
const { creditWalletInTransaction, SOURCES } = require('./award');
const { isTradingProfile } = require('./suspension');

/** The only settlement method there is. No card data lives in any schema (§6.2). */
const SETTLEMENT_METHODS = Object.freeze(['cashOnDelivery']);

const MAX_CART_ITEMS = 20;
const MAX_LINE_QTY = 20;

/**
 * Splits a discount across seller subtotals, in whole taka.
 *
 * Largest-remainder, and a byte-for-byte mirror of `allocateDiscount` in
 * `lib/core/checkout_math.dart`. Flooring alone loses taka — three ৳100 orders
 * sharing ৳50 floor to 16+16+16 and drop ৳2 — and a lost taka is a taka the
 * buyer spent points on and did not receive. The leftovers go to the largest
 * fractional remainders so the parts always sum to the whole.
 *
 * Remainders are compared as scaled integers rather than floats: a
 * floating-point tie can break differently between two runtimes, and the client
 * and the server must agree.
 */
function allocateDiscount(subtotals, discount) {
  const total = subtotals.reduce((sum, value) => sum + value, 0);
  if (subtotals.length === 0 || discount <= 0 || total <= 0) {
    return subtotals.map(() => 0);
  }
  if (discount >= total) return [...subtotals];

  const shares = [];
  const remainders = [];

  for (const subtotal of subtotals) {
    const product = subtotal * discount;
    shares.push(Math.trunc(product / total));
    remainders.push(product % total);
  }

  let leftover = discount - shares.reduce((sum, value) => sum + value, 0);

  const order = subtotals
    .map((_, index) => index)
    .sort((a, b) => remainders[b] - remainders[a] || a - b);

  let cursor = 0;
  while (leftover > 0 && cursor < order.length) {
    const index = order[cursor];
    if (shares[index] < subtotals[index]) {
      shares[index] += 1;
      leftover -= 1;
    }
    cursor += 1;
    if (cursor === order.length && leftover > 0) cursor = 0;
  }

  return shares;
}

/**
 * Groups resolved lines by seller, ordered by seller id.
 *
 * Ordered rather than insertion-order for the same reason the Dart copy is: the
 * discount is allocated across groups in list order, and the two sides have to
 * produce identical arithmetic from the same cart. Insertion order depends on
 * how the buyer built the cart, which this side never sees.
 */
function groupBySeller(lines) {
  const bySeller = new Map();
  for (const line of lines) {
    if (!bySeller.has(line.sellerId)) bySeller.set(line.sellerId, []);
    bySeller.get(line.sellerId).push(line);
  }
  return [...bySeller.keys()].sort().map((sellerId) => ({
    sellerId,
    lines: bySeller.get(sellerId),
  }));
}

/**
 * Reads the cart array into `{productId, qty}` pairs, refusing anything else.
 *
 * Rules validate all 20 bounded slots before storage. This second validation is
 * still required because the Admin SDK bypasses rules and legacy or imported
 * data can exist. A malformed entry fails rather than being quietly skipped.
 */
function readCartItems(cartData) {
  const raw = cartData && Array.isArray(cartData.items) ? cartData.items : [];

  if (raw.length === 0) throw new Error('Your cart is empty.');
  if (raw.length > MAX_CART_ITEMS) {
    throw new Error(`A cart may hold at most ${MAX_CART_ITEMS} products.`);
  }

  const seen = new Set();
  const items = [];

  for (const entry of raw) {
    if (
      !entry ||
      typeof entry !== 'object' ||
      Array.isArray(entry) ||
      Object.keys(entry).length !== 2 ||
      !Object.prototype.hasOwnProperty.call(entry, 'productId') ||
      !Object.prototype.hasOwnProperty.call(entry, 'qty')
    ) {
      throw new Error('Your cart could not be read. Empty it and try again.');
    }
    const { productId, qty } = entry;

    if (typeof productId !== 'string' || productId.length === 0) {
      throw new Error('Your cart could not be read. Empty it and try again.');
    }
    if (seen.has(productId)) {
      // Two lines for one product would decrement stock twice against a single
      // availability check.
      throw new Error('Your cart lists the same product twice.');
    }
    if (!Number.isInteger(qty) || qty < 1 || qty > MAX_LINE_QTY) {
      throw new Error(`Quantities must be between 1 and ${MAX_LINE_QTY}.`);
    }

    seen.add(productId);
    items.push({ productId, qty });
  }

  return items;
}

/**
 * Places the buyer's cart as one order per seller.
 *
 * @param {object} args
 * @param {string} args.buyerUid          from the verified token, never the body
 * @param {number} args.pointsRequested   clamped, not trusted
 * @param {string} args.settlementMethod
 * @returns {Promise<object>} the checkout summary
 */
async function checkout({
  buyerUid,
  pointsRequested = 0,
  settlementMethod = 'cashOnDelivery',
}) {
  if (!SETTLEMENT_METHODS.includes(settlementMethod)) {
    throw new Error('That settlement method is not supported.');
  }

  const firestore = db();
  const cartRef = firestore.collection('carts').doc(buyerUid);
  const walletRef = firestore.collection('wallets').doc(buyerUid);
  const buyerRef = firestore.collection('users').doc(buyerUid);
  const configRef = firestore.collection('config').doc('points');

  // Allocated before the transaction so a retried attempt reuses the same ids
  // rather than scattering half-written orders under fresh ones.
  const checkoutId = firestore.collection('orders').doc().id;

  return firestore.runTransaction(async (txn) => {
    // ---- every read first; Firestore requires reads to precede writes ----
    const cartSnap = await txn.get(cartRef);
    if (!cartSnap.exists) throw new Error('Your cart is empty.');

    const items = readCartItems(cartSnap.data());

    const productRefs = items.map((item) =>
      firestore.collection('products').doc(item.productId),
    );

    const [walletSnap, buyerSnap, configSnap, ...productSnaps] = await txn.getAll(
      walletRef,
      buyerRef,
      configRef,
      ...productRefs,
    );

    if (!walletSnap.exists) throw new Error('No wallet exists for this account.');
    if (!buyerSnap.exists) throw new Error('No profile exists for this account.');

    const policy = policyModule.fromDoc(
      configSnap.exists ? configSnap.data() : null,
    );

    // Resolve every line against the stored listing. This is where a client's
    // idea of a price stops mattering.
    const lines = [];
    for (let i = 0; i < items.length; i += 1) {
      const snap = productSnaps[i];
      const { productId, qty } = items[i];

      if (!snap.exists) {
        throw new Error('A product in your cart is no longer listed.');
      }

      const product = snap.data();

      if (product.active !== true) {
        throw new Error(`"${product.title}" is no longer for sale.`);
      }
      if (
        !Number.isSafeInteger(product.price) ||
        product.price < 1 ||
        product.price > 1000000
      ) {
        throw new Error(`"${product.title}" has no valid price.`);
      }
      if (
        !Number.isSafeInteger(product.stock) ||
        product.stock < qty ||
        product.stock > 100000
      ) {
        throw new Error(
          `"${product.title}" has only ${product.stock || 0} left.`,
        );
      }
      // Self-dealing (§7.4). Enforced here as well as in the interface, because
      // the interface is not where it counts: buying from yourself would earn
      // purchase points for moving money between your own hands.
      if (product.sellerId === buyerUid) {
        throw new Error('You cannot buy your own listing.');
      }
      if (typeof product.sellerId !== 'string' || product.sellerId.length === 0) {
        throw new Error(`"${product.title}" no longer has a valid seller.`);
      }

      lines.push({
        ref: snap.ref,
        productId,
        qty,
        sellerId: product.sellerId,
        shopName: typeof product.shopName === 'string' ? product.shopName : '',
        title: typeof product.title === 'string' ? product.title : 'Item',
        unitPrice: product.price,
        stock: product.stock,
      });
    }

    const groups = groupBySeller(lines);

    // Seller profiles, for the verified name and current trading authority. A
    // suspended seller's listings are swept out of the catalogue, but a cart
    // filled before the sweep would otherwise still close. Checking the role as
    // well prevents new orders after an administrator demotes a seller while an
    // old listing is still active.
    const sellerRefs = groups.map((group) =>
      firestore.collection('users').doc(group.sellerId),
    );
    const sellerSnaps = sellerRefs.length ? await txn.getAll(...sellerRefs) : [];

    const sellerNames = new Map();
    for (let i = 0; i < groups.length; i += 1) {
      const snap = sellerSnaps[i];
      if (!snap.exists) {
        throw new Error('A seller in your cart no longer has an account.');
      }
      const seller = snap.data();
      if (!isTradingProfile(seller)) {
        throw new Error(
          `${seller.name || 'A seller'} is not currently trading. Remove their ` +
            'items to continue.',
        );
      }
      sellerNames.set(groups[i].sellerId, seller.name || 'A seller');
    }

    // ---- arithmetic, recomputed from stored values ----
    const subtotals = groups.map((group) =>
      group.lines.reduce((sum, line) => sum + line.unitPrice * line.qty, 0),
    );
    const subtotal = subtotals.reduce((sum, value) => sum + value, 0);
    const balance = walletSnap.data().balance;
    if (!Number.isSafeInteger(balance) || balance < 0) {
      throw new Error('Your wallet has an invalid balance. Contact support.');
    }

    const redemption = policyModule.applyRedemption(policy, {
      subtotal,
      balance,
      pointsRequested,
    });

    const discounts = allocateDiscount(subtotals, redemption.discount);

    // ---- writes ----
    const buyerName = buyerSnap.data().name || 'A buyer';
    const orders = [];

    for (let i = 0; i < groups.length; i += 1) {
      const group = groups[i];
      const orderRef = firestore.collection('orders').doc();
      const discount = discounts[i];

      orders.push({
        orderId: orderRef.id,
        sellerId: group.sellerId,
        subtotal: subtotals[i],
        discount,
        payable: subtotals[i] - discount,
      });

      txn.set(orderRef, {
        buyerId: buyerUid,
        buyerName,
        sellerId: group.sellerId,
        sellerName: sellerNames.get(group.sellerId),
        shopName: group.lines[0].shopName,
        checkoutId,
        // Title and unit price SNAPSHOTTED (§6.2). A later rename or price
        // change must not rewrite what somebody bought.
        items: group.lines.map((line) => ({
          productId: line.productId,
          title: line.title,
          unitPrice: line.unitPrice,
          qty: line.qty,
        })),
        subtotal: subtotals[i],
        pointsApplied: policyModule.pointsToSpendForTaka(policy, discount),
        discount,
        payable: subtotals[i] - discount,
        settlementMethod,
        // Cash on delivery: nothing has been paid yet, and the points side is
        // settled separately and immediately below.
        paymentStatus: 'pending',
        status: 'pending',
        pointsAwarded: null,
        createdAt: serverTimestamp(),
      });
    }

    for (const line of lines) {
      txn.update(line.ref, {
        stock: admin.firestore.FieldValue.increment(-line.qty),
        updatedAt: serverTimestamp(),
      });
    }

    let balanceAfter = balance;
    if (redemption.pointsApplied > 0) {
      // Through `award.js`, like every other balance change. One debit for the
      // whole checkout, referenced by `checkoutId`, so the ledger reads as one
      // purchase even when it produced three orders.
      balanceAfter = creditWalletInTransaction(txn, {
        uid: buyerUid,
        delta: -redemption.pointsApplied,
        source: SOURCES.REDEMPTION,
        refId: checkoutId,
        currentBalance: balance,
      });
    }

    // The cart is consumed. Deleted rather than emptied so the next write
    // creates it fresh with a server timestamp.
    txn.delete(cartRef);

    txn.set(
      firestore.collection('stats').doc('platform'),
      {
        ordersCreated: admin.firestore.FieldValue.increment(orders.length),
        pointsRedeemed: admin.firestore.FieldValue.increment(
          redemption.pointsApplied,
        ),
        salesPayable: admin.firestore.FieldValue.increment(redemption.payable),
      },
      { merge: true },
    );

    return {
      checkoutId,
      orders,
      subtotal,
      pointsApplied: redemption.pointsApplied,
      discount: redemption.discount,
      payable: redemption.payable,
      balanceAfter,
      settlementMethod,
    };
  });
}

module.exports = {
  SETTLEMENT_METHODS,
  MAX_CART_ITEMS,
  MAX_LINE_QTY,
  allocateDiscount,
  groupBySeller,
  readCartItems,
  checkout,
};
