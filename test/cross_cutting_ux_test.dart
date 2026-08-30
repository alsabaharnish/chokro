import 'dart:async';

import 'package:chokro/controllers/admin_workload_controller.dart';
import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/controllers/cart_controller.dart';
import 'package:chokro/controllers/claim_controller.dart';
import 'package:chokro/controllers/current_user_provider.dart';
import 'package:chokro/controllers/ledger_controller.dart';
import 'package:chokro/controllers/seller_application_controller.dart';
import 'package:chokro/controllers/wallet_controller.dart';
import 'package:chokro/core/account_profile.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/claim_model.dart';
import 'package:chokro/models/seller_application_model.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/models/wallet_model.dart';
import 'package:chokro/services/transaction_service.dart';
import 'package:chokro/views/claims/claim_history_view.dart';
import 'package:chokro/views/seller_application/seller_application_view.dart';
import 'package:chokro/views/seller/product_edit_view.dart';
import 'package:chokro/views/shared/app_shell.dart';
import 'package:chokro/views/shared/rejection_reason_dialog.dart';
import 'package:chokro/views/shared/unsaved_changes.dart';
import 'package:chokro/views/wallet/wallet_ledger_view.dart';
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

const _champion = UserModel(
  uid: 'champion-1',
  name: 'Nadia Islam',
  email: 'nadia@example.com',
  role: AppConstants.roleBuyer,
  status: AppConstants.statusActive,
);

void main() {
  testWidgets('eco-action history explains and performs a profile switch', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/claims',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('Home')),
        ),
        GoRoute(path: '/claims', builder: (_, _) => const ClaimHistoryView()),
        GoRoute(
          path: '/claims/new',
          builder: (_, _) => const Scaffold(body: Text('Claim form opened')),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) => Stream.value(_admin)),
          cartCountProvider.overrideWithValue(0),
          adminWorkloadProvider.overrideWithValue(AdminWorkload.empty),
          userClaimsProvider.overrideWith(
            (ref) => Stream.value(const <ClaimModel>[]),
          ),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Switch to 3ZERO Champion to log an action'),
      findsOneWidget,
    );
    await tester.tap(find.text('Switch to 3ZERO Champion to log an action'));
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(RadioListTile<AccountProfile>, '3ZERO Champion'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Claim form opened'), findsOneWidget);
  });

  testWidgets('a root secondary screen sends system back to Home', (
    tester,
  ) async {
    final router = GoRouter(
      initialLocation: '/orders',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('Home destination')),
        ),
        GoRoute(
          path: '/orders',
          builder: (_, _) => const AppShell(
            title: 'My orders',
            child: Center(child: Text('Orders destination')),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) => Stream.value(_champion)),
          cartCountProvider.overrideWithValue(0),
          adminWorkloadProvider.overrideWithValue(AdminWorkload.empty),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Orders destination'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Home destination'), findsOneWidget);
  });

  testWidgets('application loading is visible', (tester) async {
    final applications =
        StreamController<List<SellerApplicationModel>>.broadcast();
    addTearDown(applications.close);
    final router = GoRouter(
      initialLocation: '/apply-seller',
      routes: [
        GoRoute(
          path: '/home',
          builder: (_, _) => const Scaffold(body: Text('Home destination')),
        ),
        GoRoute(
          path: '/apply-seller',
          builder: (_, _) => const SellerApplicationView(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) => Stream.value(_champion)),
          cartCountProvider.overrideWithValue(0),
          adminWorkloadProvider.overrideWithValue(AdminWorkload.empty),
          userApplicationsProvider.overrideWith((ref) => applications.stream),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Checking your applications…'), findsOneWidget);
  });

  testWidgets('typed application text arms the discard guard', (tester) async {
    final router = GoRouter(
      initialLocation: '/apply-seller',
      routes: [
        GoRoute(
          path: '/apply-seller',
          builder: (_, _) => const SellerApplicationView(),
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) => Stream.value(_champion)),
          cartCountProvider.overrideWithValue(0),
          adminWorkloadProvider.overrideWithValue(AdminWorkload.empty),
          userApplicationsProvider.overrideWith(
            (ref) => Stream.value(const <SellerApplicationModel>[]),
          ),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<UnsavedChangesGuard>(find.byType(UnsavedChangesGuard))
          .hasChanges,
      isFalse,
    );

    await tester.enterText(find.byType(TextFormField).first, 'Circular Works');
    await tester.pump();

    expect(
      tester
          .widget<UnsavedChangesGuard>(find.byType(UnsavedChangesGuard))
          .hasChanges,
      isTrue,
    );

    await tester.tap(find.byTooltip('Back to home'));
    await tester.pumpAndSettle();
    expect(find.text('Discard this application?'), findsOneWidget);
    expect(find.text('Home destination'), findsNothing);
  });

  testWidgets('the rejection dialog remains scrollable with accessible text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: FilledButton(
              onPressed: () => showRejectionReasonDialog(
                context,
                title: 'Reject this submission?',
                hintText: 'Explain what needs to change',
              ),
              child: const Text('Open dialog'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open dialog'));
    await tester.pumpAndSettle();

    expect(
      tester.widget<AlertDialog>(find.byType(AlertDialog)).scrollable,
      true,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a very large wallet balance fits accessible phone text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final router = GoRouter(
      initialLocation: '/wallet',
      routes: [
        GoRoute(path: '/wallet', builder: (_, _) => const WalletLedgerView()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) => Stream.value(_champion)),
          cartCountProvider.overrideWithValue(0),
          adminWorkloadProvider.overrideWithValue(AdminWorkload.empty),
          ledgerProvider.overrideWith(
            (ref) => Stream.value(
              const TransactionPage(entries: [], truncated: false),
            ),
          ),
          walletProvider.overrideWithValue(
            const AsyncData(
              WalletModel(userId: 'champion-1', balance: 9223372036854775807),
            ),
          ),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('9223372036854775807'), findsOneWidget);
    final walletList = find.descendant(
      of: find.byType(RefreshIndicator),
      matching: find.byType(ListView),
    );
    expect(
      tester.widget<ListView>(walletList).physics,
      isA<AlwaysScrollableScrollPhysics>(),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('listing price and stock stack at accessible phone size', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) => Stream.value(_champion)),
          currentUidProvider.overrideWithValue(_champion.uid),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ProductEditView(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final price = find.ancestor(
      of: find.text('Price'),
      matching: find.byType(TextFormField),
    );
    final stock = find.ancestor(
      of: find.text('Stock'),
      matching: find.byType(TextFormField),
    );
    expect(price, findsOneWidget);
    expect(stock, findsOneWidget);
    expect(
      tester.getTopLeft(stock).dy,
      greaterThan(tester.getTopLeft(price).dy),
    );
    expect(tester.takeException(), isNull);
  });
}
