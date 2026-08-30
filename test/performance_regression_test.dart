import 'package:cached_network_image/cached_network_image.dart';
import 'package:chokro/controllers/account_profile_controller.dart';
import 'package:chokro/controllers/admin_workload_controller.dart';
import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/controllers/cart_controller.dart';
import 'package:chokro/controllers/orders_controller.dart';
import 'package:chokro/core/account_profile.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/image_delivery.dart';
import 'package:chokro/core/product_taxonomy.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/order_model.dart';
import 'package:chokro/models/product_model.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/services/order_service.dart';
import 'package:chokro/views/market/product_card.dart';
import 'package:chokro/views/orders/buyer_orders_view.dart';
import 'package:chokro/views/orders/order_card.dart';
import 'package:chokro/views/seller/seller_orders_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Costs the user feels, pinned so they cannot quietly come back.
///
/// Two of these were shipped for the life of the project and neither was
/// visible in a screenshot: every list screen was drawing its whole result set
/// on every frame, and every photograph was decoded at full resolution into a
/// thumbnail-sized box.
const _buyer = UserModel(
  uid: 'buyer-1',
  name: 'Nadia Islam',
  email: 'nadia@example.com',
  role: AppConstants.roleBuyer,
  status: AppConstants.statusActive,
);

const _seller = UserModel(
  uid: 'seller-1',
  name: 'Rafiq Ahmed',
  email: 'rafiq@example.com',
  role: AppConstants.roleSeller,
  status: AppConstants.statusActive,
);

OrderModel _order(int index) => OrderModel(
  id: 'order-$index',
  buyerId: 'buyer-1',
  buyerName: 'Nadia Islam',
  sellerId: 'seller-$index',
  sellerName: 'Rafiq Ahmed',
  shopName: 'Circular Goods',
  checkoutId: 'checkout-$index',
  subtotal: 500,
  pointsApplied: 0,
  discount: 0,
  payable: 500,
  status: OrderStatus.pending,
  settlementMethod: SettlementMethod.cashOnDelivery,
  paymentStatus: PaymentStatus.pending,
  createdAt: DateTime(2026, 8, 20),
  items: const [
    OrderLine(
      productId: 'p1',
      title: 'Recycled notebook',
      unitPrice: 500,
      qty: 1,
    ),
  ],
);

/// The app frame a screen needs to build, minus the ProviderScope — callers
/// supply that, because `Override` is not exported from flutter_riverpod's
/// public surface and cannot be named in a shared signature.
Widget _app(Widget child) => MaterialApp.router(
  theme: AppTheme.light(),
  routerConfig: GoRouter(
    routes: [GoRoute(path: '/', builder: (_, _) => child)],
  ),
);

void main() {
  group('list screens stay virtualised', () {
    testWidgets('the orders screen builds only the rows on screen', (
      tester,
    ) async {
      // Forty is `QueryLimits.orders`, i.e. the most this screen can hold.
      final orders = List.generate(40, _order);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserProvider.overrideWith((ref) => Stream.value(_buyer)),
            buyerOrdersProvider.overrideWith(
              (ref) => Stream.value(
                BuyerOrderPage(orders: orders, truncated: false),
              ),
            ),
            cartCountProvider.overrideWith((ref) => 0),
            adminWorkloadProvider.overrideWith((ref) => AdminWorkload.empty),
            activeAccountProfileProvider.overrideWith(
              (ref) => AccountProfile.champion,
            ),
          ],
          child: _app(const BuyerOrdersView()),
        ),
      );
      await tester.pumpAndSettle();

      final built = tester.widgetList(find.byType(OrderCard)).length;

      // The regression: the whole list lived inside one `Center`-wrapped
      // `Column`, so the ListView had a single child and all forty cards were
      // laid out and painted every frame — thirty-odd of them off screen.
      expect(
        built,
        lessThan(orders.length),
        reason: 'every order card was built, so nothing is virtualised',
      );
      expect(built, greaterThan(0));
    });

    testWidgets('the growing seller queue still builds rows lazily', (
      tester,
    ) async {
      final orders = List.generate(40, _order);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserProvider.overrideWith((ref) => Stream.value(_seller)),
            sellerOrdersProvider.overrideWith(
              (ref) => Stream.value(
                SellerOrderPage(orders: orders, truncated: true),
              ),
            ),
            cartCountProvider.overrideWith((ref) => 0),
            adminWorkloadProvider.overrideWith((ref) => AdminWorkload.empty),
            activeAccountProfileProvider.overrideWith(
              (ref) => AccountProfile.greenpreneur,
            ),
          ],
          child: _app(const SellerOrdersView()),
        ),
      );
      await tester.pumpAndSettle();

      final built = tester.widgetList(find.byType(OrderCard)).length;
      expect(
        built,
        lessThan(orders.length),
        reason: 'the growing fulfilment queue built every order at once',
      );
      expect(built, greaterThan(0));
    });

    testWidgets('a capped buyer history offers its older orders', (
      tester,
    ) async {
      final orders = List.generate(40, _order);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            currentUserProvider.overrideWith((ref) => Stream.value(_buyer)),
            buyerOrdersProvider.overrideWith(
              (ref) =>
                  Stream.value(BuyerOrderPage(orders: orders, truncated: true)),
            ),
            cartCountProvider.overrideWith((ref) => 0),
            adminWorkloadProvider.overrideWith((ref) => AdminWorkload.empty),
            activeAccountProfileProvider.overrideWith(
              (ref) => AccountProfile.champion,
            ),
          ],
          child: _app(const BuyerOrdersView()),
        ),
      );
      await tester.pumpAndSettle();

      await tester.scrollUntilVisible(
        find.text('Load 40 older orders'),
        700,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Load 40 older orders'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('images are not decoded at full size into small boxes', () {
    testWidgets('a catalogue thumbnail bounds both request and decode', (
      tester,
    ) async {
      const product = ProductModel(
        id: 'p1',
        sellerId: 'seller-1',
        shopName: 'Circular Goods',
        title: 'Recycled notebook',
        description: 'Made from recovered paper.',
        price: 500,
        stock: 4,
        category: ProductCategory.stationery,
        imageUrls: [
          'https://res.cloudinary.com/demo/image/upload/'
              'v1712345678/chokro/products/uid/a.jpg',
        ],
      );

      await tester.pumpWidget(
        ProviderScope(
          child: _app(const Scaffold(body: ProductCard(product: product))),
        ),
      );
      await tester.pump();

      final image = tester.widget<CachedNetworkImage>(
        find.byType(CachedNetworkImage),
      );

      // Asks the host for a thumbnail rather than the 1600 px original…
      expect(image.imageUrl, contains('/image/upload/c_limit,w_'));
      expect(image.imageUrl, contains('q_auto,f_auto'));
      // …and caps the decode regardless, so one card cannot put 10 MB of
      // uncompressed bitmap into the image cache to fill a 76 px square.
      expect(image.memCacheWidth, isNotNull);
      expect(image.memCacheWidth, lessThanOrEqualTo(decodeWidthFor(76)));
    });

    testWidgets('the public id survives the rewrite untouched', (tester) async {
      // `isTrustedImageReference` on the server matches a stored URL against a
      // stored public id. Nothing here may reach into that part of the path.
      const stored =
          'https://res.cloudinary.com/demo/image/upload/'
          'v1712345678/chokro/products/uid/a.jpg';

      expect(
        thumbnailUrl(stored, width: 76),
        endsWith('/v1712345678/chokro/products/uid/a.jpg'),
      );
    });
  });
}
