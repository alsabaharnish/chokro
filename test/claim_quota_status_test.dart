import 'package:chokro/services/claim_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// The body `GET /claims/quota` actually returns.
///
/// Copied from `claimQuotaStatus()` in `server/src/claims.js`, spread into
/// `{ ok: true, ... }` by the route in `server/src/index.js`. The count key is
/// `used`; there is no `approvedThisWeek` on the wire and there never was.
Map<String, dynamic> serverQuotaBody({
  String weekKey = '2026-W35',
  int used = 3,
  int limit = 3,
  int claimAward = 15,
}) => <String, dynamic>{
  'ok': true,
  'weekKey': weekKey,
  'used': used,
  'limit': limit,
  'remaining': limit - used < 0 ? 0 : limit - used,
  'claimAward': claimAward,
};

void main() {
  group('ClaimQuotaStatus.fromJson', () {
    test('reads the count from the server key, not a key it never sends', () {
      final status = ClaimQuotaStatus.fromJson(serverQuotaBody(used: 2));

      expect(status.weekKey, '2026-W35');
      expect(status.approvedThisWeek, 2);
      expect(status.limit, 3);
      expect(status.remaining, 1);
      expect(status.isExhausted, isFalse);
    });

    test('an exhausted week reads as exhausted (F6.4)', () {
      // The regression this pins: the count was read from `approvedThisWeek`,
      // a key the server has never sent, so it fell back to zero and a
      // Champion who had used all three claims was told they had three left —
      // then found out at review time, after photographing the evidence.
      final status = ClaimQuotaStatus.fromJson(serverQuotaBody(used: 3));

      expect(status.approvedThisWeek, 3);
      expect(status.remaining, 0);
      expect(status.isExhausted, isTrue);
      expect(status.summary, 'You have used all 3 claims for this week.');
    });

    test('a fresh week reads as a full allowance', () {
      final status = ClaimQuotaStatus.fromJson(serverQuotaBody(used: 0));

      expect(status.remaining, 3);
      expect(status.summary, '3 claims left this week.');
    });

    test('one left is worded in the singular', () {
      final status = ClaimQuotaStatus.fromJson(serverQuotaBody(used: 2));

      expect(status.summary, '1 claim left this week.');
    });

    test('a counter above the limit cannot report negative headroom', () {
      // Reachable if an administrator lowers `claimQuotaPerWeek` mid-week.
      final status = ClaimQuotaStatus.fromJson(
        serverQuotaBody(used: 5, limit: 3),
      );

      expect(status.remaining, 0);
      expect(status.isExhausted, isTrue);
    });

    test('a damaged body degrades to a safe default rather than throwing', () {
      final status = ClaimQuotaStatus.fromJson(<String, dynamic>{
        'weekKey': 7,
        'used': 'three',
        'limit': null,
      });

      expect(status.weekKey, '');
      expect(status.approvedThisWeek, 0);
      expect(status.limit, 3);
    });
  });
}
