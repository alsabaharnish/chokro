import 'package:chokro/controllers/scan_controller.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/bin_model.dart';
import 'package:chokro/views/disposal/bin_entry_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _bin = BinModel(
  id: 'bin-1',
  label: 'Merul Badda gate',
  lat: 23.78,
  lng: 90.4,
  radiusMeters: 50,
  qrPayload: 'chokro:bin:a1b2c3d4e5f6',
  active: true,
  createdBy: 'admin-1',
);

class _ResolvedScanController extends ScanController {
  @override
  ScanState build() =>
      const ScanState(outcome: ScanOutcome.resolved, bin: _bin);

  @override
  Future<void> resolve(String payload) async {}
}

class _ClosedScanController extends ScanController {
  @override
  ScanState build() =>
      const ScanState(outcome: ScanOutcome.binClosed, bin: _bin);

  @override
  Future<void> resolve(String payload) async {}
}

class _TrackingScanController extends ScanController {
  _TrackingScanController(this.calls);

  final List<String> calls;

  @override
  ScanState build() => const ScanState();

  @override
  Future<void> resolve(String payload) async {
    calls.add(payload);
    state = const ScanState(outcome: ScanOutcome.unknownCode);
  }
}

Future<void> _pump(
  WidgetTester tester,
  ScanController Function() controller,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [scanControllerProvider.overrideWith(controller)],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const BinEntryView(payload: 'chokro:bin:a1b2c3d4e5f6'),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'valid web entry explains checks and continues without rescanning',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

      await _pump(tester, _ResolvedScanController.new);

      expect(find.text(_bin.label), findsOneWidget);
      expect(find.text('Continue with this bin'), findsOneWidget);
      expect(
        find.textContaining('same location, photo-content, duplicate'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closed bin cannot enter the submission flow', (tester) async {
    await _pump(tester, _ClosedScanController.new);

    expect(find.textContaining('no longer in service'), findsWidgets);
    expect(find.text('Continue with this bin'), findsNothing);
    expect(find.text('Try this code again'), findsOneWidget);
  });

  testWidgets('a second app link resolves its own bin payload', (tester) async {
    final calls = <String>[];
    final override = scanControllerProvider.overrideWith(
      () => _TrackingScanController(calls),
    );

    Widget app(String payload) => ProviderScope(
      overrides: [override],
      child: MaterialApp(home: BinEntryView(payload: payload)),
    );

    await tester.pumpWidget(app('chokro:bin:first_bin'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app('chokro:bin:second_bin'));
    await tester.pumpAndSettle();

    expect(calls, ['chokro:bin:first_bin', 'chokro:bin:second_bin']);
  });
}
