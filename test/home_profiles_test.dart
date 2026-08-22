import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/controllers/cart_controller.dart';
import 'package:chokro/controllers/orders_controller.dart';
import 'package:chokro/controllers/submission_history_controller.dart';
import 'package:chokro/controllers/wallet_controller.dart';
import 'package:chokro/core/account_profile.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/order_model.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/models/wallet_model.dart';
import 'package:chokro/views/home/home_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

UserModel _user(String role) => UserModel(
  uid: 'uid-1',
  name: 'Nabil',
  email: 'nabil@example.com',
  role: role,
  status: AppConstants.statusActive,
);

Future<void> _pumpHome(WidgetTester tester, String role) async {
  final router = GoRouter(
    initialLocation: '/home',
    routes: [GoRoute(path: '/home', builder: (_, _) => const HomeView())],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserProvider.overrideWith((ref) => Stream.value(_user(role))),
        walletProvider.overrideWith(
          (ref) =>
              Stream.value(const WalletModel(userId: 'uid-1', balance: 500)),
        ),
        pendingSubmissionCountProvider.overrideWithValue(0),
        ordersAwaitingConfirmationProvider.overrideWithValue(
          const <OrderModel>[],
        ),
        sellerOpenOrdersProvider.overrideWithValue(const <OrderModel>[]),
        cartCountProvider.overrideWithValue(0),
      ],
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Admin opens in a focused 3ZERO Admin workspace', (tester) async {
    await _pumpHome(tester, AppConstants.roleAdmin);

    expect(find.text('Using 3ZERO Admin'), findsOneWidget);
    expect(find.text('Platform dashboard'), findsOneWidget);
    expect(find.text('Greenpreneur applications'), findsOneWidget);
    expect(find.text('Support green initiatives'), findsNothing);
  });

  testWidgets('Greenpreneur opens in work profile and can switch to Champion', (
    tester,
  ) async {
    await _pumpHome(tester, AppConstants.roleSeller);

    expect(find.text('Using 3ZERO Greenpreneur'), findsOneWidget);
    expect(find.text('My sustainable listings'), findsOneWidget);

    await tester.tap(find.text('Use my Champion profile'));
    await tester.pumpAndSettle();

    expect(find.text('Using 3ZERO Champion'), findsOneWidget);
    expect(find.text('Support green initiatives'), findsOneWidget);
    expect(find.text('Use my Greenpreneur profile'), findsOneWidget);
  });

  testWidgets('Champion sees application education and donation entry points', (
    tester,
  ) async {
    await _pumpHome(tester, AppConstants.roleBuyer);

    expect(find.text('Using 3ZERO Champion'), findsOneWidget);
    expect(find.text('Become a 3ZERO Greenpreneur'), findsOneWidget);
    expect(find.text('Support green initiatives'), findsOneWidget);
  });

  testWidgets('profile picker stays stable with accessibility semantics', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpHome(tester, AppConstants.roleAdmin);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Switch'));
    await tester.pumpAndSettle();

    expect(find.byType(RadioListTile<AccountProfile>), findsNWidgets(3));
    await tester.tap(
      find.widgetWithText(RadioListTile<AccountProfile>, '3ZERO Champion'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Using 3ZERO Champion'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });

  testWidgets('account-menu profile switch keeps semantics consistent', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpHome(tester, AppConstants.roleAdmin);

    await tester.tap(find.byTooltip('Account menu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Switch profile'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.widgetWithText(RadioListTile<AccountProfile>, '3ZERO Greenpreneur'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Using 3ZERO Greenpreneur'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
