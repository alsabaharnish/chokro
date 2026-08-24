import 'package:chokro/core/sales_report.dart';
import 'package:chokro/models/order_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// A seller reads their income off these numbers, so the arithmetic is pinned
/// rather than eyeballed on a screen.

OrderModel _order({
  String id = 'order-1',
  required int subtotal,
  int discount = 0,
  SettlementMethod method = SettlementMethod.cashOnDelivery,
  PaymentStatus payment = PaymentStatus.pending,
  OrderStatus status = OrderStatus.pending,
  DateTime? createdAt,
  int qty = 1,
  int pointsApplied = 0,
}) => OrderModel(
  id: id,
  buyerId: 'buyer-1',
  buyerName: 'Nadia Islam',
  sellerId: 'seller-1',
  sellerName: 'Rafiq Ahmed',
  shopName: 'Circular Goods',
  checkoutId: 'checkout-1',
  items: [
    OrderLine(
      productId: 'product-1',
      title: 'Recycled basket',
      unitPrice: subtotal,
      qty: qty,
    ),
  ],
  subtotal: subtotal,
  pointsApplied: pointsApplied,
  discount: discount,
  payable: subtotal - discount,
  settlementMethod: method,
  paymentStatus: payment,
  status: status,
  createdAt: createdAt,
);

void main() {
  // A fixed "now" so nothing here depends on when the suite runs.
  final now = DateTime(2026, 8, 24, 14, 30);

  group('period boundaries', () {
    test('today starts at local midnight, not 24 hours ago', () {
      expect(SalesPeriod.today.startFrom(now), DateTime(2026, 8, 24));
    });

    test('the rolling windows count today as day one', () {
      // "Last 7 days" is today plus the six before it, so the window is seven
      // days long and not eight.
      expect(SalesPeriod.week.startFrom(now), DateTime(2026, 8, 18));
      expect(SalesPeriod.month.startFrom(now), DateTime(2026, 7, 26));
      expect(SalesPeriod.quarter.startFrom(now), DateTime(2026, 5, 27));
    });

    test('all time has no lower bound', () {
      expect(SalesPeriod.allTime.startFrom(now), isNull);
    });

    test('day arithmetic normalises across a month and a year boundary', () {
      // 25 Feb, not 26: 2026 is not a leap year, so the seven days are
      // 25–28 Feb plus 1–3 Mar.
      expect(
        SalesPeriod.week.startFrom(DateTime(2026, 3, 3)),
        DateTime(2026, 2, 25),
      );
      expect(
        SalesPeriod.week.startFrom(DateTime(2026, 1, 2)),
        DateTime(2025, 12, 27),
      );
      // 2028 is a leap year: the 30-day window from 1 March must land on 1 Feb,
      // which it only does if 29 February exists.
      expect(
        SalesPeriod.month.startFrom(DateTime(2028, 3, 1)),
        DateTime(2028, 2, 1),
      );
    });
  });

  group('filtering', () {
    test('an order placed before the window is excluded', () {
      final report = SellerSalesReport.from(
        [
          _order(id: 'in', subtotal: 100, createdAt: DateTime(2026, 8, 24, 0)),
          _order(
            id: 'out',
            subtotal: 500,
            createdAt: DateTime(2026, 8, 23, 23, 59),
          ),
        ],
        period: SalesPeriod.today,
        now: now,
      );

      expect(report.orderCount, 1);
      expect(report.gross, 100);
    });

    test('midnight itself is inside today', () {
      final report = SellerSalesReport.from(
        [_order(subtotal: 100, createdAt: DateTime(2026, 8, 24))],
        period: SalesPeriod.today,
        now: now,
      );
      expect(report.orderCount, 1);
    });

    test('all time counts everything, however old', () {
      final report = SellerSalesReport.from(
        [
          _order(id: 'a', subtotal: 100, createdAt: DateTime(2020, 1, 1)),
          _order(id: 'b', subtotal: 250, createdAt: now),
        ],
        period: SalesPeriod.allTime,
        now: now,
      );
      expect(report.orderCount, 2);
      expect(report.gross, 350);
    });
  });

  group('money', () {
    test('net is gross less the points discount, and is the seller income', () {
      final report = SellerSalesReport.from(
        [
          _order(id: 'a', subtotal: 1000, discount: 150, createdAt: now),
          _order(id: 'b', subtotal: 500, discount: 0, createdAt: now),
        ],
        period: SalesPeriod.today,
        now: now,
      );

      expect(report.gross, 1500);
      expect(report.pointsDiscount, 150);
      expect(report.net, 1350);
      // The identity that makes the three figures readable together.
      expect(report.net, report.gross - report.pointsDiscount);
    });

    test('cash received and simulated payments are never added together', () {
      // The distinction the whole screen turns on: a prototype order is marked
      // paid at checkout without any money moving.
      final report = SellerSalesReport.from(
        [
          _order(
            id: 'cash-delivered',
            subtotal: 300,
            payment: PaymentStatus.paid,
            status: OrderStatus.delivered,
            createdAt: now,
          ),
          _order(
            id: 'bkash',
            subtotal: 700,
            method: SettlementMethod.prototypeBkash,
            payment: PaymentStatus.paid,
            createdAt: now,
          ),
          _order(
            id: 'cash-pending',
            subtotal: 400,
            status: OrderStatus.shipped,
            createdAt: now,
          ),
        ],
        period: SalesPeriod.today,
        now: now,
      );

      expect(report.collected, 300);
      expect(report.simulated, 700);
      expect(report.outstanding, 400);
      expect(report.settled, 1000);
      // Everything is accounted for exactly once.
      expect(report.collected + report.simulated + report.outstanding,
          report.net);
    });

    test('a discounted order settles at payable, not at subtotal', () {
      final report = SellerSalesReport.from(
        [
          _order(
            subtotal: 1000,
            discount: 400,
            pointsApplied: 4000,
            payment: PaymentStatus.paid,
            status: OrderStatus.confirmed,
            createdAt: now,
          ),
        ],
        period: SalesPeriod.today,
        now: now,
      );

      expect(report.collected, 600);
      expect(report.pointsRedeemed, 4000);
    });

    test('units sold count quantities, not orders', () {
      final report = SellerSalesReport.from(
        [
          _order(id: 'a', subtotal: 100, qty: 3, createdAt: now),
          _order(id: 'b', subtotal: 100, qty: 2, createdAt: now),
        ],
        period: SalesPeriod.today,
        now: now,
      );
      expect(report.orderCount, 2);
      expect(report.itemCount, 5);
    });
  });

  group('honesty about incomplete data', () {
    test('an order whose server timestamp has not resolved is not counted '
        'into a dated window, and is reported', () {
      final report = SellerSalesReport.from(
        [
          _order(id: 'dated', subtotal: 100, createdAt: now),
          _order(id: 'undated', subtotal: 999),
        ],
        period: SalesPeriod.today,
        now: now,
      );

      expect(report.orderCount, 1);
      expect(report.gross, 100, reason: 'the undated order must not be guessed '
          'into today just because it arrived while today was on screen');
      expect(report.undated, 1);
    });

    test('all time does count an undated order, having no boundary', () {
      final report = SellerSalesReport.from(
        [_order(id: 'undated', subtotal: 999)],
        period: SalesPeriod.allTime,
        now: now,
      );
      expect(report.orderCount, 1);
      expect(report.gross, 999);
      expect(report.undated, 1);
    });

    test('truncation is carried through to an all-time total', () {
      final report = SellerSalesReport.from(
        [_order(subtotal: 100, createdAt: now)],
        period: SalesPeriod.allTime,
        now: now,
        truncated: true,
      );
      expect(report.truncated, isTrue);
    });

    test('a capped query does NOT flag a window it reached back past', () {
      // The cap drops the OLDEST orders, so a seller past the limit still has
      // an exact figure for today. Warning about a number that is provably
      // complete teaches the reader to ignore the warning on the one that
      // is not.
      final report = SellerSalesReport.from(
        [
          _order(id: 'recent', subtotal: 100, createdAt: now),
          _order(id: 'older', subtotal: 100, createdAt: DateTime(2026, 8, 1)),
        ],
        period: SalesPeriod.today,
        now: now,
        truncated: true,
      );

      expect(report.orderCount, 1);
      expect(
        report.truncated,
        isFalse,
        reason: 'the query reached back to 1 August, well past this midnight',
      );
    });

    test('a capped query DOES flag a window it could not reach the start of', () {
      final report = SellerSalesReport.from(
        [
          _order(id: 'a', subtotal: 100, createdAt: now),
          _order(id: 'b', subtotal: 100, createdAt: DateTime(2026, 8, 22)),
        ],
        period: SalesPeriod.month,
        now: now,
        truncated: true,
      );

      // The 30-day window starts 26 July; the oldest order read is 22 August,
      // so orders between those dates were cut off and the total is a floor.
      expect(report.truncated, isTrue);
      expect(report.oldestOrder, DateTime(2026, 8, 22));
    });

    test('an uncapped query never flags any window', () {
      for (final period in SalesPeriod.values) {
        final report = SellerSalesReport.from(
          [_order(subtotal: 100, createdAt: now)],
          period: period,
          now: now,
        );
        expect(report.truncated, isFalse, reason: period.name);
      }
    });
  });

  test('the settlement split always accounts for the income exactly', () {
    // Breaks the moment anyone adds a cancellation state, which is the point.
    final orders = <OrderModel>[
      for (var i = 0; i < 25; i++)
        _order(
          id: 'order-$i',
          subtotal: 100 + i * 37,
          discount: i % 3 == 0 ? i * 5 : 0,
          method: i % 4 == 0
              ? SettlementMethod.prototypeBkash
              : SettlementMethod.cashOnDelivery,
          payment: i % 2 == 0 ? PaymentStatus.paid : PaymentStatus.pending,
          createdAt: now,
        ),
    ];

    final report = SellerSalesReport.from(
      orders,
      period: SalesPeriod.today,
      now: now,
    );

    expect(report.orderCount, 25);
    expect(report.net, report.gross - report.pointsDiscount);
    expect(
      report.collected + report.simulated + report.outstanding,
      report.net,
    );
  });

  test('an empty period is empty rather than zeroed nonsense', () {
    final report = SellerSalesReport.from(
      const [],
      period: SalesPeriod.today,
      now: now,
    );
    expect(report.isEmpty, isTrue);
    expect(report.net, 0);
    expect(report.countByStatus, isEmpty);
  });

  test('orders are tallied by status', () {
    final report = SellerSalesReport.from(
      [
        _order(id: 'a', subtotal: 10, status: OrderStatus.pending, createdAt: now),
        _order(id: 'b', subtotal: 10, status: OrderStatus.pending, createdAt: now),
        _order(id: 'c', subtotal: 10, status: OrderStatus.confirmed, createdAt: now),
      ],
      period: SalesPeriod.today,
      now: now,
    );
    expect(report.countByStatus[OrderStatus.pending], 2);
    expect(report.countByStatus[OrderStatus.confirmed], 1);
    expect(report.countByStatus[OrderStatus.shipped], isNull);
  });
}
