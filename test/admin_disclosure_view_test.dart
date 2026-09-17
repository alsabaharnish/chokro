/// The disclosure screen (SEC-13) — the only surface that re-identifies a
/// person.
///
/// Three things are worth testing here and nothing else much is.
///
/// **It is locked, and the lock is not cosmetic.** The form must not exist
/// before the password, because a form an Admin can fill in and then be
/// refused is a form they fill in twice — and on the second pass they write a
/// shorter declaration.
///
/// **Nothing can be submitted incomplete.** The reference number, the written
/// reason and the attestation are each required, and the server refuses
/// without them. A screen that let an Admin press the button and then showed a
/// 400 would teach them the fields are advisory.
///
/// **The register is readable without unlocking.** Oversight has to be cheaper
/// than the thing it oversees, and a test is the only thing that will keep it
/// that way once somebody tidies this screen.
library;

import 'package:chokro/controllers/disclosure_controller.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/disclosure_model.dart';
import 'package:chokro/services/disclosure_service.dart';
import 'package:chokro/services/location_service.dart';
import 'package:chokro/services/organization_service.dart'
    show OrgActionException;
import 'package:chokro/views/admin/admin_disclosure_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _why =
    'Answering the Department of Environment audit of Padma Beverages.';

class _FakeService implements DisclosureService {
  _FakeService({
    this.register_ = const DisclosureRegister(
      entries: [],
      complete: true,
      limit: 100,
    ),
    this.result,
    this.reauthError,
    this.resolveError,
  });

  final DisclosureRegister register_;
  final DisclosureResult? result;
  final Object? reauthError;
  final Object? resolveError;

  int reauthCalls = 0;
  int resolveCalls = 0;
  String? lastDeclaration;
  DisclosureLocation? lastLocation;

  @override
  Future<void> reauthenticate(String password) async {
    reauthCalls += 1;
    if (reauthError != null) throw reauthError!;
  }

  @override
  Future<DisclosureResult> resolve({
    required String orgId,
    required String disposalRef,
    required String doeReference,
    required String declaration,
    required DisclosureLocation location,
    String? periodId,
  }) async {
    resolveCalls += 1;
    lastDeclaration = declaration;
    lastLocation = location;
    if (resolveError != null) throw resolveError!;
    return result ??
        const DisclosureResult(
          found: true,
          exhaustive: true,
          attributions: [],
          registerId: 'register-1',
          disposalId: 'd1',
          disposalPresent: true,
          binId: 'bin-7',
        );
  }

  @override
  Future<DisclosureRegister> register({int limit = 100, String? orgId}) async =>
      register_;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeLocation implements LocationService {
  _FakeLocation(this.outcome);
  final LocationOutcome outcome;

  @override
  Future<LocationResult> getCurrentLocation({
    Duration timeout = const Duration(seconds: 20),
  }) async => switch (outcome) {
    LocationOutcome.fixed => const LocationResult(
      outcome: LocationOutcome.fixed,
      latitude: 23.8103,
      longitude: 90.4125,
      accuracyMeters: 12,
    ),
    _ => LocationResult(outcome: outcome),
  };

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_FakeService> _pump(
  WidgetTester tester, {
  _FakeService? service,
  LocationOutcome location = LocationOutcome.fixed,
}) async {
  final fake = service ?? _FakeService();
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        disclosureServiceProvider.overrideWithValue(fake),
        locationServiceProvider.overrideWithValue(_FakeLocation(location)),
        disclosureClockProvider.overrideWithValue(
          () => DateTime.utc(2026, 9, 17, 6),
        ),
      ],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const Scaffold(body: AdminDisclosureTab()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fake;
}

Future<void> _unlock(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(FilledButton, 'Unlock').first);
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).last, 'correct-horse');
  await tester.tap(find.widgetWithText(FilledButton, 'Unlock').last);
  await tester.pumpAndSettle();
}

Future<void> _fill(WidgetTester tester, {String why = _why}) async {
  await tester.enterText(
    find.widgetWithText(TextField, 'Organisation id'),
    'org-1',
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Disposal reference'),
    'a' * 24,
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Department of Environment request number'),
    'DoE/EPR/2026/0041',
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Why you are doing this'),
    why,
  );
  await tester.pumpAndSettle();
}

void main() {
  // -------------------------------------------------------------------------
  // The lock
  // -------------------------------------------------------------------------

  testWidgets('it opens locked, with no form to fill in', (tester) async {
    await _pump(tester);

    expect(find.text('Locked'), findsOneWidget);
    // Not merely disabled — absent. A form an Admin can complete and then be
    // refused is a form they fill in twice, and the second declaration is
    // always the shorter one.
    expect(find.widgetWithText(TextField, 'Organisation id'), findsNothing);
    expect(
      find.widgetWithText(FilledButton, 'Record and resolve'),
      findsNothing,
    );
  });

  testWidgets('it says what this screen is before it says anything else', (
    tester,
  ) async {
    await _pump(tester);

    expect(
      find.text('This is the only screen that re-identifies a person'),
      findsOneWidget,
    );
    expect(find.textContaining('Every use is recorded'), findsOneWidget);
  });

  testWidgets('it tells the Admin the password does not come here', (
    tester,
  ) async {
    await _pump(tester);
    // True, and worth saying: the step-up goes to Firebase and this service
    // never receives it.
    expect(
      find.textContaining('goes to Firebase, not to Chokro'),
      findsOneWidget,
    );
  });

  testWidgets('a wrong password leaves it locked and says so', (tester) async {
    final fake = await _pump(
      tester,
      service: _FakeService(
        reauthError: const OrgActionException('That password is not correct.'),
      ),
    );

    await _unlock(tester);

    expect(fake.reauthCalls, 1);
    expect(find.text('That password is not correct.'), findsOneWidget);
    expect(find.text('Locked'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Organisation id'), findsNothing);
  });

  testWidgets('the right password reveals the form', (tester) async {
    await _pump(tester);
    await _unlock(tester);

    expect(find.textContaining('Unlocked'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Organisation id'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // Nothing incomplete can be submitted
  // -------------------------------------------------------------------------

  testWidgets('the button is dead until every field and the attestation', (
    tester,
  ) async {
    await _pump(tester);
    await _unlock(tester);

    FilledButton button() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Record and resolve'),
    );

    expect(button().onPressed, isNull);

    await _fill(tester);
    // Everything filled, attestation still unticked.
    expect(button().onPressed, isNull);

    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    expect(button().onPressed, isNotNull);
  });

  testWidgets('a one-word reason is not a reason', (tester) async {
    await _pump(tester);
    await _unlock(tester);
    await _fill(tester, why: 'audit');
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    // The server refuses it too. Refusing here as well means an Admin never
    // learns that the field is advisory.
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Record and resolve'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('the declaration is sent verbatim', (tester) async {
    final fake = await _pump(tester);
    await _unlock(tester);
    await _fill(tester);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Record and resolve'));
    await tester.pumpAndSettle();

    expect(fake.resolveCalls, 1);
    expect(fake.lastDeclaration, _why);
  });

  testWidgets('it says a record is written before offering the button', (
    tester,
  ) async {
    await _pump(tester);
    await _unlock(tester);

    expect(
      find.textContaining('no way to resolve a reference without leaving a record'),
      findsOneWidget,
    );
  });

  // -------------------------------------------------------------------------
  // Location — the case a real device will not reproduce on demand
  // -------------------------------------------------------------------------

  testWidgets('location starts as not-recorded, never as blank', (
    tester,
  ) async {
    await _pump(tester);
    await _unlock(tester);

    expect(find.text('Location not recorded yet'), findsOneWidget);
  });

  testWidgets('a refused location is recorded AS refused', (tester) async {
    final fake = await _pump(tester, location: LocationOutcome.denied);
    await _unlock(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Add location'));
    await tester.pumpAndSettle();

    expect(find.text('Refused by the Admin’s device'), findsOneWidget);

    await _fill(tester);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Record and resolve'));
    await tester.pumpAndSettle();

    // And it still goes through. Blocking on a declined location would make
    // the control bypassable with a system setting.
    expect(fake.resolveCalls, 1);
    expect(fake.lastLocation?.status, 'denied');
  });

  testWidgets('a granted location is sent with its coordinates', (
    tester,
  ) async {
    final fake = await _pump(tester, location: LocationOutcome.fixed);
    await _unlock(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Add location'));
    await tester.pumpAndSettle();
    expect(find.text('23.81030, 90.41250 ±12m'), findsOneWidget);

    await _fill(tester);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Record and resolve'));
    await tester.pumpAndSettle();

    expect(fake.lastLocation?.status, 'granted');
    expect(fake.lastLocation?.latitude, 23.8103);
  });

  testWidgets('never asking for a location still sends a status', (
    tester,
  ) async {
    final fake = await _pump(tester);
    await _unlock(tester);
    await _fill(tester);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Record and resolve'));
    await tester.pumpAndSettle();

    // Never null. The register row has to say which of the three happened.
    expect(fake.lastLocation?.status, 'unavailable');
  });

  // -------------------------------------------------------------------------
  // After the act
  // -------------------------------------------------------------------------

  testWidgets('it locks again afterwards — a second one is a second decision', (
    tester,
  ) async {
    await _pump(tester);
    await _unlock(tester);
    await _fill(tester);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Record and resolve'));
    await tester.pumpAndSettle();

    expect(find.text('Locked'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Organisation id'), findsNothing);
  });

  testWidgets('a stopped-early search does not render as a not-found', (
    tester,
  ) async {
    await _pump(
      tester,
      service: _FakeService(
        result: const DisclosureResult(
          found: false,
          exhaustive: false,
          attributions: [],
          note: 'Stopped after 20000 attributions without a match.',
        ),
      ),
    );
    await _unlock(tester);
    await _fill(tester);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Record and resolve'));
    await tester.pumpAndSettle();

    // Telling a regulator a genuine row is unknown is the worst answer this
    // feature can give.
    expect(
      find.text('The search stopped early — this is NOT a not-found'),
      findsOneWidget,
    );
    expect(find.text('Not this organisation’s reference'), findsNothing);
  });

  testWidgets('a failed register write is stated, not hidden', (tester) async {
    await _pump(
      tester,
      service: _FakeService(
        result: const DisclosureResult(
          found: true,
          exhaustive: true,
          attributions: [],
          registerId: null,
          disposalPresent: true,
        ),
      ),
    );
    await _unlock(tester);
    await _fill(tester);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Record and resolve'));
    await tester.pumpAndSettle();

    // The access happened either way, and the screen has to say the readable
    // row is missing rather than let it look like it was never needed.
    expect(
      find.textContaining('register row could not be written'),
      findsOneWidget,
    );
    expect(find.textContaining('this access IS recorded'), findsOneWidget);
  });

  testWidgets('an expired unlock relocks the screen and says why', (
    tester,
  ) async {
    // The server refuses an `auth_time` older than five minutes. The client
    // window is thirty seconds shorter so this should be rare — but a slow
    // form, a cold start or a clock skew can still land here, and when it does
    // the screen must drop back to locked rather than leave a form that looks
    // usable and is not.
    await _pump(
      tester,
      service: _FakeService(
        resolveError: const OrgActionException(
          'Your unlock has expired. Enter your password again to continue.',
          code: 'reauthentication_required',
        ),
      ),
    );
    await _unlock(tester);
    await _fill(tester);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Record and resolve'));
    await tester.pumpAndSettle();

    expect(find.textContaining('unlock has expired'), findsOneWidget);
    expect(find.text('Locked'), findsOneWidget);
    // And the form is gone, so the declaration cannot be half-resubmitted
    // against a session that is no longer valid.
    expect(find.widgetWithText(TextField, 'Organisation id'), findsNothing);
  });

  // -------------------------------------------------------------------------
  // The register
  // -------------------------------------------------------------------------

  testWidgets('the register reads without unlocking anything', (tester) async {
    await _pump(
      tester,
      service: _FakeService(
        register_: DisclosureRegister(
          complete: true,
          limit: 100,
          entries: [
            DisclosureRecord(
              id: 'r1',
              kind: 'identity',
              location: const DisclosureLocation.denied(),
              adminName: 'Ayesha Rahman',
              doeReference: 'DoE/EPR/2026/0041',
              declaration: _why,
              at: DateTime.utc(2026, 9, 16, 10),
            ),
          ],
        ),
      ),
    );

    // Still locked, and the register is right there. Oversight has to be
    // cheaper than the thing it oversees.
    expect(find.text('Locked'), findsOneWidget);
    expect(find.text('Named a Champion'), findsOneWidget);
    expect(find.text('“$_why”'), findsOneWidget);
    expect(find.textContaining('Refused by the Admin'), findsOneWidget);
  });

  testWidgets('a truncated register says so, loudly', (tester) async {
    await _pump(
      tester,
      service: _FakeService(
        register_: DisclosureRegister(
          complete: false,
          limit: 100,
          entries: [
            DisclosureRecord(
              id: 'r1',
              kind: 'resolve',
              location: const DisclosureLocation.unavailable(),
              at: DateTime.utc(2026, 9, 16),
            ),
          ],
        ),
      ),
    );

    expect(
      find.textContaining('a missing row matters most'),
      findsOneWidget,
    );
  });

  testWidgets('an empty register says nothing has ever happened', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.text('No disclosure has ever been made.'), findsOneWidget);
  });
}
