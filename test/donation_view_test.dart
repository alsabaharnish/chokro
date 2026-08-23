import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/controllers/cart_controller.dart';
import 'package:chokro/controllers/wallet_controller.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/donation_model.dart';
import 'package:chokro/models/payment_model.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/models/wallet_model.dart';
import 'package:chokro/views/donations/donation_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

void main() {
  testWidgets('donation choices and confirmation keep semantics consistent', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();

    final user = UserModel(
      uid: 'champion-1',
      name: 'Nabil',
      email: 'nabil@example.com',
      role: AppConstants.roleBuyer,
      status: AppConstants.statusActive,
    );
    final router = GoRouter(
      initialLocation: '/donate',
      routes: [
        GoRoute(path: '/donate', builder: (_, _) => const DonationView()),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWithValue(AsyncData(user)),
          walletProvider.overrideWithValue(
            const AsyncData(WalletModel(userId: 'champion-1', balance: 500)),
          ),
          cartCountProvider.overrideWithValue(0),
        ],
        child: MaterialApp.router(
          theme: AppTheme.light(),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(RadioListTile<GreenInitiative>), findsNWidgets(3));
    final donationScroll = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    final treePlanting = find.widgetWithText(
      RadioListTile<GreenInitiative>,
      'Tree planting',
    );
    await tester.scrollUntilVisible(
      treePlanting,
      120,
      scrollable: donationScroll,
    );
    await tester.pumpAndSettle();
    await tester.tap(treePlanting);
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Review donation'),
      120,
      scrollable: donationScroll,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Review donation'));
    await tester.pumpAndSettle();

    expect(find.text('Confirm point donation'), findsOneWidget);
    expect(
      find.textContaining('Donate 100 points to Tree planting?'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(TextButton, 'Not yet'));
    await tester.pumpAndSettle();

    // The selector is lazily disposed while the ListView is at the bottom.
    // Return to the top so its segment widgets are mounted again.
    await tester.drag(donationScroll, const Offset(0, 2000));
    await tester.pumpAndSettle();
    final modeSelector = tester.widget<SegmentedButton<DonationMode>>(
      find.byWidgetPredicate(
        (widget) => widget is SegmentedButton<DonationMode>,
      ),
    );
    modeSelector.onSelectionChanged?.call({DonationMode.prototypeOnline});
    await tester.pumpAndSettle();
    await tester.drag(donationScroll, const Offset(0, -1000));
    await tester.pumpAndSettle();

    expect(find.byType(RadioListTile<SettlementMethod>), findsNWidgets(3));
    final reviewPrototype = find.widgetWithText(
      FilledButton,
      'Review prototype payment',
    );
    await tester.scrollUntilVisible(
      reviewPrototype,
      160,
      scrollable: donationScroll,
    );
    await tester.ensureVisible(reviewPrototype);
    await tester.pumpAndSettle();
    await tester.tap(reviewPrototype);
    await tester.pumpAndSettle();

    expect(find.text('Prototype payment'), findsOneWidget);
    expect(find.textContaining('no real money'), findsOneWidget);
    expect(find.text('Simulate successful payment'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
