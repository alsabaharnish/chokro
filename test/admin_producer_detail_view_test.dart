/// The read-only producer view (EPR-44, EPR-46).
///
/// Two things on this screen are easy to build and dangerous to get wrong, and
/// both are about a claim the screen must NOT make.
///
/// EPR-46 requires every view of a producer's workspace to be recorded, and
/// the server writes that audit entry BEFORE it assembles anything. So a view
/// that could not be recorded is a view that did not happen — and the screen
/// has to say so rather than falling back to a generic error, which an Admin
/// reads as "try again" rather than "you did not see this".
///
/// The chain card has three states, not two. `verified` is nullable, and "not
/// checked" is not "checked and failed". A card that collapsed them would
/// either alarm nobody or alarm everybody.
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
import 'package:chokro/services/admin_oversight_service.dart';
import 'package:chokro/views/admin/admin_producer_detail_view.dart';
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

const _orgId = 'org-1';

DateTime _fixedClock() => DateTime.utc(2026, 9, 16, 6);

const _view = OrganizationView(
  orgId: _orgId,
  legalName: 'Padma Beverages Limited',
  tradeName: 'Padma',
  status: 'active',
  periodId: '2026-09',
  readOnly: true,
  impersonation: false,
  canWrite: false,
  capabilityNote:
      'A read-only copy of what this producer sees. No action taken here '
      'reaches their account.',
  memberCount: 4,
  certificates: <IssuedCertificate>[],
  doeRegistrationNo: 'DoE-2026-114',
);

ActivityTimeline _timeline({
  bool? verified,
  String? chainState,
  bool keyed = false,
  String? caveat,
  List<TimelineEntry> entries = const [],
}) {
  return ActivityTimeline(
    orgId: _orgId,
    entries: entries,
    verified: verified,
    chainState: chainState,
    keyed: keyed,
    verificationCaveat: caveat,
  );
}

Future<void> _pumpDetail(
  WidgetTester tester, {
  OrganizationViewResult view = const OrganizationViewResult(view: _view),
  ActivityTimeline? timeline,
  ActivityTimeline? verifiedTimeline,
  List<ReconciliationRow> reconciliation = const [],
  Size size = const Size(1200, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final router = GoRouter(
    initialLocation: '/admin/producers/$_orgId',
    routes: [
      GoRoute(
        path: '/home',
        builder: (_, _) => const Scaffold(body: Text('Home')),
      ),
      GoRoute(
        path: '/admin/producers/:orgId',
        builder: (_, state) =>
            AdminProducerDetailView(orgId: state.pathParameters['orgId']!),
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
        organizationViewProvider.overrideWith((ref, key) async => view),
        organizationTimelineProvider.overrideWith(
          (ref, orgId) async => timeline ?? _timeline(),
        ),
        verifiedTimelineProvider.overrideWith(
          (ref, orgId) async => verifiedTimeline ?? _timeline(verified: true),
        ),
        organizationReconciliationProvider.overrideWith(
          (ref, orgId) async => reconciliation,
        ),
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
  // EPR-46 — a view that was not recorded is a view that did not happen
  // -------------------------------------------------------------------------

  testWidgets('a view that could not be recorded says it was not opened', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      view: const OrganizationViewResult.failed(
        'The view could not be recorded in the audit log, so it was not '
        'opened.',
      ),
    );

    expect(find.text('The view was not opened'), findsOneWidget);
    // And the producer's data is not on screen behind the message. The audit
    // entry is written before assembly precisely so this cannot happen.
    expect(find.text('Padma Beverages Limited'), findsNothing);
    expect(find.text('DoE-2026-114'), findsNothing);
  });

  testWidgets('the read-only view names whose screen it is', (tester) async {
    await _pumpDetail(tester);

    // EPR-46's visual distinctness. The banner names the producer, because an
    // Admin three scrolls into a workspace has forgotten whose it is — which
    // is exactly when they are most likely to act on what they see.
    expect(find.text('You are looking at Padma’s own view'), findsOneWidget);
    expect(
      find.textContaining('No action taken here reaches their account'),
      findsOneWidget,
    );
    expect(find.text('Padma Beverages Limited'), findsOneWidget);
    expect(find.text('DoE-2026-114'), findsOneWidget);
  });

  testWidgets('the tint runs behind the whole tab, not just a banner', (
    tester,
  ) async {
    await _pumpDetail(tester);

    // Behind the scrolling content rather than above it, so it survives a
    // scroll. A banner that scrolls away takes the warning with it.
    final container = tester.widget<Container>(
      find
          .ancestor(
            of: find.byType(ListView),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(container.color, isNotNull);
    expect(container.color!.a, greaterThan(0));
  });

  // -------------------------------------------------------------------------
  // The chain card — three states, not two
  // -------------------------------------------------------------------------

  testWidgets('an unchecked chain is not reported as broken', (tester) async {
    await _pumpDetail(tester, timeline: _timeline());
    await _openTab(tester, 'History');

    expect(find.text('The chain has not been checked'), findsOneWidget);
    // Null is not false. Reporting an unwalked chain as broken would train an
    // Admin to ignore the one alarm that matters.
    expect(find.text('The chain is BROKEN'), findsNothing);
    expect(find.text('The chain is intact'), findsNothing);
    expect(find.widgetWithText(OutlinedButton, 'Verify the chain'), findsOneWidget);
  });

  testWidgets('verifying walks the chain and reports it intact', (tester) async {
    await _pumpDetail(
      tester,
      timeline: _timeline(),
      verifiedTimeline: _timeline(
        verified: true,
        keyed: true,
        caveat: 'Every entry links to the one before it, under an '
            'operator-held key.',
      ),
    );
    await _openTab(tester, 'History');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Verify the chain'));
    await tester.pumpAndSettle();

    expect(find.text('The chain is intact'), findsOneWidget);
  });

  testWidgets('an intact but UNKEYED chain carries its caveat (SEC-12)', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      timeline: _timeline(),
      verifiedTimeline: _timeline(
        verified: true,
        keyed: false,
        caveat: 'AUDIT_CHAIN_KEY is not set. This chain is tamper-evident '
            'against anyone without write access and is NOT evidence against '
            'an insider holding the database credential.',
      ),
    );
    await _openTab(tester, 'History');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Verify the chain'));
    await tester.pumpAndSettle();

    expect(find.text('The chain is intact'), findsOneWidget);
    // The caveat is part of the result, not a footnote. "Intact" without it
    // overstates the control — and on an unkeyed chain, overstates it to
    // exactly the adversary the log exists to catch.
    expect(
      find.textContaining('NOT evidence against an insider'),
      findsOneWidget,
    );
  });

  testWidgets('a broken chain says so and says what to do', (tester) async {
    await _pumpDetail(
      tester,
      timeline: _timeline(),
      verifiedTimeline: _timeline(verified: false, keyed: true),
    );
    await _openTab(tester, 'History');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Verify the chain'));
    await tester.pumpAndSettle();

    expect(find.text('The chain is BROKEN'), findsOneWidget);
    expect(find.textContaining('escalate'), findsOneWidget);
  });

  testWidgets('an organisation older than the log is not called broken', (
    tester,
  ) async {
    // The real case: a producer created before the audit log existed showed
    // "The chain is BROKEN — treat this organisation's history as unreliable
    // and escalate" on a record that never had a chain to break. An auditor
    // escalated twice over nothing stops reading the third one.
    await _pumpDetail(
      tester,
      timeline: _timeline(),
      verifiedTimeline: _timeline(
        verified: false,
        chainState: 'noChain',
        keyed: true,
      ),
    );
    await _openTab(tester, 'History');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Verify the chain'));
    await tester.pumpAndSettle();

    expect(find.text('No chain recorded'), findsOneWidget);
    expect(find.text('The chain is BROKEN'), findsNothing);
    expect(find.textContaining('escalate'), findsNothing);
    // And it does not read as a clean bill either — nothing before the log is
    // covered, and the card has to say so.
    expect(find.text('The chain is intact'), findsNothing);
  });

  testWidgets('a scan that hit its limit is not called broken', (tester) async {
    await _pumpDetail(
      tester,
      timeline: _timeline(),
      verifiedTimeline: _timeline(
        verified: false,
        chainState: 'partial',
        keyed: true,
      ),
    );
    await _openTab(tester, 'History');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Verify the chain'));
    await tester.pumpAndSettle();

    expect(find.text('Checked as far as the limit'), findsOneWidget);
    expect(find.text('The chain is BROKEN'), findsNothing);
    expect(find.text('The chain is intact'), findsNothing);
  });

  testWidgets('an unrecognised state falls through to the strict wording', (
    tester,
  ) async {
    // A state added server-side that this build does not know must not land on
    // a reassuring message. `verified` stays the authoritative signal and
    // anything unrecognised reads as unverified.
    await _pumpDetail(
      tester,
      timeline: _timeline(),
      verifiedTimeline: _timeline(
        verified: false,
        chainState: 'somethingNewerServersSay',
        keyed: true,
      ),
    );
    await _openTab(tester, 'History');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Verify the chain'));
    await tester.pumpAndSettle();

    expect(find.text('The chain is BROKEN'), findsOneWidget);
  });

  testWidgets('a state cannot dress up a chain the server did not verify', (
    tester,
  ) async {
    // `noChain` alongside `verified: true` is a contradiction, and the branch
    // order decides which half wins. It must be the server's boolean — a
    // client that let the refining string promote an unverified chain to a
    // verified one would be the whole control undone by a string compare.
    await _pumpDetail(
      tester,
      timeline: _timeline(),
      verifiedTimeline: _timeline(
        verified: false,
        chainState: 'intact',
        keyed: true,
      ),
    );
    await _openTab(tester, 'History');

    await tester.tap(find.widgetWithText(OutlinedButton, 'Verify the chain'));
    await tester.pumpAndSettle();

    expect(find.text('The chain is BROKEN'), findsOneWidget);
    expect(find.text('The chain is intact'), findsNothing);
  });

  testWidgets('an empty history is not a verified one', (tester) async {
    await _pumpDetail(tester, timeline: _timeline());
    await _openTab(tester, 'History');

    expect(
      find.text('Nothing recorded for this organisation yet.'),
      findsOneWidget,
    );
    // An organisation with no entries still has an unchecked chain, not a
    // clean one.
    expect(find.text('The chain has not been checked'), findsOneWidget);
  });

  // -------------------------------------------------------------------------
  // Per-producer reconciliation
  // -------------------------------------------------------------------------

  testWidgets('an unchecked period shows no variance rather than zero', (
    tester,
  ) async {
    await _pumpDetail(
      tester,
      reconciliation: const [
        ReconciliationRow(
          orgId: _orgId,
          periodId: '2026-09',
          incrementedMassMg: 5000000,
        ),
      ],
    );
    await _openTab(tester, 'Reconciliation');

    // Zero variance means "checked and agreed". An unchecked period rendering
    // as zero is how an entirely unverified year looks clean.
    expect(find.text('0 kg'), findsNothing);
    expect(find.textContaining('Never checked'), findsWidgets);
  });
}
