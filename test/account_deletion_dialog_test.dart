/// The Admin's account-deletion flow (SEC-13).
///
/// Two claims are tested, and they are the two the flow exists to make.
///
/// **What is kept is shown before the button.** An Admin is acting for someone
/// who is not in the room and will be asked afterwards what happened to their
/// data. If the retained list appears only on the outcome screen it arrives
/// too late to be of any use.
///
/// **A partial deletion never renders as a clean one.** The server answers 207
/// when a step failed. Collapsing that into "Deleted" is how somebody is told
/// they were forgotten when they were not.
library;

import 'package:chokro/controllers/admin_users_controller.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/account_deletion_model.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/services/account_deletion_service.dart';
import 'package:chokro/views/admin/account_deletion_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

const _champion = UserModel(
  uid: 'champion-1',
  name: 'Rahim Uddin',
  email: 'rahim@example.com',
  role: 'buyer',
  status: 'active',
);

const _retained = [
  RetainedCategory(
    what: 'Disposal records and their photographs',
    why: 'The evidence behind certificates already issued to producers.',
    contested: true,
  ),
  RetainedCategory(
    what: 'Attributions — the gram figures',
    why: 'They hold no account reference at all.',
    contested: false,
  ),
];

const _erased = [
  ErasedCategory(what: 'Name, email address and profile photograph', where: 'users'),
  ErasedCategory(what: 'The sign-in account itself', where: 'Firebase Auth'),
];

const _plan = DeletionPlan(
  uid: 'champion-1',
  accountExists: true,
  alreadyDeleted: false,
  erased: _erased,
  retained: _retained,
  name: 'Rahim Uddin',
  email: 'rahim@example.com',
);

class _FakeService implements AccountDeletionService {
  _FakeService({DeletionPlan? plan, this.outcome, this.planError})
    : plan_ = plan ?? _plan;

  final DeletionPlan plan_;
  final DeletionOutcome? outcome;
  final Object? planError;
  int deleteCalls = 0;
  String lastReason = '';

  @override
  Future<DeletionPlan> plan(String uid) async {
    if (planError != null) throw planError!;
    return plan_;
  }

  @override
  Future<DeletionOutcome> delete(String uid, {String reason = ''}) async {
    deleteCalls += 1;
    lastReason = reason;
    return outcome ??
        const DeletionOutcome(
          uid: 'champion-1',
          complete: true,
          alreadyDeleted: false,
          erased: ['Identity fields cleared and the account tombstoned'],
          failed: [],
          retained: _retained,
        );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_FakeService> _open(
  WidgetTester tester, {
  _FakeService? service,
}) async {
  final fake = service ?? _FakeService();
  tester.view.physicalSize = const Size(900, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [accountDeletionServiceProvider.overrideWithValue(fake)],
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => showAccountDeletionDialog(context, _champion),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return fake;
}

void main() {
  testWidgets('what is kept is shown before the delete button', (tester) async {
    await _open(tester);

    expect(find.text('What is kept'), findsOneWidget);
    expect(find.text('Disposal records and their photographs'), findsOneWidget);
    expect(find.text('What is removed'), findsOneWidget);

    // And the button exists alongside it, so the Admin reads the list on the
    // same screen where they decide.
    expect(
      find.widgetWithText(FilledButton, 'Delete permanently'),
      findsOneWidget,
    );
  });

  testWidgets('a contested retention is marked as Chokro\'s position', (
    tester,
  ) async {
    await _open(tester);

    // An Admin answering "will my disposals be deleted?" has to know which
    // half of the answer is settled law and which is Chokro's position.
    expect(find.text('Chokro’s position'), findsOneWidget);
    expect(find.textContaining('a lawyer has not yet confirmed'), findsOneWidget);
  });

  testWidgets('the button says what happens, not OK', (tester) async {
    await _open(tester);

    expect(find.widgetWithText(FilledButton, 'Delete permanently'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'OK'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Confirm'), findsNothing);
  });

  testWidgets('nothing is deleted until the button is pressed', (tester) async {
    final fake = await _open(tester);

    expect(fake.deleteCalls, 0);

    await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
    await tester.pumpAndSettle();

    expect(fake.deleteCalls, 1);
  });

  testWidgets('the recorded reason is sent', (tester) async {
    final fake = await _open(tester);

    await tester.enterText(find.byType(TextField), 'Requested by email 16 Sept');
    await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
    await tester.pumpAndSettle();

    expect(fake.lastReason, 'Requested by email 16 Sept');
  });

  testWidgets('a clean run reports every step completed', (tester) async {
    await _open(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
    await tester.pumpAndSettle();

    expect(find.text('Account deleted'), findsOneWidget);
    expect(find.text('Every step completed'), findsOneWidget);
    // And the retained list is repeated, because it is what the Admin will be
    // asked about after the fact.
    expect(find.text('What is still kept'), findsOneWidget);
  });

  testWidgets('a PARTIAL deletion does not render as a clean one', (
    tester,
  ) async {
    await _open(
      tester,
      service: _FakeService(
        outcome: const DeletionOutcome(
          uid: 'champion-1',
          complete: false,
          alreadyDeleted: false,
          erased: ['Identity fields cleared and the account tombstoned'],
          failed: ['Profile photograph: cloudinary down'],
          retained: _retained,
        ),
      ),
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Delete permanently'));
    await tester.pumpAndSettle();

    expect(find.text('Partly deleted'), findsOneWidget);
    expect(find.text('Some of this did not run'), findsOneWidget);
    expect(find.textContaining('cloudinary down'), findsOneWidget);

    // The two claims that must never both appear.
    expect(find.text('Account deleted'), findsNothing);
    expect(find.text('Every step completed'), findsNothing);
  });

  testWidgets('an absent `complete` field reads as incomplete, not complete', (
    tester,
  ) async {
    // A missing field must never render as reassurance on this screen.
    final outcome = DeletionOutcome.fromJson(const {
      'uid': 'champion-1',
      'erased': ['Identity fields cleared'],
      'failed': <String>[],
    });
    expect(outcome.complete, isFalse);
  });

  testWidgets('an already-deleted account offers no delete button', (
    tester,
  ) async {
    await _open(
      tester,
      service: _FakeService(
        plan: const DeletionPlan(
          uid: 'champion-1',
          accountExists: true,
          alreadyDeleted: true,
          erased: _erased,
          retained: _retained,
        ),
      ),
    );

    expect(find.text('Already deleted'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Delete permanently'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a plan that fails to load offers a retry and no delete', (
    tester,
  ) async {
    await _open(
      tester,
      service: _FakeService(planError: Exception('service unavailable')),
    );

    expect(find.text('That did not run'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Delete permanently'),
    );
    expect(button.onPressed, isNull);
  });
}
