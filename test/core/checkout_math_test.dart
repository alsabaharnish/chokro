import 'package:chokro/core/checkout_math.dart';
import 'package:chokro/core/points_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const policy = PointsPolicy.defaults;

  CartLine line({
    required String seller,
    required int price,
    int qty = 1,
    String? productId,
  }) =>
      CartLine(
        productId: productId ?? '$seller-$price-$qty',
        sellerId: seller,
        shopName: 'Shop $seller',
        title: 'Item at $price',
        unitPrice: price,
        qty: qty,
      );

  group('allocateDiscount', () {
    test('gives everything to a single group', () {
      expect(allocateDiscount([500], 50), [50]);
    });

    test('splits proportionally when the division is exact', () {
      expect(allocateDiscount([300, 100], 40), [30, 10]);
    });

    test('distributes the remainder so the parts sum to the whole', () {
      // Three equal groups sharing 50 taka: exact shares are 16.66 each.
      final shares = allocateDiscount([100, 100, 100], 50);
      expect(shares.fold<int>(0, (a, b) => a + b), 50);
      expect(shares, [17, 17, 16]);
    });

    test('matches the Node copy on the uneven case', () {
      // The same figures as server/test/checkout.test.js. The client shows the
      // buyer a figure and the server charges one; a divergence here is the
      // buyer being charged something other than what they were shown.
      expect(allocateDiscount([333, 667], 49), [16, 33]);
    });

    test('never gives a group more discount than its own subtotal', () {
      final shares = allocateDiscount([10, 1000], 500);
      expect(shares[0], lessThanOrEqualTo(10));
      expect(shares.fold<int>(0, (a, b) => a + b), 500);
    });

    test('returns zeros for no discount, and for empty input', () {
      expect(allocateDiscount([100, 200], 0), [0, 0]);
      expect(allocateDiscount([], 50), isEmpty);
    });

    test('caps at the total when asked for more than exists', () {
      expect(allocateDiscount([100, 200], 999), [100, 200]);
    });

    test('breaks ties toward the earlier group, deterministically', () {
      expect(allocateDiscount([100, 100], 1), [1, 0]);
    });
  });

  group('groupBySeller', () {
    test('orders groups by seller id, not by insertion', () {
      final grouped = groupBySeller([
        line(seller: 'zeta', price: 10),
        line(seller: 'alpha', price: 10),
      ]);

      expect(grouped.first.first.sellerId, 'alpha');
      expect(grouped.last.first.sellerId, 'zeta');
    });

    test('keeps every line of one seller together', () {
      final grouped = groupBySeller([
        line(seller: 'a', price: 10),
        line(seller: 'b', price: 20),
        line(seller: 'a', price: 30),
      ]);

      expect(grouped.length, 2);
      expect(grouped.first.length, 2);
    });
  });

  group('quoteCheckout', () {
    test('sums the subtotal across sellers and quantities', () {
      final quote = quoteCheckout(
        lines: [
          line(seller: 'a', price: 100, qty: 2),
          line(seller: 'b', price: 50, qty: 3),
        ],
        policy: policy,
        balance: 0,
      );

      expect(quote.subtotal, 350);
      expect(quote.payable, 350);
      expect(quote.orderCount, 2);
    });

    test('applies no discount when no points are requested', () {
      final quote = quoteCheckout(
        lines: [line(seller: 'a', price: 500)],
        policy: policy,
        balance: 10000,
      );

      expect(quote.pointsApplied, 0);
      expect(quote.discount, 0);
      expect(quote.payable, 500);
    });

    test('redeems at 100 points to 10 taka', () {
      final quote = quoteCheckout(
        lines: [line(seller: 'a', price: 1000)],
        policy: policy,
        balance: 1000,
        pointsRequested: 500,
      );

      expect(quote.pointsApplied, 500);
      expect(quote.discount, 50);
      expect(quote.payable, 950);
    });

    test('clamps a request above the 50% ceiling and reports the ceiling', () {
      final quote = quoteCheckout(
        lines: [line(seller: 'a', price: 100)],
        policy: policy,
        balance: 100000,
        pointsRequested: 100000,
      );

      // Half of 100 taka is 50 taka, which costs 500 points.
      expect(quote.discount, 50);
      expect(quote.pointsApplied, 500);
      expect(quote.maxRedeemablePoints, 500);
    });

    test('clamps to the wallet balance when that is the tighter bound', () {
      final quote = quoteCheckout(
        lines: [line(seller: 'a', price: 1000)],
        policy: policy,
        balance: 130,
        pointsRequested: 130,
      );

      // 130 points buys 13 taka, and points are spent in whole-taka blocks.
      expect(quote.pointsApplied, 130);
      expect(quote.discount, 13);
      expect(quote.payable, 987);
    });

    test('per-group points always sum to the checkout total', () {
      final quote = quoteCheckout(
        lines: [
          line(seller: 'a', price: 100),
          line(seller: 'b', price: 100),
          line(seller: 'c', price: 100),
        ],
        policy: policy,
        balance: 5000,
        pointsRequested: 500,
      );

      final groupPoints =
          quote.groups.fold<int>(0, (sum, g) => sum + g.pointsApplied);
      final groupDiscount =
          quote.groups.fold<int>(0, (sum, g) => sum + g.discount);

      expect(groupPoints, quote.pointsApplied);
      expect(groupDiscount, quote.discount);
    });

    test('per-group payable always sums to the checkout payable', () {
      final quote = quoteCheckout(
        lines: [
          line(seller: 'a', price: 333),
          line(seller: 'b', price: 667),
        ],
        policy: policy,
        balance: 5000,
        pointsRequested: 490,
      );

      final groupPayable =
          quote.groups.fold<int>(0, (sum, g) => sum + g.payable);
      expect(groupPayable, quote.payable);
    });

    test('an empty cart quotes to nothing rather than throwing', () {
      final quote = quoteCheckout(lines: [], policy: policy, balance: 500);

      expect(quote.isEmpty, isTrue);
      expect(quote.subtotal, 0);
      expect(quote.payable, 0);
      expect(quote.pointsApplied, 0);
    });

    test('a negative points request is treated as none', () {
      final quote = quoteCheckout(
        lines: [line(seller: 'a', price: 100)],
        policy: policy,
        balance: 500,
        pointsRequested: -500,
      );

      expect(quote.pointsApplied, 0);
      expect(quote.payable, 100);
    });
  });

  group('CartLine', () {
    test('reports unavailability only when stock is known to be short', () {
      const known = CartLine(
        productId: 'p',
        sellerId: 's',
        shopName: 'Shop',
        title: 'Item',
        unitPrice: 10,
        qty: 5,
        stock: 2,
      );
      const unknown = CartLine(
        productId: 'p',
        sellerId: 's',
        shopName: 'Shop',
        title: 'Item',
        unitPrice: 10,
        qty: 5,
      );

      expect(known.isAvailable, isFalse);
      expect(unknown.isAvailable, isTrue);
    });
  });
}
