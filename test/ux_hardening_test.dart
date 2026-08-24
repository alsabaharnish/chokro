import 'dart:math' as math;

import 'package:chokro/controllers/account_profile_controller.dart';
import 'package:chokro/controllers/admin_workload_controller.dart';
import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/controllers/cart_controller.dart';
import 'package:chokro/controllers/submission_history_controller.dart';
import 'package:chokro/core/account_profile.dart';
import 'package:chokro/core/auth_errors.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/disposal_model.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/views/history/submission_history_view.dart';
import 'package:chokro/views/shared/action_card.dart';
import 'package:chokro/views/shared/flow_progress.dart';
import 'package:chokro/views/shared/status_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

/// Regression cover for defects that a green suite did not catch.
///
/// Every case here reproduces something that was actually broken, and the two
/// layout ones were broken at the *default* text size on ordinary phones — they
/// survived 496 passing tests because only one test file in the suite had ever
/// set a text scale, and no test rendered the submissions screen at all.

const _champion = UserModel(
  uid: 'buyer-1',
  name: 'Nadia Islam',
  email: 'nadia@example.com',
  role: AppConstants.roleBuyer,
  status: AppConstants.statusActive,
);

DisposalModel _disposal(DisposalStatus status) => DisposalModel(
  id: 'disposal-${status.name}',
  userId: 'buyer-1',
  binId: 'bin-1',
  photoUrl: 'https://storage.example/photo.jpg',
  capturedLat: 23.78,
  capturedLng: 90.40,
  distanceMeters: 8,
  declaredItemCount: 3,
  itemType: DisposalItemType.plasticBottle,
  status: status,
  pointsAwarded: 50,
);

void _sizeAs(WidgetTester tester, {required double width, double scale = 1}) {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

double _relativeLuminance(Color colour) {
  double channel(double value) => value <= 0.03928
      ? value / 12.92
      : math.pow((value + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(colour.r) +
      0.7152 * channel(colour.g) +
      0.0722 * channel(colour.b);
}

/// WCAG 2.1 contrast ratio. AA requires 4.5 for body text.
double _contrast(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  group('status chip fits the row it is given', () {
    // The chip's Row was `MainAxisSize.min` around an unconstrained Text, and
    // three of its four labels are short sentences. On the submissions screen
    // it shares a row with a 64px thumbnail and the points badge, which left it
    // 91px on a 320dp phone against the ~295px it wanted: it overflowed by
    // 204px at 320, 164 at 360, 134 at 390 and 94 at 430 — at the *default*
    // text size, on every handset, with no accessibility setting involved.
    for (final width in <double>[320, 360, 390, 430]) {
      for (final scale in <double>[1, 2]) {
        testWidgets('submissions list at ${width}dp, text scale $scale', (
          tester,
        ) async {
          _sizeAs(tester, width: width, scale: scale);

          final router = GoRouter(
            initialLocation: '/history',
            routes: [
              GoRoute(
                path: '/history',
                builder: (_, _) => const SubmissionHistoryView(),
              ),
            ],
          );
          addTearDown(router.dispose);

          await tester.pumpWidget(
            ProviderScope(
              overrides: [
                currentUserProvider.overrideWith(
                  (ref) => Stream.value(_champion),
                ),
                activeAccountProfileProvider.overrideWithValue(
                  AccountProfile.champion,
                ),
                cartCountProvider.overrideWithValue(0),
                adminWorkloadProvider.overrideWithValue(AdminWorkload.empty),
                submissionHistoryProvider.overrideWith(
                  (ref) => Stream.value([
                    _disposal(DisposalStatus.autoApproved),
                    _disposal(DisposalStatus.manualApproved),
                    _disposal(DisposalStatus.pending),
                  ]),
                ),
              ],
              child: MaterialApp.router(
                theme: AppTheme.light(),
                routerConfig: router,
              ),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 100));

          expect(tester.takeException(), isNull);
        });
      }
    }

    testWidgets('the label survives rather than being clipped away', (
      tester,
    ) async {
      _sizeAs(tester, width: 320);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 120,
                child: StatusChip(status: DisposalStatus.autoApproved),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // Wrapping, not ellipsising: "Verified by a reviewer" truncated to
      // "Verified by a…" loses what distinguishes it from the automatic
      // decision, which is the one thing this chip exists to say.
      expect(find.text('Approved automatically'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('disposal flow progress bar', () {
    // A hardcoded `preferredSize` of 42 that could not grow. Android's "Large"
    // font setting is around 1.3, so this broke without anyone opting in to an
    // accessibility size — on all four steps of the app's core flow.
    for (final scale in <double>[1, 1.15, 1.3, 1.6, 2]) {
      testWidgets('fits its declared height at text scale $scale', (
        tester,
      ) async {
        _sizeAs(tester, width: 320, scale: scale);
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              appBar: AppBar(
                title: const Text('Confirm and submit'),
                bottom: const FlowProgress(
                  current: 3,
                  total: 4,
                  label: 'Location',
                ),
              ),
              body: const SizedBox(),
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Step 3 of 4'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('section headings wrap instead of running off the screen', (
    tester,
  ) async {
    _sizeAs(tester, width: 320, scale: 2);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(
          body: SectionHeading('3ZERO administration', icon: Icons.shield),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('an action card is activatable by a screen reader', (
    tester,
  ) async {
    // `excludeSemantics: true` dropped the InkWell's semantics, tap action
    // included, so every card announced itself as a button and then handled no
    // activation. The home screen is built entirely from these, which made it
    // readable but unusable under TalkBack and VoiceOver.
    final handle = tester.ensureSemantics();
    var taps = 0;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: ActionCard(
            icon: Icons.eco_outlined,
            title: 'Log an eco-action',
            subtitle: 'Photograph something you did.',
            onTap: () => taps++,
          ),
        ),
      ),
    );
    await tester.pump();

    final node = tester.getSemantics(find.byType(ActionCard));
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.tap),
      isTrue,
      reason: 'the node announces itself as a button, so it must handle a tap',
    );

    await tester.tap(find.byType(ActionCard));
    await tester.pump();

    expect(taps, 1);
    handle.dispose();
  });

  group('colour pairings meet WCAG AA', () {
    // The SnackBar bug: four call sites set `backgroundColor: errorContainer`
    // and left the content colour at SnackBar's `onInverseSurface` default,
    // which measures 1.70:1 in light mode and 1.56 in dark. Every failed
    // sign-in, registration and application review was reported invisibly.
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      final scheme = theme.colorScheme;
      final mode = scheme.brightness.name;

      test('$mode: error snackbar pairing is readable', () {
        expect(
          _contrast(scheme.onErrorContainer, scheme.errorContainer),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('$mode: success snackbar pairing is readable', () {
        expect(
          _contrast(scheme.onSuccessContainer, scheme.successContainer),
          greaterThanOrEqualTo(4.5),
        );
      });

      test('$mode: warning reads on every surface it is painted on', () {
        // Was `#8D6E00` in light mode: 4.37 on surfaceContainerLow and 4.15 on
        // surfaceContainer, i.e. legal only on whichever container it happened
        // to land on.
        for (final surface in <Color>[
          scheme.surface,
          scheme.surfaceContainerLowest,
          scheme.surfaceContainerLow,
          scheme.surfaceContainer,
        ]) {
          expect(
            _contrast(scheme.warning, surface),
            greaterThanOrEqualTo(4.5),
            reason: 'warning on a $mode surface',
          );
        }
      });

      test('$mode: warning has a usable container pair', () {
        expect(
          _contrast(scheme.onWarningContainer, scheme.warningContainer),
          greaterThanOrEqualTo(4.5),
        );
      });
    }
  });

  group('password reset does not disclose whether an account exists', () {
    // The success wording is deliberately non-committal. The failure branch
    // reported `authErrorMessage`, whose answer for `user-not-found` is "That
    // email and password do not match" — a password on a screen that asks for
    // none, and a confirmation that the address is unregistered.
    test('identity-revealing codes are not reportable', () {
      for (final code in ['user-not-found', 'invalid-credential']) {
        expect(passwordResetMessage(code), isNull, reason: code);
      }
    });

    test('failures about the request itself are still reported', () {
      expect(passwordResetMessage('invalid-email'), isNotNull);
      expect(passwordResetMessage('network-request-failed'), isNotNull);
      expect(passwordResetMessage('too-many-requests'), isNotNull);
    });

    test('an unrecognised code stays silent rather than guessing', () {
      expect(passwordResetMessage('something-new'), isNull);
      expect(passwordResetMessage(null), isNull);
    });
  });

  test('the generic auth failure does not claim to be about signing in', () {
    // Registration reaches this fallback when the Firebase account was created
    // and the Firestore profile write then failed. "Something went wrong
    // signing you in" described the wrong step and sent people to a sign-in
    // screen where their new credentials worked perfectly well.
    expect(authErrorMessage(null), isNot(contains('signing you in')));
  });
}
