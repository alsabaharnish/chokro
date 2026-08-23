import 'package:chokro/controllers/account_profile_controller.dart';
import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/controllers/cart_controller.dart';
import 'package:chokro/core/account_profile.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/product_taxonomy.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/cart_model.dart';
import 'package:chokro/models/product_model.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/views/market/cart_view.dart';
import 'package:chokro/views/market/product_card.dart';
import 'package:chokro/views/shared/app_shell.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

const _admin = UserModel(
  uid: 'admin-1',
  name: 'Ayesha Rahman',
  email: 'ayesha@example.com',
  role: AppConstants.roleAdmin,
  status: AppConstants.statusActive,
);

ProductModel _product({int stock = 8}) => ProductModel.forSave(
  id: 'product-1',
  sellerId: 'seller-1',
  shopName: 'Circular Goods Collective',
  title: 'Handmade recycled storage basket',
  description: 'A durable storage basket made from recovered materials.',
  category: ProductCategory.homeAndLiving,
  price: 999999,
  stock: stock,
  tags: const ['recycled', 'storage'],
  imageUrls: const [],
  active: true,
);

void _useAccessiblePhoneSize(WidgetTester tester) {
  tester.view.physicalSize = const Size(320, 720);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = 2;

  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  testWidgets('a deep-linked secondary screen always has a route home', (
    tester,
  ) async {
    _useAccessiblePhoneSize(tester);

    final router = GoRouter(
      initialLocation: '/admin/bins',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('Home destination')),
        ),
        GoRoute(
          path: '/admin/bins',
          builder: (_, _) => const AppShell(
            title: 'Register and manage collection bins',
            child: Center(child: Text('Bin console')),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) => Stream.value(_admin)),
          activeAccountProfileProvider.overrideWithValue(AccountProfile.admin),
          cartCountProvider.overrideWithValue(0),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byTooltip('Back to home'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('Back to home'));
    await tester.pumpAndSettle();
    expect(find.text('Home destination'), findsOneWidget);
  });

  testWidgets('product cards wrap price and stock state at large text sizes', (
    tester,
  ) async {
    _useAccessiblePhoneSize(tester);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: 280,
              child: ProductCard(
                product: _product(stock: 0),
                trailing: const IconButton(
                  onPressed: null,
                  icon: Icon(Icons.more_vert),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Out of stock'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a populated cart explains that live product data is loading', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cartProvider.overrideWith(
            (ref) => Stream.value(
              const CartModel(
                userId: 'buyer-1',
                items: [CartItem(productId: 'product-1', qty: 2)],
              ),
            ),
          ),
          cartProductsProvider.overrideWith(
            (ref) => const Stream<List<ProductModel>>.empty(),
          ),
          checkoutQuoteProvider.overrideWithValue(null),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const CartView()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Checking current prices and stock…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a product lookup failure is visible and retryable', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cartProvider.overrideWith(
            (ref) => Stream.value(
              const CartModel(
                userId: 'buyer-1',
                items: [CartItem(productId: 'product-1', qty: 2)],
              ),
            ),
          ),
          cartProductsProvider.overrideWith(
            (ref) =>
                Stream<List<ProductModel>>.error(StateError('lookup failed')),
          ),
          checkoutQuoteProvider.overrideWithValue(null),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const CartView()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(
      find.text('Cart prices and stock could not be loaded'),
      findsOneWidget,
    );
    expect(find.text('Try again'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cart controls fit a narrow phone with accessible text', (
    tester,
  ) async {
    _useAccessiblePhoneSize(tester);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          cartProvider.overrideWith(
            (ref) => Stream.value(
              const CartModel(
                userId: 'buyer-1',
                items: [CartItem(productId: 'product-1', qty: 2)],
              ),
            ),
          ),
          cartProductsProvider.overrideWith(
            (ref) => Stream.value([_product()]),
          ),
          checkoutQuoteProvider.overrideWithValue(null),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: const CartView()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('2'), findsOneWidget);
    expect(find.byTooltip('Remove'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
