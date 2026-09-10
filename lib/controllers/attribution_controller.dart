import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/epr_period.dart';
import '../models/epr_period_model.dart';
import '../services/attribution_read_service.dart';
import 'producer_workspace_controller.dart';

final attributionReadServiceProvider = Provider<AttributionReadService>(
  (ref) => AttributionReadService(),
);

/// This organisation's period history, newest first (EPR-22).
final producerPeriodsProvider =
    FutureProvider.autoDispose<List<EprPeriodModel>>((ref) async {
      final workspace = await ref.watch(producerWorkspaceProvider.future);
      if (!workspace.isReady) return const <EprPeriodModel>[];
      return ref.watch(attributionReadServiceProvider).listPeriods();
    });

/// The clock the period selector starts from.
///
/// Overridden in tests, so "which month does the workspace open on" is a
/// question with a fixed answer rather than one that changes at midnight Dhaka
/// time while a test is running.
final periodClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// The period the workspace is currently showing.
///
/// Defaults to the current Asia/Dhaka month. Resolved on the client only for
/// *selection*: every stored `periodId` is derived on the server from its own
/// clock (EPR-23), so this never decides which period a figure belongs to — it
/// decides which one to ask for.
class SelectedPeriodController extends Notifier<String> {
  @override
  String build() => periodIdFor(ref.read(periodClockProvider)());

  /// Refuses a malformed period rather than querying with it. A bad period
  /// returns an empty rollup, which a screen renders as a month with no
  /// activity — indistinguishable from a real quiet month.
  void select(String periodId) {
    if (!isValidPeriodId(periodId)) return;
    state = periodId;
  }
}

final selectedPeriodProvider =
    NotifierProvider<SelectedPeriodController, String>(
      SelectedPeriodController.new,
    );

/// The selected period's rollup.
final selectedPeriodDataProvider = FutureProvider.autoDispose<EprPeriodModel>((
  ref,
) async {
  final workspace = await ref.watch(producerWorkspaceProvider.future);
  final periodId = ref.watch(selectedPeriodProvider);

  if (!workspace.isReady) {
    return EprPeriodModel.empty(
      orgId: workspace.organization?.id ?? '',
      periodId: periodId,
    );
  }

  return ref.watch(attributionReadServiceProvider).loadPeriod(periodId);
});

/// The twelve months up to and including the selected one.
///
/// Bounded by construction, so a trend cannot become an unbounded read
/// (QA-10). Twelve because that is the span a producer's annual report covers.
final periodOptionsProvider = Provider.autoDispose<List<String>>((ref) {
  final selected = ref.watch(selectedPeriodProvider);
  return periodsEndingAt(selected, count: 12).reversed.toList(growable: false);
});
