import 'package:chokro/controllers/account_profile_controller.dart';
import 'package:chokro/controllers/admin_workload_controller.dart';
import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/controllers/cart_controller.dart';
import 'package:chokro/controllers/sales_report_controller.dart';
import 'package:chokro/core/account_profile.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/order_model.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/services/order_service.dart';
import 'package:chokro/views/seller/seller_sales_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _greenpreneur = UserModel(
  uid: 'seller-1',
  name: 'Rafiq Ahmed',
  email: 'rafiq@example.com',
  role: AppConstants.roleSeller,
  status: AppConstants.statusActive,
);

OrderModel _order({
  required String id,
  required int subtotal,
  int discount = 0,
  SettlementMethod method = SettlementMethod.cashOnDelivery,
  PaymentStatus payment = PaymentStatus.pending,
  OrderStatus status = OrderStatus.pending,
  DateTime? createdAt,
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
      qty: 1,
    ),
  ],
  subtotal: subtotal,
  pointsApplied: discount * 10,
  discount: discount,
  payable: subtotal - discount,
  settlementMethod: method,
  paymentStatus: payment,
  status: status,
  createdAt: createdAt ?? DateTime.now(),
);

Widget _app({required List<OrderModel> orders, bool truncated = false}) {
  final router = GoRouter(
    initialLocation: '/seller/sales',
    routes: [
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('Home')),
      ),
      GoRoute(
        path: '/seller/orders',
        builder: (_, _) => const Scaffold(body: Text('Orders to fulfil')),
      ),
      GoRoute(
        path: '/seller/products',
        builder: (_, _) => const Scaffold(body: Text('Your listings')),
      ),
      GoRoute(
        path: '/seller/sales',
        builder: (_, _) => const SellerSalesView(),
      ),
    ],
  );
  addTearDown(router.dispose);

  return ProviderScope(
    overrides: [
      currentUserProvider.overrideWith((ref) => Stream.value(_greenpreneur)),
      activeAccountProfileProvider.overrideWithValue(
        AccountProfile.greenpreneur,
      ),
      cartCountProvider.overrideWithValue(0),
      adminWorkloadProvider.overrideWithValue(AdminWorkload.empty),
      sellerReportOrdersProvider.overrideWith(
        (ref) =>
            Stream.value(SellerOrderPage(orders: orders, truncated: truncated)),
      ),
    ],
    child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
  );
}

void _sizeAs(WidgetTester tester, {required double width, double scale = 1}) {
  tester.view.physicalSize = Size(width, 1400);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  testWidgets('reports the period income and never merges real with simulated', (
    tester,
  ) async {
    _sizeAs(tester, width: 400);
    final now = DateTime.now();

    await tester.pumpWidget(
      _app(
        orders: [
          // Cash, delivered: really collected.
          _order(
            id: 'a',
            subtotal: 300,
            discount: 50,
            payment: PaymentStatus.paid,
            status: OrderStatus.delivered,
            createdAt: now,
          ),
          // Prototype: marked paid at checkout, but no money moved.
          _order(
            id: 'b',
            subtotal: 700,
            method: SettlementMethod.prototypeBkash,
            payment: PaymentStatus.paid,
            createdAt: now,
          ),
          // Cash, not delivered: still to collect.
          _order(id: 'c', subtotal: 400, createdAt: now),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // gross 1,400 − discount 50 = net 1,350, split 250 cash / 700 simulated /
    // 400 outstanding. Every figure deliberately distinct so a match cannot be
    // the wrong tile.
    expect(find.text('৳1,350'), findsOneWidget, reason: 'headline income');
    expect(find.text('৳250'), findsOneWidget, reason: 'collected in cash');
    expect(find.text('৳700'), findsOneWidget, reason: 'simulated online');
    expect(find.text('৳400'), findsOneWidget, reason: 'still to collect');
    expect(find.text('৳1,400'), findsOneWidget, reason: 'list value, once');

    // The figure that must never appear: real plus simulated as one number.
    expect(find.text('৳950'), findsNothing);

    expect(tester.takeException(), isNull);
  });

  testWidgets('states plainly that Chokro does not hold the money', (
    tester,
  ) async {
    _sizeAs(tester, width: 400);
    await tester.pumpWidget(_app(orders: [_order(id: 'a', subtotal: 100)]));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      find.textContaining('Chokro does not hold this money'),
      findsOneWidget,
    );
    // Simulated money is labelled as such wherever it is shown.
    expect(find.textContaining('No real money moved'), findsOneWidget);
  });

  testWidgets('a truncated window says so and qualifies the headline', (
    tester,
  ) async {
    _sizeAs(tester, width: 400);
    await tester.pumpWidget(
      _app(
        orders: [_order(id: 'a', subtotal: 100, createdAt: DateTime.now())],
        truncated: true,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Not "৳100" — the number itself carries the qualifier, because a reader
    // who takes one thing off this screen takes the headline.
    expect(find.textContaining('at least ৳100'), findsOneWidget);
    expect(find.textContaining('floors rather than totals'), findsOneWidget);
  });

  testWidgets('a seller with no orders gets a useful empty state', (
    tester,
  ) async {
    _sizeAs(tester, width: 400);
    await tester.pumpWidget(_app(orders: const []));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('No sales yet'), findsOneWidget);
    expect(find.text('Go to your listings'), findsOneWidget);
    expect(find.textContaining('Orders placed today'), findsNothing);
    await tester.tap(find.text('Go to your listings'));
    await tester.pumpAndSettle();
    expect(find.text('Your listings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty selected period still renders its zero report', (
    tester,
  ) async {
    _sizeAs(tester, width: 400);
    await tester.pumpWidget(
      _app(
        orders: [
          _order(
            id: 'older',
            subtotal: 100,
            createdAt: DateTime.now().subtract(const Duration(days: 20)),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.textContaining('Orders placed today'), findsOneWidget);
    expect(find.text('No sales yet'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  group('layout holds at every size the app supports', () {
    // The Greenpreneur now has five navigation destinations, which is the
    // practical ceiling for a NavigationBar — so the widths and text scales
    // that broke other screens in this app are checked explicitly here rather
    // than assumed.
    for (final width in <double>[320, 360, 430, 800, 1280, 1920]) {
      for (final scale in <double>[1, 2]) {
        testWidgets('${width}dp at text scale $scale', (tester) async {
          _sizeAs(tester, width: width, scale: scale);
          await tester.pumpWidget(
            _app(
              orders: [
                _order(
                  id: 'a',
                  subtotal: 12500,
                  discount: 400,
                  payment: PaymentStatus.paid,
                  status: OrderStatus.delivered,
                  createdAt: DateTime.now(),
                ),
              ],
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));

          expect(tester.takeException(), isNull);
        });
      }
    }
  });

  group('the five-destination rail survives a short browser window', () {
    // Adding "Sales" makes five Greenpreneur destinations — the same count the
    // admin profile already ships. The NavigationRail is built without its own
    // scrolling, so a short window is where that would bite.
    for (final height in <double>[900, 700, 600, 500, 420]) {
      testWidgets('1280 x ${height}dp', (tester) async {
        tester.view.physicalSize = Size(1280, height);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await tester.pumpWidget(_app(orders: [_order(id: 'a', subtotal: 500)]));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('switching period re-totals without another read', (
    tester,
  ) async {
    _sizeAs(tester, width: 900);
    final now = DateTime.now();

    await tester.pumpWidget(
      _app(
        orders: [
          // Two orders today so the period total differs from every tile —
          // with a single order, net and "still to collect" are the same
          // number and a match proves nothing.
          _order(
            id: 'today-paid',
            subtotal: 120,
            discount: 20,
            payment: PaymentStatus.paid,
            status: OrderStatus.delivered,
            createdAt: now,
          ),
          _order(id: 'today-open', subtotal: 250, createdAt: now),
          _order(
            id: 'old',
            subtotal: 900,
            createdAt: now.subtract(const Duration(days: 20)),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('৳350'), findsOneWidget, reason: 'today only');

    await tester.tap(find.text('Last 30 days'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('৳1,250'), findsOneWidget, reason: 'all three orders');
    expect(tester.takeException(), isNull);
  });
}
