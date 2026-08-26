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
      expect(
        status.summary,
        'All 3 approved eco-actions for this week are used. '
        'The count resets on Monday.',
      );
    });

    test('a fresh week reads as a full allowance', () {
      final status = ClaimQuotaStatus.fromJson(serverQuotaBody(used: 0));

      expect(status.remaining, 3);
      expect(status.summary, '3 more eco-actions can be approved this week.');
    });

    test('one left is worded in the singular', () {
      final status = ClaimQuotaStatus.fromJson(serverQuotaBody(used: 2));

      expect(status.summary, '1 more eco-action can be approved this week.');
    });

    test('the summary says the count is over approvals, not submissions', () {
      // The wording is the whole point of this one. "3 claims left this week"
      // on a submission form reads as a submission budget, so a Champion
      // submitted five, was told each was under review, and collected two
      // rejections they had no way to anticipate. The counter is incremented
      // in `approveClaim`, never on create.
      final fresh = ClaimQuotaStatus.fromJson(serverQuotaBody(used: 0));
      final spent = ClaimQuotaStatus.fromJson(serverQuotaBody(used: 3));

      for (final summary in [fresh.summary, spent.summary]) {
        expect(
          summary.toLowerCase(),
          contains('approved'),
          reason: 'the number counts approvals and must say so',
        );
      }
      expect(spent.summary, contains('resets on Monday'));
    });

    test('carries the per-claim award the server already sends', () {
      // Parsed away before this, so the submission form asked the user to
      // photograph and describe an eco-action without ever saying what one is
      // worth — the figure only appeared after approval, days later.
      final status = ClaimQuotaStatus.fromJson(serverQuotaBody(claimAward: 15));

      expect(status.claimAward, 15);
    });

    test('a missing award falls back to zero rather than throwing', () {
      final body = serverQuotaBody()..remove('claimAward');

      expect(ClaimQuotaStatus.fromJson(body).claimAward, 0);
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
