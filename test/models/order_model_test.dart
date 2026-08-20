import 'package:chokro/models/order_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  OrderModel order({
    OrderStatus status = OrderStatus.pending,
    String buyerId = 'buyer_uid',
    String sellerId = 'seller_uid',
  }) => OrderModel(
    id: 'o1',
    buyerId: buyerId,
    buyerName: 'Buyer',
    sellerId: sellerId,
    sellerName: 'Seller',
    shopName: 'Green Corner',
    checkoutId: 'c1',
    items: const [
      OrderLine(productId: 'p1', title: 'Bamboo brush', unitPrice: 250, qty: 2),
    ],
    subtotal: 500,
    pointsApplied: 200,
    discount: 20,
    payable: 480,
    settlementMethod: SettlementMethod.cashOnDelivery,
    paymentStatus: PaymentStatus.pending,
    status: status,
  );

  group('status machine', () {
    test('a seller ships, then delivers', () {
      expect(
        OrderStatus.nextFor(OrderStatus.pending, isSeller: true),
        OrderStatus.shipped,
      );
      expect(
        OrderStatus.nextFor(OrderStatus.shipped, isSeller: true),
        OrderStatus.delivered,
      );
    });

    test('a seller cannot confirm their own delivery', () {
      expect(
        OrderStatus.nextFor(OrderStatus.delivered, isSeller: true),
        isNull,
      );
    });

    test('a buyer confirms only once the seller has marked it delivered', () {
      expect(OrderStatus.nextFor(OrderStatus.pending, isSeller: false), isNull);
      expect(OrderStatus.nextFor(OrderStatus.shipped, isSeller: false), isNull);
      expect(
        OrderStatus.nextFor(OrderStatus.delivered, isSeller: false),
        OrderStatus.confirmed,
      );
    });

    test('a confirmed order is finished for both parties', () {
      expect(
        OrderStatus.nextFor(OrderStatus.confirmed, isSeller: true),
        isNull,
      );
      expect(
        OrderStatus.nextFor(OrderStatus.confirmed, isSeller: false),
        isNull,
      );
      expect(OrderStatus.confirmed.isTerminal, isTrue);
    });

    test('an unrecognised stored status reads as pending, never confirmed', () {
      expect(OrderStatus.fromName('settled'), OrderStatus.pending);
      expect(OrderStatus.fromName(null), OrderStatus.pending);
    });
  });

  group('nextStatusFor resolves the party from the order itself', () {
    test('offers the seller the shipping step', () {
      expect(order().nextStatusFor('seller_uid'), OrderStatus.shipped);
    });

    test('offers the buyer nothing until delivery', () {
      expect(order().nextStatusFor('buyer_uid'), isNull);
      expect(
        order(status: OrderStatus.delivered).nextStatusFor('buyer_uid'),
        OrderStatus.confirmed,
      );
    });

    test('offers a stranger nothing at all', () {
      expect(
        order(status: OrderStatus.delivered).nextStatusFor('someone_else'),
        isNull,
      );
    });

    test('a buyer who is also the seller still cannot confirm as the seller', () {
      // Self-dealing is refused at checkout (§7.4), so this order cannot exist;
      // the model resolving seller-first is what makes the impossible case fail
      // closed rather than granting the confirm-and-credit transition.
      final self = order(
        status: OrderStatus.delivered,
        buyerId: 'x',
        sellerId: 'x',
      );
      expect(self.nextStatusFor('x'), isNull);
    });
  });

  group('parsing', () {
    test('reads the fields the server writes', () {
      final parsed = OrderModel.fromMap({
        'buyerId': 'b',
        'buyerName': 'Buyer',
        'sellerId': 's',
        'sellerName': 'Seller',
        'shopName': 'Shop',
        'checkoutId': 'c',
        'items': [
          {'productId': 'p1', 'title': 'Item', 'unitPrice': 100, 'qty': 2},
        ],
        'subtotal': 200,
        'pointsApplied': 100,
        'discount': 10,
        'payable': 190,
        'settlementMethod': 'cashOnDelivery',
        'paymentStatus': 'paid',
        'status': 'delivered',
        'pointsAwarded': 9,
      }, id: 'o1');

      expect(parsed.items.single.lineTotal, 200);
      expect(parsed.itemCount, 2);
      expect(parsed.payable, 190);
      expect(parsed.paymentStatus, PaymentStatus.paid);
      expect(parsed.status, OrderStatus.delivered);
      expect(parsed.pointsAwarded, 9);
    });

    test('an empty document parses to a pending, unpaid, unrewarded order', () {
      final parsed = OrderModel.fromMap(null, id: 'o1');

      expect(parsed.status, OrderStatus.pending);
      expect(parsed.paymentStatus, PaymentStatus.pending);
      expect(parsed.pointsAwarded, isNull);
      expect(parsed.items, isEmpty);
    });

    test(
      'a line whose title is missing still names something to the buyer',
      () {
        final line = OrderLine.fromMap({
          'productId': 'p1',
          'unitPrice': 10,
          'qty': 1,
        });
        expect(line.title, isNotEmpty);
      },
    );

    test('an unparseable items array yields no lines rather than throwing', () {
      final parsed = OrderModel.fromMap({'items': 'nonsense'}, id: 'o1');
      expect(parsed.items, isEmpty);
    });

    test('malformed line entries and enum fields fail closed', () {
      final parsed = OrderModel.fromMap({
        'items': [
          'nonsense',
          {'productId': 'p1', 'title': 'Item', 'unitPrice': 10, 'qty': 1},
        ],
        'settlementMethod': 7,
        'paymentStatus': false,
        'status': <String>['confirmed'],
      }, id: 'o1');

      expect(parsed.items, hasLength(1));
      expect(parsed.status, OrderStatus.pending);
      expect(parsed.paymentStatus, PaymentStatus.pending);
      expect(parsed.settlementMethod, SettlementMethod.cashOnDelivery);
    });

    test('fractional money and quantities are not silently truncated', () {
      final parsed = OrderModel.fromMap({
        'items': [
          {'productId': 'p1', 'title': 'Item', 'unitPrice': 10.5, 'qty': 1.5},
        ],
        'subtotal': 10.5,
        'pointsAwarded': 5.5,
      }, id: 'o1');

      expect(parsed.items.single.unitPrice, 0);
      expect(parsed.items.single.qty, 0);
      expect(parsed.subtotal, 0);
      expect(parsed.pointsAwarded, isNull);
    });
  });

  test('subtotal, discount and payable stay consistent on a real order', () {
    final o = order();
    expect(o.subtotal - o.discount, o.payable);
    expect(o.items.fold<int>(0, (sum, l) => sum + l.lineTotal), o.subtotal);
  });
}
