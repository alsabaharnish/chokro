import 'package:chokro/controllers/admin_bins_controller.dart';
import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/bin_model.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/services/location_service.dart';
import 'package:chokro/views/admin/admin_bins_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// On-site GPS capture during bin registration (F2.1).
///
/// These cover the parts that are easy to get subtly wrong and impossible to
/// notice by looking: whether the captured fix reaches the form, and whether the
/// accuracy note stops describing the form once the numbers in it are no longer
/// the ones the GPS produced.

class _FakeLocationService extends LocationService {
  _FakeLocationService(this.result);

  final LocationResult result;
  int calls = 0;

  @override
  Future<LocationResult> getCurrentLocation({
    Duration timeout = const Duration(seconds: 20),
  }) async {
    calls++;
    return result;
  }
}

BinModel _bin({required bool active}) => BinModel(
  label: 'Merul Badda - Block C gate',
  lat: 23.78,
  lng: 90.4,
  radiusMeters: 50,
  qrPayload: 'chokro:bin:abc123',
  active: active,
  createdBy: 'admin-uid',
);

final _admin = UserModel(
  uid: 'admin-uid',
  name: 'Admin',
  email: 'admin@example.com',
  role: AppConstants.roleAdmin,
  status: AppConstants.statusActive,
  createdAt: DateTime(2026, 1, 1),
);

Future<_FakeLocationService> _pump(
  WidgetTester tester,
  LocationResult fix, {
  List<BinModel> bins = const [],
}) async {
  final location = _FakeLocationService(fix);

  final router = GoRouter(
    initialLocation: '/admin/bins',
    routes: [
      GoRoute(
        path: '/admin/bins',
        builder: (context, state) => const AdminBinsView(),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        binLocationServiceProvider.overrideWithValue(location),
        currentUserProvider.overrideWith((ref) => Stream.value(_admin)),
        allBinsProvider.overrideWith((ref) => Stream.value(bins)),
      ],
      child: MaterialApp.router(theme: AppTheme.light(), routerConfig: router),
    ),
  );
  await tester.pumpAndSettle();
  return location;
}

/// Reads a coordinate field by its label.
String _fieldText(WidgetTester tester, String label) {
  final field = tester.widget<TextField>(
    find.ancestor(of: find.text(label), matching: find.byType(TextField)),
  );
  return field.controller!.text;
}

void main() {
  testWidgets('a captured fix fills the coordinate fields', (tester) async {
    final location = await _pump(
      tester,
      const LocationResult(
        outcome: LocationOutcome.fixed,
        latitude: 23.780815,
        longitude: 90.407452,
        accuracyMeters: 6,
      ),
    );

    await tester.tap(find.text('Use my location'));
    await tester.pumpAndSettle();

    expect(location.calls, 1);

    // Five decimal places is roughly a metre; more would be false precision.
    expect(_fieldText(tester, 'Latitude'), '23.78082');
    expect(_fieldText(tester, 'Longitude'), '90.40745');

    // A good fix against the default 50 m radius is reported, not warned about.
    expect(find.textContaining('Position captured'), findsOneWidget);
    expect(find.textContaining('too rough'), findsNothing);
  });

  testWidgets('a fix too rough for the radius is warned about', (tester) async {
    await _pump(
      tester,
      const LocationResult(
        outcome: LocationOutcome.fixed,
        latitude: 23.780815,
        longitude: 90.407452,
        accuracyMeters: 40,
      ),
    );

    await tester.tap(find.text('Use my location'));
    await tester.pumpAndSettle();

    // ±40 m cannot centre a 50 m geofence. The coordinates are still filled in
    // — the administrator may knowingly widen the radius instead.
    expect(find.textContaining('too rough'), findsOneWidget);
    expect(_fieldText(tester, 'Latitude'), '23.78082');
  });

  testWidgets('widening the radius clears the warning without recapturing', (
    tester,
  ) async {
    await _pump(
      tester,
      const LocationResult(
        outcome: LocationOutcome.fixed,
        latitude: 23.780815,
        longitude: 90.407452,
        accuracyMeters: 40,
      ),
    );

    await tester.tap(find.text('Use my location'));
    await tester.pumpAndSettle();
    expect(find.textContaining('too rough'), findsOneWidget);

    // ±40 m is fine for a 200 m compound, and the verdict is relative to the
    // radius rather than absolute — so it must follow the radius field.
    await tester.enterText(
      find.ancestor(of: find.text('Radius'), matching: find.byType(TextField)),
      '200',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('too rough'), findsNothing);
    expect(find.textContaining('Position captured'), findsOneWidget);
  });

  testWidgets('editing a coordinate by hand drops the accuracy note', (
    tester,
  ) async {
    await _pump(
      tester,
      const LocationResult(
        outcome: LocationOutcome.fixed,
        latitude: 23.780815,
        longitude: 90.407452,
        accuracyMeters: 6,
      ),
    );

    await tester.tap(find.text('Use my location'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Position captured'), findsOneWidget);

    // Typed coordinates have no accuracy. Leaving "accurate to ±6 m" beside a
    // number the GPS never produced would be a false claim about the bin's
    // position — the one value nothing downstream can double-check.
    await tester.enterText(
      find.ancestor(
        of: find.text('Latitude'),
        matching: find.byType(TextField),
      ),
      '23.9',
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Position captured'), findsNothing);
    expect(find.textContaining('accurate to'), findsNothing);
  });

  testWidgets('a denied permission still allows typing coordinates', (
    tester,
  ) async {
    await _pump(tester, const LocationResult(outcome: LocationOutcome.denied));

    await tester.tap(find.text('Use my location'));
    await tester.pumpAndSettle();

    // The web build has no useful GPS and a permission can be refused, so the
    // failure must not be a dead end.
    expect(
      find.textContaining('type the coordinates in by hand'),
      findsOneWidget,
    );
    expect(_fieldText(tester, 'Latitude'), isEmpty);
  });

  testWidgets('a permanently denied permission offers settings', (
    tester,
  ) async {
    await _pump(
      tester,
      const LocationResult(outcome: LocationOutcome.deniedForever),
    );

    await tester.tap(find.text('Use my location'));
    await tester.pumpAndSettle();

    expect(find.text('Open settings'), findsOneWidget);
  });

  testWidgets('print-all is offered when an open bin exists', (tester) async {
    await _pump(
      tester,
      const LocationResult(outcome: LocationOutcome.idle),
      bins: [_bin(active: true)],
    );

    expect(find.text('Print labels (1)'), findsOneWidget);
  });

  testWidgets('print-all is withheld when every bin is closed', (tester) async {
    await _pump(
      tester,
      const LocationResult(outcome: LocationOutcome.idle),
      bins: [_bin(active: false)],
    );

    // A closed bin's label on the street produces a scan, a walk and a refusal,
    // so there is nothing worth printing.
    expect(find.textContaining('Print labels'), findsNothing);
  });

  testWidgets('print-all is withheld when there are no bins', (tester) async {
    await _pump(tester, const LocationResult(outcome: LocationOutcome.idle));

    expect(find.textContaining('Print labels'), findsNothing);
    expect(
      find.textContaining('Nothing can be scanned until one exists'),
      findsOneWidget,
    );
  });

  testWidgets('a registered bin QR opens without layout or semantics errors', (
    tester,
  ) async {
    // Narrow enough to exercise the mobile dialog constraints while leaving
    // the registered-bin card on screen for this interaction-focused test.
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final semantics = tester.ensureSemantics();

    final bin = _bin(active: true);
    await _pump(
      tester,
      const LocationResult(outcome: LocationOutcome.idle),
      bins: [bin],
    );

    final showQr = find.byTooltip('Show and print QR code for ${bin.label}');
    final binList = find
        .descendant(
          of: find.byType(ListView),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(showQr, 200, scrollable: binList);
    await tester.tap(showQr);
    await tester.pumpAndSettle();

    expect(find.text(bin.label), findsWidgets);
    expect(find.text(bin.qrPayload), findsOneWidget);
    expect(find.bySemanticsLabel('QR code for ${bin.label}'), findsOneWidget);
    expect(find.text('Copy payload'), findsOneWidget);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
