/// The EPR oversight console (EPR-43, EPR-45, EPR-47, EPR-48, EPR-17).
///
/// `admin_oversight_model_test.dart` proves absence is MODELLED correctly —
/// that a variance is null when nobody checked, that precision is null below
/// the sample floor. These tests prove absence is RENDERED correctly, which is
/// a different claim and the one that actually protects an Admin.
///
/// A model that faithfully holds `null` and a screen that draws it as `0%` is
/// still a screen that says an unverified year is clean. Every test here is
/// about a figure the server did not send, and what the Admin sees instead.
library;

import 'package:chokro/controllers/account_profile_controller.dart';
import 'package:chokro/controllers/admin_oversight_controller.dart';
import 'package:chokro/controllers/auth_controller.dart';
import 'package:chokro/controllers/cart_controller.dart';
import 'package:chokro/core/account_profile.dart';
import 'package:chokro/core/constants.dart';
import 'package:chokro/core/theme.dart';
import 'package:chokro/models/admin_oversight_model.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/views/admin/admin_epr_oversight_view.dart';
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

/// A fixed clock, so "which period does the console open on" has one answer
/// rather than one that changes at midnight Dhaka time mid-run.
DateTime _fixedClock() => DateTime.utc(2026, 9, 16, 6);

const _emptyAccuracy = AccuracySnapshot(
  reviewed: 0,
  judged: 0,
  correct: 0,
  incorrect: 0,
  unclear: 0,
  minSample: 30,
  windowPeriods: <String>[],
  trend: <AccuracyTrendPoint>[],
);

const _emptyRegister = IssuanceRegister(
  certificates: <IssuedCertificate>[],
  issued: 0,
  superseded: 0,
  revoked: 0,
  truncated: false,
);

const _emptyReconciliation = ReconciliationOverview(
  periodsExamined: 0,
  reconciled: 0,
  mismatched: <ReconciliationRow>[],
  uncheckedCount: 0,
  unchecked: <ReconciliationRow>[],
  uncheckedMassMg: 0,
);

Future<void> _pumpConsole(
  WidgetTester tester, {
  List<AnomalyFinding> anomalies = const [],
  List<DeclarationReviewRow> declarations = const [],
  ReconciliationOverview reconciliation = _emptyReconciliation,
  AccuracySnapshot accuracy = _emptyAccuracy,
  List<SampledMatch> accuracyQueue = const [],
  IssuanceRegister issuance = _emptyRegister,
  Size size = const Size(1200, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = GoRouter(
    initialLocation: '/admin/epr',
    routes: [
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('Home')),
      ),
      GoRoute(
        path: '/admin/epr',
        builder: (_, _) => const AdminEprOversightView(),
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
        oversightClockProvider.overrideWithValue(_fixedClock),
        anomalyQueueProvider.overrideWith((ref) async => anomalies),
        declarationReviewProvider.overrideWith((ref) async => declarations),
        reconciliationProvider.overrideWith((ref) async => reconciliation),
        accuracySnapshotProvider.overrideWith((ref) async => accuracy),
        accuracyQueueProvider.overrideWith((ref) async => accuracyQueue),
        issuanceRegisterProvider.overrideWith((ref) async => issuance),
      ],
      child: MaterialApp.router(
        theme: AppTheme.light(),
        routerConfig: router,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openTab(WidgetTester tester, String label) async {
  await tester.tap(find.widgetWithText(Tab, label));
  await tester.pumpAndSettle();
}

void main() {
  // -------------------------------------------------------------------------
  // The shape of the console
  // -------------------------------------------------------------------------

  testWidgets('five surfaces sit behind one shared period selector', (
    tester,
  ) async {
    await _pumpConsole(tester);

    for (final tab in const [
      'Anomalies',
      'Declarations',
      'Reconciliation',
      'Accuracy',
      'Issuance',
    ]) {
      expect(find.widgetWithText(Tab, tab), findsOneWidget);
    }

    // One selector, not five. Two tabs a tap apart must never disagree about
    // which month is being investigated.
    expect(find.byType(DropdownButtonFormField<String>), findsOneWidget);
    expect(find.text('September 2026'), findsOneWidget);
  });

  testWidgets('the selected period survives a tab change', (tester) async {
    await _pumpConsole(tester);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AdminEprOversightView)),
    );
    container.read(oversightPeriodProvider.notifier).select('2026-07');
    await tester.pumpAndSettle();

    expect(find.text('July 2026'), findsOneWidget);

    await _openTab(tester, 'Reconciliation');
    await _openTab(tester, 'Accuracy');

    // The thread through the console. An Admin investigating July who moves
    // between surfaces is still investigating July.
    expect(find.text('July 2026'), findsOneWidget);
    expect(container.read(oversightPeriodProvider), '2026-07');
  });

  // -------------------------------------------------------------------------
  // Anomalies (EPR-45)
  // -------------------------------------------------------------------------

  testWidgets('an empty queue does not claim anything was examined', (
    tester,
  ) async {
    await _pumpConsole(tester);

    expect(find.text('Nothing flagged'), findsOneWidget);
    // The distinction that keeps a queue honest. "No open findings" and
    // "this period has been checked" are different statements, and a console
    // that blurred them would make an unscanned platform look supervised.
    expect(
      find.textContaining('does not mean a period has been examined'),
      findsOneWidget,
    );
  });

  testWidgets('a finding shows the threshold it was judged against', (
    tester,
  ) async {
    await _pumpConsole(
      tester,
      anomalies: const [
        AnomalyFinding(
          id: 'finding-1',
          orgId: 'org-1',
          periodId: '2026-09',
          type: 'binConcentration',
          subjectType: 'bin',
          subjectId: 'bin-42',
          severity: 'high',
          status: 'open',
          summary: 'One bin accounts for most of this period.',
          figures: {'share': 0.82, 'threshold': 0.6},
        ),
      ],
    );

    expect(find.text('One bin accounts for most of this period.'), findsOneWidget);
    expect(find.text('Bin concentration'), findsOneWidget);

    // An Admin reading this six months later needs the threshold in force at
    // the time, not a prettified summary that has lost it.
    expect(find.textContaining('threshold'), findsWidgets);
  });

  // -------------------------------------------------------------------------
  // Reconciliation (EPR-48) — the screen with the most to get wrong
  // -------------------------------------------------------------------------

  testWidgets('coverage reports the total never checked, not the list length', (
    tester,
  ) async {
    await _pumpConsole(
      tester,
      reconciliation: ReconciliationOverview(
        periodsExamined: 40,
        reconciled: 8,
        mismatched: const [],
        // 32 unchecked, of which the server sent 2.
        uncheckedCount: 32,
        unchecked: const [
          ReconciliationRow(
            orgId: 'org-1',
            periodId: '2026-08',
            incrementedMassMg: 5000000,
          ),
          ReconciliationRow(
            orgId: 'org-2',
            periodId: '2026-08',
            incrementedMassMg: 3000000,
          ),
        ],
        uncheckedMassMg: 91000000,
      ),
    );
    await _openTab(tester, 'Reconciliation');

    // 32, not 2. "How much of this has anyone verified" cannot be read off a
    // bounded list, and a register that answered 2 would be reassuring and
    // wrong.
    expect(find.text('32 (80%)'), findsOneWidget);
    expect(find.text('2 (5%)'), findsNothing);
    expect(find.text('Checked and agreed'), findsOneWidget);
    expect(find.text('8'), findsOneWidget);
  });

  testWidgets('a truncated unchecked list says it is truncated', (tester) async {
    await _pumpConsole(
      tester,
      reconciliation: ReconciliationOverview(
        periodsExamined: 40,
        reconciled: 8,
        mismatched: const [],
        uncheckedCount: 32,
        unchecked: const [
          ReconciliationRow(
            orgId: 'org-1',
            periodId: '2026-08',
            incrementedMassMg: 5000000,
          ),
        ],
        uncheckedMassMg: 91000000,
      ),
    );
    await _openTab(tester, 'Reconciliation');

    expect(find.textContaining('Showing 1 of 32'), findsOneWidget);
  });

  testWidgets('no periods examined renders no percentage rather than 0%', (
    tester,
  ) async {
    await _pumpConsole(tester);
    await _openTab(tester, 'Reconciliation');

    // A platform with nothing in it has not achieved 100% coverage, and has
    // not achieved 0% either. There is nothing to divide by, so there is no
    // percentage — and printing one would invent a figure.
    expect(find.text('Never checked'), findsWidgets);
    expect(find.text('0'), findsWidgets);
    expect(find.textContaining('%'), findsNothing);
  });

  testWidgets('a mismatch shows both figures and neither as the truth', (
    tester,
  ) async {
    await _pumpConsole(
      tester,
      reconciliation: ReconciliationOverview(
        periodsExamined: 3,
        reconciled: 2,
        mismatched: [
          ReconciliationRow(
            orgId: 'org-1',
            periodId: '2026-09',
            incrementedMassMg: 5000000,
            recomputedMassMg: 4800000,
            variance: 200000,
            matched: false,
            recomputedAt: DateTime.utc(2026, 9, 15),
            attributionCount: 120,
          ),
        ],
        uncheckedCount: 0,
        unchecked: const [],
        uncheckedMassMg: 0,
      ),
    );
    await _openTab(tester, 'Reconciliation');

    // QA-3. A disagreement is evidence of a fault, not a number to tidy away,
    // so the screen must not present either figure as authoritative.
    expect(
      find.textContaining('does not overwrite the incremented counter'),
      findsOneWidget,
    );
    expect(find.text('5 kg'), findsOneWidget);
    expect(find.text('4.8 kg'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // Accuracy (EPR-17) — the figure that goes into report methodology
  // -------------------------------------------------------------------------

  testWidgets('an unmeasurable precision states the server\'s reason', (
    tester,
  ) async {
    await _pumpConsole(
      tester,
      accuracy: const AccuracySnapshot(
        reviewed: 4,
        judged: 4,
        correct: 4,
        incorrect: 0,
        unclear: 0,
        minSample: 30,
        windowPeriods: ['2026-09'],
        trend: <AccuracyTrendPoint>[],
        precisionAbsenceReason:
            'Only 4 of a required 30 samples have been reviewed.',
        recallAbsenceReason:
            'Recall cannot be measured without a ground-truth set of '
            'packaging that was never recognised.',
      ),
    );
    await _openTab(tester, 'Accuracy');

    // Four out of four correct is 100%, and printing it would be the single
    // most misleading number this console could produce. The reason is shown
    // instead — never a dash, never a zero, and never the flattering figure.
    expect(
      find.text('Only 4 of a required 30 samples have been reviewed.'),
      findsOneWidget,
    );
    expect(find.text('100.0%'), findsNothing);
  });

  testWidgets('recall absence is stated even when precision is measurable', (
    tester,
  ) async {
    await _pumpConsole(
      tester,
      accuracy: const AccuracySnapshot(
        reviewed: 40,
        judged: 38,
        correct: 34,
        incorrect: 4,
        unclear: 2,
        minSample: 30,
        windowPeriods: ['2026-08', '2026-09'],
        trend: <AccuracyTrendPoint>[],
        precision: 0.894,
        unclearShare: 0.05,
        recallAbsenceReason:
            'Recall cannot be measured without a ground-truth set.',
      ),
    );
    await _openTab(tester, 'Accuracy');

    expect(find.text('89.4%'), findsOneWidget);
    // A precision figure without its recall caveat reads as "the model is 89%
    // accurate", which is a claim about something nobody measured.
    expect(
      find.text('Recall cannot be measured without a ground-truth set.'),
      findsOneWidget,
    );
    // And the unjudged share, because a high figure here says the PHOTOGRAPHS
    // are the problem rather than the model.
    expect(
      find.textContaining('could not be judged and is excluded'),
      findsOneWidget,
    );
  });

  // -------------------------------------------------------------------------
  // Issuance (EPR-47)
  // -------------------------------------------------------------------------

  testWidgets('a truncated register says so', (tester) async {
    await _pumpConsole(
      tester,
      issuance: IssuanceRegister(
        certificates: [
          IssuedCertificate(
            serial: 'CHKR-PP-ABCD-2345',
            orgId: 'org-1',
            tradeName: 'Padma Beverages',
            periodId: '2026-09',
            status: 'issued',
            contentHash: 'a' * 64,
            collectedMassMg: 5000000,
            issuedAt: DateTime.utc(2026, 9, 10),
          ),
        ],
        issued: 1,
        superseded: 0,
        revoked: 0,
        truncated: true,
      ),
    );
    await _openTab(tester, 'Issuance');

    expect(find.text('CHKR-PP-ABCD-2345'), findsOneWidget);
    // "Which certificates are affected by this fault" is the question this
    // register answers, and a silent truncation would be the worst possible
    // answer to it.
    expect(find.text('This register is truncated'), findsOneWidget);
    expect(find.textContaining('More certificates exist'), findsOneWidget);
  });

  testWidgets('a truncated register that came back EMPTY does not claim '
      'nothing was issued', (tester) async {
    // Found by writing these tests. The empty branch ran before the truncation
    // check and discarded it, so a bounded read returning nothing told an
    // Admin "Nothing has been issued yet" — a positive false claim on the one
    // screen where a missed certificate is the whole risk.
    await _pumpConsole(
      tester,
      issuance: const IssuanceRegister(
        certificates: [],
        issued: 0,
        superseded: 0,
        revoked: 0,
        truncated: true,
      ),
    );
    await _openTab(tester, 'Issuance');

    expect(find.text('Nothing has been issued yet.'), findsNothing);
    expect(find.text('This register is truncated'), findsOneWidget);
    expect(find.textContaining('NOT a statement'), findsOneWidget);
  });

  testWidgets('an empty filtered register names the filter, not the register', (
    tester,
  ) async {
    // Also found here. With `revoked` selected and nothing revoked, the screen
    // said "Nothing has been issued yet" — false whenever anything has been
    // issued, and reassurance about a question nobody asked. The anomaly queue
    // already got this right; this tab did not.
    await _pumpConsole(tester);
    await _openTab(tester, 'Issuance');

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AdminEprOversightView)),
    );
    container.read(issuanceFilterProvider.notifier).select('revoked');
    await tester.pumpAndSettle();

    expect(find.text('Nothing revoked'), findsOneWidget);
    expect(find.text('Nothing has been issued yet.'), findsNothing);
  });
}
