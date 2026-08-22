import 'package:chokro/models/stats_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('a database with no stats document', () {
    test('reads as zeros rather than failing', () {
      final stats = PlatformStats.fromMap(null);

      expect(stats.disposalsApproved, 0);
      expect(stats.pointsIssued, 0);
      expect(stats.ordersCreated, 0);
    });

    test('reports no approval rate at all, which is not zero percent', () {
      final stats = PlatformStats.fromMap(null);

      expect(stats.disposalApprovalPercent, isNull);
      expect(stats.claimApprovalPercent, isNull);
    });
  });

  group('derived figures', () {
    const stats = PlatformStats(
      disposalsApproved: 8,
      disposalsRejected: 2,
      claimsApproved: 3,
      claimsRejected: 1,
      pointsIssued: 500,
      pointsRedeemed: 120,
      pointsDonated: 50,
      donationsReceived: 2,
      ordersCreated: 5,
      ordersConfirmed: 2,
    );

    test('outstanding points are issued minus redeemed and donated', () {
      expect(stats.pointsOutstanding, 330);
    });

    test('approval rates are whole percentages of decided items', () {
      expect(stats.disposalApprovalPercent, 80);
      expect(stats.claimApprovalPercent, 75);
    });

    test('open orders are those placed but not yet confirmed', () {
      expect(stats.ordersOpen, 3);
    });

    test('open orders never go negative on inconsistent counters', () {
      const skewed = PlatformStats(ordersCreated: 1, ordersConfirmed: 4);
      expect(skewed.ordersOpen, 0);
    });
  });

  test('tolerates counters stored as doubles', () {
    final stats = PlatformStats.fromMap({'pointsIssued': 500.0});
    expect(stats.pointsIssued, 500);
  });

  test('reads donation counters', () {
    final stats = PlatformStats.fromMap({
      'pointsDonated': 250,
      'donationsReceived': 3,
    });
    expect(stats.pointsDonated, 250);
    expect(stats.donationsReceived, 3);
  });

  test('does not silently truncate a fractional counter', () {
    final stats = PlatformStats.fromMap({'pointsIssued': 500.5});
    expect(stats.pointsIssued, 0);
  });

  test('ignores a counter stored with a nonsense type', () {
    final stats = PlatformStats.fromMap({'pointsIssued': 'lots'});
    expect(stats.pointsIssued, 0);
  });
}
