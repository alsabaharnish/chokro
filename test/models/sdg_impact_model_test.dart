import 'package:chokro/models/sdg_impact_model.dart';
import 'package:chokro/models/stats_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('derives only supported activity signals from platform counters', () {
    const stats = PlatformStats(
      disposalsApproved: 12,
      claimsApproved: 5,
      ordersCreated: 7,
      salesPayable: 18500,
      donationsReceived: 3,
      pointsDonated: 450,
    );

    final impact = SdgImpactSnapshot.fromPlatform(
      stats: stats,
      greenpreneurProfiles: 4,
      greenpreneurCountIsFloor: true,
    );

    expect(impact.approvedDisposalSubmissions, 12);
    expect(impact.approvedEcoActions, 5);
    expect(impact.approvedEnvironmentalActivityRecords, 17);
    expect(impact.marketplaceOrders, 7);
    expect(impact.marketplaceOrderValueTaka, 18500);
    expect(impact.greenpreneurProfiles, 4);
    expect(impact.greenpreneurCountIsFloor, isTrue);
    expect(impact.initiativeContributions, 3);
    expect(impact.initiativePoints, 450);
    expect(impact.hasRecordedActivity, isTrue);
  });

  test('a profile capability alone is not environmental activity', () {
    final impact = SdgImpactSnapshot.fromPlatform(
      stats: PlatformStats.empty,
      // The bootstrap Admin inherits this profile even before the platform has
      // recorded a disposal, claim, order, or contribution.
      greenpreneurProfiles: 1,
    );

    expect(impact.greenpreneurProfiles, 1);
    expect(impact.hasRecordedActivity, isFalse);
  });
}
