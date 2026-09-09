import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/producer_sku_model.dart';
import '../services/producer_sku_service.dart';
import 'producer_workspace_controller.dart';

/// Shared by the producer registry and the Admin mass queue. Holds an
/// `http.Client` and a `FirebaseAuth` reference and nothing else.
final producerSkuServiceProvider = Provider<ProducerSkuService>(
  (ref) => ProducerSkuService(),
);

/// One organisation's product registry (EPR-9).
///
/// Depends on the workspace, so a member whose access was removed sees the
/// workspace's own explanation rather than an empty catalogue with no reason.
final skuCatalogueProvider = FutureProvider.autoDispose<SkuCatalogue>((
  ref,
) async {
  final workspace = await ref.watch(producerWorkspaceProvider.future);
  if (!workspace.isReady) {
    return const SkuCatalogue(skus: <ProducerSkuModel>[]);
  }
  return ref.watch(producerSkuServiceProvider).listSkus();
});

/// One product's revision history and the weighings behind it (EPR-12).
final skuHistoryProvider = FutureProvider.autoDispose.family<SkuHistory, String>(
  (ref, skuId) => ref.watch(producerSkuServiceProvider).loadHistory(skuId),
);

/// The Admin mass-verification queue (EPR-42).
///
/// "The single most consequential screen in the system: it is where a number
/// that will appear on regulatory filings is accepted or refused."
final massQueueProvider = FutureProvider.autoDispose<MassQueue>(
  (ref) => ref.watch(producerSkuServiceProvider).loadMassQueue(),
);

final adminSkuHistoryProvider = FutureProvider.autoDispose
    .family<SkuHistory, String>(
      (ref, skuId) =>
          ref.watch(producerSkuServiceProvider).loadHistory(skuId, asAdmin: true),
    );

/// A producer's actions on its own registry. Every one is a server call (SEC-4).
class SkuActions {
  const SkuActions(this._ref);

  final Ref _ref;

  ProducerSkuService get _service => _ref.read(producerSkuServiceProvider);

  Future<String> save(ProducerSkuModel sku) async {
    final id = await _service.saveDraft(sku);
    _refresh();
    return id;
  }

  Future<int> import(List<ProducerSkuModel> drafts) async {
    final created = await _service.importDrafts(drafts);
    _refresh();
    return created;
  }

  Future<void> submit(String skuId) async {
    await _service.submitForVerification(skuId);
    _refresh();
    _ref.invalidate(skuHistoryProvider(skuId));
  }

  /// The catalogue and the activity trail: every one of these actions is also
  /// an audit entry, and the trail is a click away.
  void _refresh() {
    _ref.invalidate(skuCatalogueProvider);
    _ref.invalidate(orgActivityProvider);
  }
}

final skuActionsProvider = Provider<SkuActions>(SkuActions.new);

/// Chokro's actions on a submitted declaration.
class MassVerificationActions {
  const MassVerificationActions(this._ref);

  final Ref _ref;

  ProducerSkuService get _service => _ref.read(producerSkuServiceProvider);

  Future<MassAuditOutcome> recordAudit({
    required String skuId,
    required int sampleSize,
    required int measuredMeanMg,
    int? measuredStdDevMg,
    String? weighingLocation,
    String? scalePhotoUrl,
    String? note,
  }) async {
    final outcome = await _service.recordAudit(
      skuId: skuId,
      sampleSize: sampleSize,
      measuredMeanMg: measuredMeanMg,
      measuredStdDevMg: measuredStdDevMg,
      weighingLocation: weighingLocation,
      scalePhotoUrl: scalePhotoUrl,
      note: note,
    );
    _refresh(skuId);
    return outcome;
  }

  Future<void> setVerifiedMass({
    required String skuId,
    required int verifiedUnitMassMg,
    required String reason,
    required String note,
  }) async {
    await _service.setVerifiedMass(
      skuId: skuId,
      verifiedUnitMassMg: verifiedUnitMassMg,
      reason: reason,
      note: note,
    );
    _refresh(skuId);
  }

  Future<void> reject({required String skuId, required String reason}) async {
    await _service.rejectSku(skuId: skuId, reason: reason);
    _refresh(skuId);
  }

  void _refresh(String skuId) {
    _ref.invalidate(massQueueProvider);
    _ref.invalidate(adminSkuHistoryProvider(skuId));
  }
}

final massVerificationActionsProvider = Provider<MassVerificationActions>(
  MassVerificationActions.new,
);
