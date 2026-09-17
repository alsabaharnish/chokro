/// The idle timeout (SEC-9).
///
/// The control defends an unattended desktop, so the tests are about who it
/// applies to, what resets it, and — the one that matters most — what must NOT
/// reset it. A dashboard that polls would otherwise hold a session open
/// forever in an empty office, which is the exact situation being guarded
/// against.
library;

import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/idle_session.dart';
import 'package:chokro/models/user_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

UserModel _user(String role) => UserModel(
  uid: 'u1',
  name: 'Test',
  email: 't@example.com',
  role: role,
  status: AppConstants.statusActive,
);

class _RecordingAuth extends AuthController {
  int signOuts = 0;

  @override
  Future<void> build() async {}

  @override
  Future<void> signOut() async {
    signOuts += 1;
  }
}

Future<_RecordingAuth> _pump(WidgetTester tester, {required String role}) async {
  final controller = _RecordingAuth();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserProvider.overrideWithValue(AsyncData(_user(role))),
        authControllerProvider.overrideWith(() => controller),
      ],
      child: const MaterialApp(
        home: IdleSessionGuard(
          child: Scaffold(body: Center(child: Text('workspace'))),
        ),
      ),
    ),
  );
  await tester.pump();
  return controller;
}

void main() {
  mainAppShape();
  testWidgets('a producer left alone is signed out', (tester) async {
    final auth = await _pump(tester, role: AppConstants.roleProducer);

    await tester.pump(idleTimeout - const Duration(minutes: 1));
    expect(auth.signOuts, 0, reason: 'must not fire early');

    await tester.pump(const Duration(minutes: 2));
    expect(auth.signOuts, 1);
  });

  testWidgets('an Admin is treated the same', (tester) async {
    final auth = await _pump(tester, role: AppConstants.roleAdmin);
    await tester.pump(idleTimeout + const Duration(minutes: 1));
    expect(auth.signOuts, 1);
  });

  testWidgets('a Champion is not signed out mid-disposal', (tester) async {
    // Their account carries no compliance data, and a timeout firing while
    // somebody stands at a bin costs a real action to protect nothing.
    final auth = await _pump(tester, role: AppConstants.roleBuyer);
    await tester.pump(idleTimeout * 3);
    expect(auth.signOuts, 0);
  });

  testWidgets('a tap resets the clock', (tester) async {
    final auth = await _pump(tester, role: AppConstants.roleProducer);

    await tester.pump(idleTimeout - const Duration(minutes: 2));
    await tester.tap(find.text('workspace'));
    await tester.pump();

    // Past the ORIGINAL deadline, but not the new one.
    await tester.pump(idleTimeout - const Duration(minutes: 2));
    expect(auth.signOuts, 0);

    await tester.pump(const Duration(minutes: 3));
    expect(auth.signOuts, 1);
  });

  testWidgets('a rebuild alone does NOT reset the clock', (tester) async {
    // The test the whole control depends on. If a rebuild counted as activity,
    // any screen with a stream or a poll would keep an empty office signed in
    // indefinitely — and the control would look present while doing nothing.
    final auth = await _pump(tester, role: AppConstants.roleProducer);

    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(minutes: 5));
      // A frame, with no human input.
      await tester.pump();
    }

    expect(auth.signOuts, 1);
  });

  testWidgets('it does not sign out twice', (tester) async {
    final auth = await _pump(tester, role: AppConstants.roleProducer);
    await tester.pump(idleTimeout + const Duration(minutes: 1));
    await tester.pump(idleTimeout + const Duration(minutes: 1));
    expect(auth.signOuts, 1);
  });

  testWidgets('it does not block taps reaching the screen beneath', (
    tester,
  ) async {
    // A `Listener` rather than a `GestureDetector` for exactly this reason:
    // a gesture detector at the root would compete with children for taps.
    var tapped = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWithValue(
            AsyncData(_user(AppConstants.roleProducer)),
          ),
        ],
        child: MaterialApp(
          home: IdleSessionGuard(
            child: Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () => tapped = true,
                  child: const Text('press me'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('press me'));
    await tester.pump();
    expect(tapped, isTrue);
  });
}

// ---------------------------------------------------------------------------
// The configuration main.dart actually uses
// ---------------------------------------------------------------------------

void mainAppShape() {
  testWidgets('it survives wrapping MaterialApp, not just living inside one', (
    tester,
  ) async {
    // Every test above mounts the guard INSIDE a MaterialApp, which is not how
    // `main.dart` uses it — there it wraps `MaterialApp.router`, above the
    // Navigator and above the View.
    //
    // In that position a `Focus` widget made Flutter's focus traversal sort
    // descendants that had not been laid out, and the app threw on its first
    // frame in a browser:
    //
    //   RenderBox was not laid out: RenderSemanticsAnnotations NEEDS-LAYOUT
    //
    // The inside-a-MaterialApp tests all passed while the application would
    // not start. This one mounts it the way production does.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWithValue(
            AsyncData(_user(AppConstants.roleProducer)),
          ),
        ],
        child: const IdleSessionGuard(
          child: MaterialApp(
            home: Scaffold(body: Center(child: Text('workspace'))),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('workspace'), findsOneWidget);
  });

  testWidgets('a keystroke still counts as activity in that shape', (
    tester,
  ) async {
    final controller = _RecordingAuth();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWithValue(
            AsyncData(_user(AppConstants.roleProducer)),
          ),
          authControllerProvider.overrideWith(() => controller),
        ],
        child: const IdleSessionGuard(
          child: MaterialApp(
            home: Scaffold(body: Center(child: Text('workspace'))),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.pump(idleTimeout - const Duration(minutes: 2));
    // Through HardwareKeyboard, which is what replaced the Focus widget.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.pump();

    await tester.pump(idleTimeout - const Duration(minutes: 2));
    expect(controller.signOuts, 0, reason: 'the keystroke should have reset it');

    await tester.pump(const Duration(minutes: 3));
    expect(controller.signOuts, 1);
  });
}
