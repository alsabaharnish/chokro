import 'dart:math' as math;

import 'package:chokro/controllers/account_profile_controller.dart';
import 'package:chokro/controllers/admin_workload_controller.dart';
import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/controllers/cart_controller.dart';
import 'package:chokro/controllers/dashboard_controller.dart';
import 'package:chokro/core/account_profile.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/stats_model.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/views/admin/admin_dashboard_view.dart';
import 'package:chokro/views/shared/action_card.dart';
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

const _stats = PlatformStats(
  disposalsApproved: 1234567,
  disposalsRejected: 2,
  claimsApproved: 5,
  claimsRejected: 1,
  pointsIssued: 2000000,
  pointsRedeemed: 400000,
  pointsDonated: 450,
  donationsReceived: 3,
  ordersCreated: 7,
  ordersConfirmed: 4,
  salesPayable: 18500,
);

const _accounts = AccountTotals(
  total: 12,
  buyers: 12,
  sellers: 4,
  admins: 1,
  suspended: 2,
);

Future<void> _pumpDashboard(
  WidgetTester tester, {
  AsyncValue<PlatformStats> stats = const AsyncData(_stats),
  AsyncValue<AccountTotals> accounts = const AsyncData(_accounts),
  Size size = const Size(1200, 900),
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final router = GoRouter(
    initialLocation: '/admin/dashboard',
    routes: [
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('Home')),
      ),
      GoRoute(
        path: '/admin/dashboard',
        builder: (_, _) => const AdminDashboardView(),
      ),
      GoRoute(
        path: '/admin/appeals',
        builder: (_, _) => const Scaffold(body: Text('Appeals')),
      ),
      GoRoute(
        path: '/admin/users',
        builder: (_, _) => const Scaffold(body: Text('Accounts')),
      ),
      GoRoute(
        path: '/admin/disposals',
        builder: (_, _) => const Scaffold(body: Text('Disposals')),
      ),
      GoRoute(
        path: '/admin/claims',
        builder: (_, _) => const Scaffold(body: Text('Eco-actions')),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserProvider.overrideWithValue(const AsyncData(_admin)),
        activeAccountProfileProvider.overrideWithValue(AccountProfile.admin),
        cartCountProvider.overrideWithValue(0),
        adminWorkloadProvider.overrideWithValue(AdminWorkload.empty),
        platformStatsProvider.overrideWithValue(stats),
        accountTotalsProvider.overrideWithValue(accounts),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens on a truthful all-time SDG alignment view', (
    tester,
  ) async {
    await _pumpDashboard(tester);

    expect(find.text('SDG impact signals'), findsOneWidget);
    expect(find.text('Target 8.3'), findsOneWidget);
    expect(find.text('Target 11.6'), findsOneWidget);
    expect(find.text('Target 12.5'), findsOneWidget);
    expect(find.text('Target 13.3'), findsOneWidget);
    expect(find.text('1,234,567'), findsNWidgets(2));
    expect(find.textContaining('official indicators'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Read methodology'));
    await tester.pumpAndSettle();

    expect(find.text('How SDG alignment is calculated'), findsOneWidget);
    expect(find.text('Goal cards may overlap'), findsOneWidget);
    expect(find.text('Unmeasured outcomes stay unclaimed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cached and truncated values keep their provenance', (
    tester,
  ) async {
    await _pumpDashboard(
      tester,
      stats: const AsyncData(PlatformStats(isFromCache: true)),
      accounts: const AsyncData(
        AccountTotals(
          total: 200,
          buyers: 200,
          sellers: 18,
          admins: 2,
          truncated: true,
          isFromCache: true,
        ),
      ),
    );

    expect(find.text('Cached snapshot'), findsOneWidget);
    expect(find.text('18+'), findsOneWidget);
    expect(find.text('Cached account snapshot'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone layout survives large accessibility text', (tester) async {
    await _pumpDashboard(tester, size: const Size(320, 900), textScale: 2);

    expect(find.text('SDG impact signals'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Platform data'));
    await tester.pumpAndSettle();
    expect(find.text('Operational overview'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('platform failure does not hide accounts or Admin shortcuts', (
    tester,
  ) async {
    await _pumpDashboard(
      tester,
      stats: AsyncError(StateError('offline'), StackTrace.empty),
    );

    await tester.tap(find.text('Platform data'));
    await tester.pumpAndSettle();

    expect(find.text('Platform counters could not be loaded'), findsOneWidget);
    expect(find.text('Accounts'), findsWidgets);
    expect(find.text('12'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.widgetWithText(ActionCard, 'Appeals'),
      240,
      scrollable: find.descendant(
        of: find.byKey(
          const PageStorageKey<String>('admin-operations-dashboard'),
        ),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.widgetWithText(ActionCard, 'Appeals'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('SDG number badges choose an accessible foreground', () {
    for (final colour in const <Color>[
      Color(0xFFA21942),
      Color(0xFFFD9D24),
      Color(0xFFBF8B2E),
      Color(0xFF3F7E44),
    ]) {
      final luminance = colour.computeLuminance();
      final blackContrast = (luminance + 0.05) / 0.05;
      final whiteContrast = 1.05 / (luminance + 0.05);
      final foreground = blackContrast >= whiteContrast
          ? Colors.black
          : Colors.white;
      expect(_contrast(foreground, colour), greaterThanOrEqualTo(4.5));
    }
  });
}

double _contrast(Color a, Color b) {
  double luminance(Color colour) {
    double channel(double value) => value <= 0.03928
        ? value / 12.92
        : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
    return 0.2126 * channel(colour.r) +
        0.7152 * channel(colour.g) +
        0.0722 * channel(colour.b);
  }

  final first = luminance(a);
  final second = luminance(b);
  return (math.max(first, second) + 0.05) / (math.min(first, second) + 0.05);
}
