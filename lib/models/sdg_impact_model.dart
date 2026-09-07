import 'stats_model.dart';

/// A conservative SDG-alignment snapshot derived from Chokro's existing
/// platform counters.
///
/// These are activity signals, not official UN indicators and not claims of
/// environmental outcomes. In particular, Chokro does not yet store verified
/// material weight, avoided emissions, jobs created, or a reporting baseline.
/// Keeping the derivation in a plain Dart model makes that boundary explicit
/// and testable instead of scattering impact arithmetic through the view.
class SdgImpactSnapshot {
  const SdgImpactSnapshot({
    required this.approvedDisposalSubmissions,
    required this.approvedEcoActions,
    required this.marketplaceOrders,
    required this.marketplaceOrderValueTaka,
    required this.greenpreneurProfiles,
    required this.greenpreneurCountIsFloor,
    required this.initiativeContributions,
    required this.initiativePoints,
  });

  factory SdgImpactSnapshot.fromPlatform({
    required PlatformStats stats,
    required int greenpreneurProfiles,
    bool greenpreneurCountIsFloor = false,
  }) {
    return SdgImpactSnapshot(
      approvedDisposalSubmissions: stats.disposalsApproved,
      approvedEcoActions: stats.claimsApproved,
      marketplaceOrders: stats.ordersCreated,
      marketplaceOrderValueTaka: stats.salesPayable,
      greenpreneurProfiles: greenpreneurProfiles,
      greenpreneurCountIsFloor: greenpreneurCountIsFloor,
      initiativeContributions: stats.donationsReceived,
      initiativePoints: stats.pointsDonated,
    );
  }

  final int approvedDisposalSubmissions;
  final int approvedEcoActions;
  final int marketplaceOrders;
  final int marketplaceOrderValueTaka;
  final int greenpreneurProfiles;

  /// True when the account directory hit its read cap, so the visible profile
  /// count is a lower bound rather than an exact total.
  final bool greenpreneurCountIsFloor;

  final int initiativeContributions;
  final int initiativePoints;

  /// Approved disposal and eco-action records are separate event types, so they
  /// may be combined without counting the same record twice.
  int get approvedEnvironmentalActivityRecords =>
      approvedDisposalSubmissions + approvedEcoActions;

  bool get hasRecordedActivity =>
      approvedEnvironmentalActivityRecords > 0 ||
      marketplaceOrders > 0 ||
      marketplaceOrderValueTaka > 0 ||
      initiativeContributions > 0 ||
      initiativePoints > 0;
}
