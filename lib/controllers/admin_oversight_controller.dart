

/// The Admin oversight console's state (EPR-43 to EPR-48).
///
/// ## Every provider here is `autoDispose`, and one deliberately is not
///
/// These are consoles an Admin opens, works, and leaves. Holding a queue alive
/// after they navigate away would keep a stale list in memory and show it
/// unchanged on return — on a screen whose entire purpose is "what needs a
/// decision right now", a stale list is worse than a spinner.
///
/// [oversightPeriodProvider] is the exception. It is the selected reporting
/// period, and it must survive a tab change: an Admin investigating September
/// who switches from the anomaly queue to the accuracy panel is still
/// investigating September.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/epr_period.dart';
import '../models/admin_oversight_model.dart';
import '../services/admin_oversight_service.dart';

final adminOversightServiceProvider = Provider<AdminOversightService>(
  (ref) => AdminOversightService(),
);

/// The clock the period selector starts from.
///
/// Overridden in tests, so "which period does the console open on" has a fixed
/// answer rather than one that changes at midnight Dhaka time mid-run. The same
/// injection `attribution_controller.dart` uses, for the same reason.
final oversightClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// The period the console is investigating.
///
/// Not `autoDispose`: it is the thread running through every tab.
class OversightPeriodController extends Notifier<String> {
  @override
  String build() => periodIdFor(ref.read(oversightClockProvider)());

  /// Refuses a malformed period rather than querying with it.
  ///
  /// A bad period returns empty results, which a console renders as a quiet
  /// month — indistinguishable from a real one, and on a reconciliation screen
  /// that reads as "nothing to check here".
  void select(String periodId) {
    if (!isValidPeriodId(periodId)) return;
    state = periodId;
  }
}

final oversightPeriodProvider =
    NotifierProvider<OversightPeriodController, String>(
      OversightPeriodController.new,
    );

/// The twelve periods up to and including the selected one.
///
/// Bounded by construction, matching the producer portal's own selector so the
/// two never offer different ranges for the same question.
final oversightPeriodOptionsProvider = Provider.autoDispose<List<String>>((ref) {
  final selected = ref.watch(oversightPeriodProvider);
  return periodsEndingAt(selected, count: 12).reversed.toList(growable: false);
});

// ---------------------------------------------------------------------------
// The anomaly queue (EPR-45)
// ---------------------------------------------------------------------------

/// Which status the queue is showing.
class AnomalyFilterController extends Notifier<String> {
  @override
  String build() => AnomalyStatus.open;

  void select(String status) {
    if (!AnomalyStatus.all.contains(status)) return;
    state = status;
  }
}

final anomalyFilterProvider = NotifierProvider<AnomalyFilterController, String>(
  AnomalyFilterController.new,
);

final anomalyQueueProvider =
    FutureProvider.autoDispose<List<AnomalyFinding>>((ref) {
      final status = ref.watch(anomalyFilterProvider);
      return ref.watch(adminOversightServiceProvider).listAnomalies(status: status);
    });

/// How many findings are open, for the badge on the console's entry card.
///
/// Its own provider rather than `anomalyQueueProvider.length`, because the
/// badge is read on the home screen where the queue itself is not loaded — and
/// watching the full queue there would fetch a list nobody is about to see.
final openAnomalyCountProvider = FutureProvider.autoDispose<int>((ref) async {
  final findings = await ref
      .watch(adminOversightServiceProvider)
      .listAnomalies(status: AnomalyStatus.open);
  return findings.length;
});

// ---------------------------------------------------------------------------
// Reconciliation (EPR-48)
// ---------------------------------------------------------------------------

final reconciliationProvider =
    FutureProvider.autoDispose<ReconciliationOverview>(
      (ref) => ref.watch(adminOversightServiceProvider).loadReconciliation(),
    );

final organizationReconciliationProvider = FutureProvider.autoDispose
    .family<List<ReconciliationRow>, String>(
      (ref, orgId) => ref
          .watch(adminOversightServiceProvider)
          .loadOrganizationReconciliation(orgId),
    );

// ---------------------------------------------------------------------------
// The accuracy audit (EPR-17)
// ---------------------------------------------------------------------------

/// Which sampling reason the review queue is showing.
///
/// The two are genuinely different work. A standing-audit match was attributed
/// automatically and is being checked; a low-confidence match was never
/// attributed and is being rescued. Mixing them in one list would make a
/// reviewer's verdict mean two things.
class AccuracyReasonController extends Notifier<String> {
  @override
  String build() => 'accuracyAudit';

  void select(String reason) {
    if (reason != 'accuracyAudit' && reason != 'lowConfidence') return;
    state = reason;
  }
}

final accuracyReasonProvider =
    NotifierProvider<AccuracyReasonController, String>(
      AccuracyReasonController.new,
    );

final accuracyQueueProvider =
    FutureProvider.autoDispose<List<SampledMatch>>((ref) {
      final reason = ref.watch(accuracyReasonProvider);
      return ref
          .watch(adminOversightServiceProvider)
          .loadAccuracyQueue(reason: reason);
    });

final accuracySnapshotProvider =
    FutureProvider.autoDispose<AccuracySnapshot>((ref) {
      final periodId = ref.watch(oversightPeriodProvider);
      return ref.watch(adminOversightServiceProvider).loadAccuracy(periodId);
    });

// ---------------------------------------------------------------------------
// The issuance register (EPR-47)
// ---------------------------------------------------------------------------

/// The register's status filter. Null shows everything, which is the default —
/// an Admin scoping a fault needs the withdrawn ones too.
class IssuanceFilterController extends Notifier<String?> {
  @override
  String? build() => null;

  void select(String? status) {
    if (status != null && !['issued', 'superseded', 'revoked'].contains(status)) {
      return;
    }
    state = status;
  }
}

final issuanceFilterProvider =
    NotifierProvider<IssuanceFilterController, String?>(
      IssuanceFilterController.new,
    );

final issuanceRegisterProvider =
    FutureProvider.autoDispose<IssuanceRegister>((ref) {
      final status = ref.watch(issuanceFilterProvider);
      return ref.watch(adminOversightServiceProvider).loadIssuance(status: status);
    });

// ---------------------------------------------------------------------------
// The declaration review queue (EPR-43)
// ---------------------------------------------------------------------------

final declarationReviewProvider =
    FutureProvider.autoDispose<List<DeclarationReviewRow>>(
      (ref) => ref.watch(adminOversightServiceProvider).loadDeclarationReview(),
    );

// ---------------------------------------------------------------------------
// One producer (EPR-44, EPR-46)
// ---------------------------------------------------------------------------

/// The read-only producer view.
///
/// Keyed by organisation AND period, so switching the period re-opens the view
/// — which is correct rather than wasteful: EPR-46 requires every view to be
/// recorded, and a cached view of September silently shown while the console
/// says October would be a record of a view that did not happen.
final organizationViewProvider = FutureProvider.autoDispose
    .family<OrganizationViewResult, ({String orgId, String periodId})>(
      (ref, key) => ref
          .watch(adminOversightServiceProvider)
          .viewAsOrganization(orgId: key.orgId, periodId: key.periodId),
    );

/// One producer's chronological history.
///
/// Unverified by default. Walking the hash chain is a whole-collection read,
/// and a screen refreshing a list should not pay for it — the verify action is
/// explicit, and its result says whether the chain is KEYED as well as whether
/// it is intact.
final organizationTimelineProvider =
    FutureProvider.autoDispose.family<ActivityTimeline, String>(
      (ref, orgId) =>
          ref.watch(adminOversightServiceProvider).loadTimeline(orgId: orgId),
    );

final verifiedTimelineProvider =
    FutureProvider.autoDispose.family<ActivityTimeline, String>(
      (ref, orgId) => ref
          .watch(adminOversightServiceProvider)
          .loadTimeline(orgId: orgId, verify: true),
    );

/// Refreshes everything a write could have changed.
///
/// One function rather than a scatter of `ref.invalidate` calls at each call
/// site, because the surfaces overlap: superseding a certificate changes the
/// issuance register AND the producer's timeline, and closing an anomaly
/// changes the queue AND the badge on the home card. A caller that invalidated
/// only what it obviously touched would leave a stale count on a screen the
/// Admin walks back to.
/// Takes a [WidgetRef] rather than a [Ref] because every caller is a widget
/// reacting to a button press. The two are different types in Riverpod and
/// only one of them exists inside a `build`.
void invalidateOversight(WidgetRef ref) {
  ref.invalidate(anomalyQueueProvider);
  ref.invalidate(openAnomalyCountProvider);
  ref.invalidate(reconciliationProvider);
  ref.invalidate(accuracyQueueProvider);
  ref.invalidate(accuracySnapshotProvider);
  ref.invalidate(issuanceRegisterProvider);
  ref.invalidate(declarationReviewProvider);
}
