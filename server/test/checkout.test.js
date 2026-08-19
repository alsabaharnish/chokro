/**
 * Pure unit tests for the checkout arithmetic and the order status machine
 * (F4.4-F4.7).
 *
 * No Firebase, no network. `allocateDiscount`, `groupBySeller`, `readCartItems`
 * and `nextStatusFor` are written as separate functions from the transaction
 * that uses them precisely so that the parts deciding what a buyer pays and who
 * may credit a wallet can be tested directly.
 *
 * The discount cases here are the same worked examples as
 * `test/core/checkout_math_test.dart`. That duplication is the point: the client
 * shows the buyer a figure and the server charges one, and if the two ever
 * disagree the buyer is right to complain. Matching tests on both sides are what
 * catch a drift between the copies.
 */

const {
  allocateDiscount,
  groupBySeller,
  readCartItems,
  MAX_CART_ITEMS,
  MAX_LINE_QTY,
  SETTLEMENT_METHODS,
} = require('../src/checkout');

const { nextStatusFor, STATUSES } = require('../src/orders');

const policyModule = require('../src/pointsPolicy');

const POLICY = policyModule.defaults();

// ---------------------------------------------------------------------------
// Discount allocation
// ---------------------------------------------------------------------------

describe('allocateDiscount', () => {
  it('gives everything to a single group', () => {
    expect(allocateDiscount([500], 50)).toEqual([50]);
  });

  it('splits proportionally when the division is exact', () => {
    expect(allocateDiscount([300, 100], 40)).toEqual([30, 10]);
  });

  it('distributes the remainder so the parts sum to the whole', () => {
    const shares = allocateDiscount([100, 100, 100], 50);

    expect(shares.reduce((a, b) => a + b, 0)).toBe(50);
    expect(shares).toEqual([17, 17, 16]);
  });

  it('matches the Dart copy on the uneven case', () => {
    // Same figures as test/core/checkout_math_test.dart. A divergence here is
    // the buyer being charged something other than what they were shown.
    expect(allocateDiscount([333, 667], 49)).toEqual(
      // 333*49/1000 = 16.317 -> 16 (remainder 317)
      // 667*49/1000 = 32.683 -> 32 (remainder 683), takes the leftover taka
      [16, 33],
    );
  });

  it('never gives a group more discount than its own subtotal', () => {
    const shares = allocateDiscount([10, 1000], 500);

    expect(shares[0]).toBeLessThanOrEqual(10);
    expect(shares.reduce((a, b) => a + b, 0)).toBe(500);
  });

  it('returns zeros for no discount and for empty input', () => {
    expect(allocateDiscount([100, 200], 0)).toEqual([0, 0]);
    expect(allocateDiscount([], 50)).toEqual([]);
  });

  it('caps at the total when asked for more than exists', () => {
    expect(allocateDiscount([100, 200], 999)).toEqual([100, 200]);
  });

  it('breaks ties toward the earlier group, deterministically', () => {
    expect(allocateDiscount([100, 100], 1)).toEqual([1, 0]);
  });
});

// ---------------------------------------------------------------------------
// Grouping
// ---------------------------------------------------------------------------

describe('groupBySeller', () => {
  const line = (sellerId, productId) => ({ sellerId, productId });

  it('orders groups by seller id, not by insertion', () => {
    const groups = groupBySeller([line('zeta', 'p1'), line('alpha', 'p2')]);

    expect(groups.map((g) => g.sellerId)).toEqual(['alpha', 'zeta']);
  });

  it('keeps every line of one seller together', () => {
    const groups = groupBySeller([
      line('a', 'p1'),
      line('b', 'p2'),
      line('a', 'p3'),
    ]);

    expect(groups).toHaveLength(2);
    expect(groups[0].lines).toHaveLength(2);
  });

  it('a multi-seller cart becomes one order per seller', () => {
    // §7.4: a cart may hold several sellers, but an order carries one sellerId.
    const groups = groupBySeller([line('a', 'p1'), line('b', 'p2'), line('c', 'p3')]);
    expect(groups).toHaveLength(3);
  });
});

// ---------------------------------------------------------------------------
// Cart parsing — the "enforced where it is read" half of the rules bargain
// ---------------------------------------------------------------------------

describe('readCartItems', () => {
  it('reads a well-formed cart', () => {
    expect(readCartItems({ items: [{ productId: 'p1', qty: 2 }] })).toEqual([
      { productId: 'p1', qty: 2 },
    ]);
  });

  it('refuses an empty cart', () => {
    expect(() => readCartItems({ items: [] })).toThrow(/empty/i);
    expect(() => readCartItems(null)).toThrow(/empty/i);
  });

  it('refuses a cart beyond the item ceiling', () => {
    const items = Array.from({ length: MAX_CART_ITEMS + 1 }, (_, i) => ({
      productId: `p${i}`,
      qty: 1,
    }));
    expect(() => readCartItems({ items })).toThrow(/at most/i);
  });

  it('refuses the same product listed twice', () => {
    // Two lines for one product would decrement stock twice against a single
    // availability check.
    expect(() =>
      readCartItems({
        items: [
          { productId: 'p1', qty: 1 },
          { productId: 'p1', qty: 1 },
        ],
      }),
    ).toThrow(/twice/i);
  });

  it('refuses a quantity of zero, a negative one and a fractional one', () => {
    for (const qty of [0, -1, 1.5]) {
      expect(() => readCartItems({ items: [{ productId: 'p1', qty }] })).toThrow(
        /Quantities/,
      );
    }
  });

  it('refuses a quantity past the line ceiling', () => {
    expect(() =>
      readCartItems({ items: [{ productId: 'p1', qty: MAX_LINE_QTY + 1 }] }),
    ).toThrow(/Quantities/);
  });

  it('fails rather than silently dropping a malformed line', () => {
    // Skipping a line the buyer believes they are buying is worse than saying
    // the cart is broken.
    expect(() =>
      readCartItems({ items: [{ productId: 'p1', qty: 1 }, 'nonsense'] }),
    ).toThrow();
    expect(() =>
      readCartItems({ items: [{ qty: 1 }] }),
    ).toThrow();
    expect(() =>
      readCartItems({ items: [{ productId: '', qty: 1 }] }),
    ).toThrow();
  });

  it('ignores anything a client parked alongside the two real keys', () => {
    // The rules do not check element shape (they cannot iterate a list), so a
    // cached price CAN reach the document. It must never reach the arithmetic.
    const items = readCartItems({
      items: [{ productId: 'p1', qty: 2, unitPrice: 1, subtotal: 1 }],
    });

    expect(items).toEqual([{ productId: 'p1', qty: 2 }]);
  });
});

// ---------------------------------------------------------------------------
// Redemption, against the same policy the client reads
// ---------------------------------------------------------------------------

describe('redemption arithmetic mirrors points_policy.dart', () => {
  it('redeems at 100 points to 10 taka', () => {
    expect(
      policyModule.applyRedemption(POLICY, {
        subtotal: 1000,
        balance: 1000,
        pointsRequested: 500,
      }),
    ).toEqual({ subtotal: 1000, pointsApplied: 500, discount: 50, payable: 950 });
  });

  it('clamps at half the subtotal — points supplement payment', () => {
    const outcome = policyModule.applyRedemption(POLICY, {
      subtotal: 100,
      balance: 100000,
      pointsRequested: 100000,
    });

    expect(outcome.discount).toBe(50);
    expect(outcome.pointsApplied).toBe(500);
  });

  it('clamps to the wallet balance when that is tighter', () => {
    const outcome = policyModule.applyRedemption(POLICY, {
      subtotal: 1000,
      balance: 130,
      pointsRequested: 130,
    });

    expect(outcome.pointsApplied).toBe(130);
    expect(outcome.discount).toBe(13);
  });

  it('spends points only in whole-taka blocks', () => {
    // 137 points is 13 taka and 7 points left over. Spending the remainder would
    // put a partial block in the ledger and it would stop reconciling.
    const outcome = policyModule.applyRedemption(POLICY, {
      subtotal: 1000,
      balance: 137,
      pointsRequested: 137,
    });

    expect(outcome.pointsApplied).toBe(130);
    expect(outcome.pointsApplied % policyModule.pointsPerTaka(POLICY)).toBe(0);
  });

  it('treats a negative or absent request as none', () => {
    for (const pointsRequested of [-500, undefined, NaN, 'lots']) {
      expect(
        policyModule.applyRedemption(POLICY, {
          subtotal: 500,
          balance: 500,
          pointsRequested,
        }).pointsApplied,
      ).toBe(0);
    }
  });

  it('per-group points always sum to the checkout total', () => {
    const subtotals = [100, 100, 100];
    const outcome = policyModule.applyRedemption(POLICY, {
      subtotal: 300,
      balance: 5000,
      pointsRequested: 500,
    });
    const discounts = allocateDiscount(subtotals, outcome.discount);

    const groupPoints = discounts.reduce(
      (sum, d) => sum + policyModule.pointsToSpendForTaka(POLICY, d),
      0,
    );

    expect(groupPoints).toBe(outcome.pointsApplied);
  });
});

describe('purchase award', () => {
  it('is a percentage of payable, not of subtotal', () => {
    // Points already redeemed must not earn points back — that is a slow leak.
    expect(policyModule.purchaseAward(POLICY, 1000)).toBe(50);
    expect(policyModule.purchaseAward(POLICY, 950)).toBe(47);
  });

  it('rounds down, and a small order can legitimately earn nothing', () => {
    expect(policyModule.purchaseAward(POLICY, 15)).toBe(0);
  });

  it('never awards on a zero or negative payable', () => {
    expect(policyModule.purchaseAward(POLICY, 0)).toBe(0);
    expect(policyModule.purchaseAward(POLICY, -100)).toBe(0);
  });
});

// ---------------------------------------------------------------------------
// The status machine (F4.6, F4.7)
// ---------------------------------------------------------------------------

describe('nextStatusFor', () => {
  it('a seller ships, then delivers', () => {
    expect(nextStatusFor('pending', { isSeller: true })).toBe('shipped');
    expect(nextStatusFor('shipped', { isSeller: true })).toBe('delivered');
  });

  it('THE ONE THAT MATTERS: a seller cannot confirm their own delivery', () => {
    // One party on both ends of a two-party confirmation would leave the
    // purchase award resting on nothing.
    expect(nextStatusFor('delivered', { isSeller: true })).toBeNull();
  });

  it('a buyer confirms only after the seller marks it delivered', () => {
    expect(nextStatusFor('pending', { isSeller: false })).toBeNull();
    expect(nextStatusFor('shipped', { isSeller: false })).toBeNull();
    expect(nextStatusFor('delivered', { isSeller: false })).toBe('confirmed');
  });

  it('a confirmed order is finished for both parties', () => {
    expect(nextStatusFor('confirmed', { isSeller: true })).toBeNull();
    expect(nextStatusFor('confirmed', { isSeller: false })).toBeNull();
  });

  it('an unrecognised stored status offers a seller nothing', () => {
    expect(nextStatusFor('cancelled', { isSeller: true })).toBeNull();
    expect(nextStatusFor(undefined, { isSeller: false })).toBeNull();
  });

  it('agrees with the vocabulary the Dart model parses', () => {
    expect(STATUSES).toEqual(['pending', 'shipped', 'delivered', 'confirmed']);
  });
});

describe('settlement', () => {
  it('offers cash on delivery and nothing that stores card data', () => {
    // §6.2: no payment card data in any schema.
    expect(SETTLEMENT_METHODS).toEqual(['cashOnDelivery']);
  });
});
