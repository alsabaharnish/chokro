import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/organization_model.dart';
import '../models/producer_audit_model.dart';
import '../services/organization_service.dart';
import 'producer_workspace_controller.dart';

/// The Admin producer directory (EPR-40).
///
/// Bounded on the server at [QueryLimits.producerDirectory]; an obligated
/// producer register is a few hundred large industries, not a consumer
/// collection.
final adminProducersProvider =
    FutureProvider.autoDispose<List<OrganizationModel>>(
      (ref) => ref.watch(organizationServiceProvider).listOrganizations(),
    );

/// One organisation, with the two things a review decision needs beside it:
/// brand collisions (EPR-14) and the current member list.
final adminProducerDetailProvider = FutureProvider.autoDispose
    .family<OrganizationDetail, String>(
      (ref, orgId) =>
          ref.watch(organizationServiceProvider).loadOrganization(orgId),
    );

/// One organisation's activity timeline, read through the Admin route.
///
/// A different endpoint from the producer's own view of the same log, and
/// deliberately: EPR-46 requires the audit trail to distinguish a Chokro
/// employee reading a company's history from that company reading it.
final adminProducerActivityProvider = FutureProvider.autoDispose
    .family<List<ProducerAuditEntry>, String>(
      (ref, orgId) =>
          ref.watch(organizationServiceProvider).listActivity(orgId: orgId),
    );

/// The audit chain check (SEC-12, EPR-48).
///
/// Not watched by the directory: it walks the whole log, so it runs when an
/// Admin asks for it.
final adminAuditChainProvider = FutureProvider.autoDispose
    .family<AuditChainReport, String>(
      (ref, orgId) =>
          ref.watch(organizationServiceProvider).verifyAuditChain(orgId),
    );

/// The producer directory, grouped the way the queue is actually worked.
///
/// Pending review first and by itself, because that is the list with a clock on
/// it: registration is due within six months of listing, and an application
/// sitting behind forty active companies in one alphabetical list is an
/// application nobody sees.
class ProducerDirectory {
  const ProducerDirectory(this.organizations);

  final List<OrganizationModel> organizations;

  List<OrganizationModel> get awaitingReview =>
      organizations.where((o) => o.isAwaitingReview).toList(growable: false);

  List<OrganizationModel> get active =>
      organizations.where((o) => o.isActive).toList(growable: false);

  List<OrganizationModel> get inactive => organizations
      .where((o) => !o.isActive && !o.isAwaitingReview)
      .toList(growable: false);

  bool get isEmpty => organizations.isEmpty;

  /// Whether the directory may be a prefix of the register rather than all of
  /// it.
  ///
  /// Reported rather than hidden, in the manner of `SellerSalesReport.truncated`:
  /// a count that silently covers the first two hundred of an unknown number is
  /// not a degraded answer but a wrong one, with nothing about it that looks
  /// wrong.
  bool truncatedAt(int cap) => organizations.length >= cap;
}

final producerDirectoryProvider = Provider.autoDispose<
  AsyncValue<ProducerDirectory>
>((ref) {
  return ref
      .watch(adminProducersProvider)
      .whenData(ProducerDirectory.new);
});

/// Admin actions on producer organisations. Every one is a server call (SEC-4).
class AdminProducerActions {
  const AdminProducerActions(this._ref);

  final Ref _ref;

  OrganizationService get _service => _ref.read(organizationServiceProvider);

  Future<void> create(Map<String, dynamic> application) async {
    await _service.createOrganization(application);
    _ref.invalidate(adminProducersProvider);
  }

  Future<void> approve({
    required String orgId,
    required String sizeClass,
    required DateTime obligationStartDate,
    required List<String> categories,
    String? complianceRoute,
    String? bin,
    String? tradeLicenceNo,
    String? doeRegistrationNo,
    String? reason,
  }) async {
    await _service.reviewOrganization(
      orgId: orgId,
      decision: 'approve',
      sizeClass: sizeClass,
      obligationStartDate: obligationStartDate,
      categories: categories,
      complianceRoute: complianceRoute,
      bin: bin,
      tradeLicenceNo: tradeLicenceNo,
      doeRegistrationNo: doeRegistrationNo,
      reason: reason,
    );
    _refresh(orgId);
  }

  Future<void> reject({required String orgId, required String reason}) async {
    await _service.reviewOrganization(
      orgId: orgId,
      decision: 'reject',
      reason: reason,
    );
    _refresh(orgId);
  }

  Future<void> requestInformation({
    required String orgId,
    required String reason,
  }) async {
    await _service.reviewOrganization(
      orgId: orgId,
      decision: 'requestInfo',
      reason: reason,
    );
    _refresh(orgId);
  }

  Future<void> suspend({required String orgId, required String reason}) async {
    await _service.setOrganizationStatus(
      orgId: orgId,
      status: 'suspended',
      reason: reason,
    );
    _refresh(orgId);
  }

  Future<void> reinstate(String orgId) async {
    await _service.setOrganizationStatus(orgId: orgId, status: 'active');
    _refresh(orgId);
  }

  Future<OrgInvitation> inviteOwner({
    required String orgId,
    required String email,
    required String orgRole,
  }) async {
    final invitation = await _service.inviteAsAdmin(
      orgId: orgId,
      email: email,
      orgRole: orgRole,
    );
    _refresh(orgId);
    return invitation;
  }

  /// Records the read-only view before it is opened (EPR-46).
  ///
  /// Throws when the entry could not be written, and the caller must not open
  /// the view in that case. An unrecorded read of a customer's compliance
  /// position is exactly what the trail exists to prevent, so failing to log is
  /// a reason not to look — not a reason to look quietly.
  Future<void> recordView(String orgId) => _service.recordOrganizationView(orgId);

  void _refresh(String orgId) {
    _ref.invalidate(adminProducersProvider);
    _ref.invalidate(adminProducerDetailProvider(orgId));
    _ref.invalidate(adminProducerActivityProvider(orgId));
  }
}

final adminProducerActionsProvider = Provider<AdminProducerActions>(
  AdminProducerActions.new,
);
