import 'package:chokro/core/points_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure Dart tests — no Firebase, no emulator, no widgets. Run with:
///   flutter test test/core/points_policy_test.dart
void main() {
  const policy = PointsPolicy.defaults;

  group('defaults match §7.3', () {
    test('baseline values are as briefed', () {
      expect(policy.disposalAward, 50);
      expect(policy.claimAward, 15);
      expect(policy.claimQuotaPerWeek, 3);
      expect(policy.purchaseAwardPercent, 5);
      expect(policy.redemptionPointsPerBlock, 100);
      expect(policy.redemptionTakaPerBlock, 10);
      expect(policy.maxRedemptionPercentOfSubtotal, 50);
      expect(policy.lockoutHours, 6);
      expect(policy.dailyDisposalCap, 3);
    });

    test('the defaults are internally consistent', () {
      expect(policy.validate(), isEmpty);
      expect(policy.isValid, isTrue);
    });

    test('100 points buys 10 taka, so one disposal is worth 5 taka', () {
      expect(policy.pointsPerTaka, 10);
      expect(policy.takaForPoints(100), 10);
      expect(policy.takaForPoints(policy.disposalAward), 5);
    });
  });

  group('validation', () {
    test('rejects a claim award that meets or beats the disposal award', () {
      // The load-bearing invariant: award value tracks verification strength.
      final equal = policy.copyWith(claimAward: 50);
      final greater = policy.copyWith(claimAward: 80);

      expect(equal.validate(), isNotEmpty);
      expect(greater.validate(), isNotEmpty);
      expect(
        greater.validate().single,
        contains('must pay less'),
      );
    });

    test('rejects non-positive awards and windows', () {
      expect(policy.copyWith(disposalAward: 0).validate(), isNotEmpty);
      expect(policy.copyWith(lockoutHours: 0).validate(), isNotEmpty);
      expect(policy.copyWith(dailyDisposalCap: -1).validate(), isNotEmpty);
    });

    test('rejects out-of-range percentages', () {
      expect(policy.copyWith(purchaseAwardPercent: 101).validate(), isNotEmpty);
      expect(
        policy.copyWith(maxRedemptionPercentOfSubtotal: 120).validate(),
        isNotEmpty,
      );
    });

    test('rejects a lockout window longer than a week', () {
      expect(policy.copyWith(lockoutHours: 200).validate(), isNotEmpty);
    });

    test('accepts a plausible admin adjustment', () {
      // Arnish said he may raise the redemption rate later; that must pass.
      final adjusted = policy.copyWith(redemptionTakaPerBlock: 20);
      expect(adjusted.validate(), isEmpty);
      expect(adjusted.pointsPerTaka, 5);
      expect(adjusted.takaForPoints(50), 10);
    });
  });

  group('redemption cap', () {
    test('caps at 50% of subtotal even with a large balance', () {
      final cap = policy.maxRedeemablePoints(subtotal: 200, balance: 100000);
      expect(cap, 1000); // 1000 points = ৳100 = half of ৳200
      expect(policy.takaForPoints(cap), 100);
    });

    test('caps at the wallet balance when that is the tighter bound', () {
      final cap = policy.maxRedeemablePoints(subtotal: 500, balance: 250);
      expect(cap, 250);
    });

    test('rounds down to a whole-taka block', () {
      // 257 points is ৳25.7 — the stray 7 points are not spendable.
      final cap = policy.maxRedeemablePoints(subtotal: 500, balance: 257);
      expect(cap, 250);
      expect(cap % policy.pointsPerTaka, 0);
    });

    test('returns zero when the subtotal is too small to discount', () {
      expect(policy.maxRedeemablePoints(subtotal: 1, balance: 500), 0);
      expect(policy.maxRedeemablePoints(subtotal: 0, balance: 500), 0);
    });

    test('returns zero for an empty or negative wallet', () {
      expect(policy.maxRedeemablePoints(subtotal: 500, balance: 0), 0);
      expect(policy.maxRedeemablePoints(subtotal: 500, balance: -50), 0);
    });
  });

  group('applying redemption', () {
    test('splits an order into discount and payable', () {
      final outcome = policy.applyRedemption(
        subtotal: 200,
        balance: 1000,
        pointsRequested: 500,
      );
      expect(outcome.pointsApplied, 500);
      expect(outcome.discount, 50);
      expect(outcome.payable, 150);
    });

    test('clamps an over-request to the cap rather than throwing', () {
      final outcome = policy.applyRedemption(
        subtotal: 200,
        balance: 100000,
        pointsRequested: 99999,
      );
      expect(outcome.pointsApplied, 1000);
      expect(outcome.payable, 100);
    });

    test('ignores a negative request', () {
      final outcome = policy.applyRedemption(
        subtotal: 200,
        balance: 1000,
        pointsRequested: -400,
      );
      expect(outcome.pointsApplied, 0);
      expect(outcome.payable, 200);
    });

    test('never lets points cover the whole order', () {
      final outcome = policy.applyRedemption(
        subtotal: 300,
        balance: 100000,
        pointsRequested: 100000,
      );
      expect(outcome.payable, greaterThan(0));
      expect(outcome.payable, 150);
    });

    test('discount and payable always reconcile to the subtotal', () {
      for (final subtotal in [1, 7, 99, 100, 333, 1000, 12345]) {
        final outcome = policy.applyRedemption(
          subtotal: subtotal,
          balance: 5000,
          pointsRequested: 5000,
        );
        expect(outcome.discount + outcome.payable, subtotal,
            reason: 'failed at subtotal $subtotal');
        expect(outcome.pointsApplied, policy.pointsToSpendForTaka(outcome.discount));
      }
    });
  });

  group('purchase award', () {
    test('is 5% of payable, rounded down', () {
      expect(policy.purchaseAward(100), 5);
      expect(policy.purchaseAward(199), 9);
      expect(policy.purchaseAward(1000), 50);
    });

    test('is zero for trivial or non-positive amounts', () {
      expect(policy.purchaseAward(19), 0);
      expect(policy.purchaseAward(0), 0);
      expect(policy.purchaseAward(-100), 0);
    });

    test('buying is never a better earn route than disposing', () {
      // A ৳1000 order earns 50 points — the same as one disposal, which takes
      // no money at all. Anything cheaper earns strictly less.
      expect(policy.purchaseAward(999), lessThan(policy.disposalAward));
    });
  });

  group('lockout window', () {
    final opened = DateTime.utc(2026, 7, 31, 8, 0);

    test('expires exactly six hours after it opens', () {
      expect(policy.lockoutExpiry(opened), DateTime.utc(2026, 7, 31, 14, 0));
    });

    test('is in force right up to the expiry instant', () {
      final expires = policy.lockoutExpiry(opened);
      expect(
        policy.isLockedOut(
          expiresAt: expires,
          now: DateTime.utc(2026, 7, 31, 13, 59, 59),
        ),
        isTrue,
      );
    });

    test('is released at and after the expiry instant', () {
      final expires = policy.lockoutExpiry(opened);
      expect(policy.isLockedOut(expiresAt: expires, now: expires), isFalse);
      expect(
        policy.isLockedOut(
          expiresAt: expires,
          now: DateTime.utc(2026, 7, 31, 14, 0, 1),
        ),
        isFalse,
      );
    });

    test('a missing lockout document means not locked out', () {
      expect(
        policy.isLockedOut(expiresAt: null, now: DateTime.utc(2026, 7, 31)),
        isFalse,
      );
    });

    test('crosses a day boundary correctly', () {
      final late = DateTime.utc(2026, 7, 31, 23, 0);
      expect(policy.lockoutExpiry(late), DateTime.utc(2026, 8, 1, 5, 0));
    });
  });

  group('caps and quotas', () {
    test('allows disposals up to the daily cap and no further', () {
      expect(policy.canApproveAnotherDisposalToday(0), isTrue);
      expect(policy.canApproveAnotherDisposalToday(2), isTrue);
      expect(policy.canApproveAnotherDisposalToday(3), isFalse);
      expect(policy.canApproveAnotherDisposalToday(4), isFalse);
    });

    test('refuses a fourth claim in the same week', () {
      expect(policy.canApproveAnotherClaimThisWeek(2), isTrue);
      expect(policy.canApproveAnotherClaimThisWeek(3), isFalse);
    });

    test('the daily disposal cap bounds the strongest earn route', () {
      expect(policy.dailyDisposalCap * policy.disposalAward, 150);
    });
  });

  group('ISO week keys', () {
    test('produces a zero-padded sortable key', () {
      expect(IsoWeek.key(DateTime.utc(2026, 7, 31)), '2026-W31');
      expect(IsoWeek.key(DateTime.utc(2026, 1, 1)), '2026-W01');
    });

    test('every day of one week maps to the same key', () {
      // Mon 27 July 2026 through Sun 2 August 2026.
      final keys = <String>{};
      for (var day = 27; day <= 31; day++) {
        keys.add(IsoWeek.key(DateTime.utc(2026, 7, day)));
      }
      keys.add(IsoWeek.key(DateTime.utc(2026, 8, 1)));
      keys.add(IsoWeek.key(DateTime.utc(2026, 8, 2)));
      expect(keys, {'2026-W31'});
    });

    test('a new week starts on Monday, not Sunday', () {
      expect(IsoWeek.key(DateTime.utc(2026, 8, 2)), '2026-W31'); // Sunday
      expect(IsoWeek.key(DateTime.utc(2026, 8, 3)), '2026-W32'); // Monday
    });

    test('early January can belong to the previous ISO year', () {
      // 1 Jan 2027 is a Friday, so it falls in the last ISO week of 2026.
      expect(IsoWeek.key(DateTime.utc(2027, 1, 1)), '2026-W53');
      expect(IsoWeek.weekYear(DateTime.utc(2027, 1, 1)), 2026);
    });

    test('late December can belong to the next ISO year', () {
      expect(IsoWeek.key(DateTime.utc(2024, 12, 30)), '2025-W01');
      expect(IsoWeek.key(DateTime.utc(2025, 12, 29)), '2026-W01');
    });

    test('time of day does not affect the key', () {
      expect(
        IsoWeek.key(DateTime.utc(2026, 7, 31, 23, 59)),
        IsoWeek.key(DateTime.utc(2026, 7, 31, 0, 1)),
      );
    });

    test('builds the quota document id', () {
      expect(
        IsoWeek.quotaDocId('abc123', DateTime.utc(2026, 7, 31)),
        'abc123_2026-W31',
      );
    });
  });

  group('config serialization', () {
    test('round-trips through JSON', () {
      final custom = policy.copyWith(disposalAward: 40, lockoutHours: 12);
      expect(PointsPolicy.fromJson(custom.toJson()), custom);
    });

    test('falls back to defaults when the document is missing', () {
      expect(PointsPolicy.fromJson(null), PointsPolicy.defaults);
      expect(PointsPolicy.fromJson(<String, dynamic>{}), PointsPolicy.defaults);
    });

    test('falls back per-field on partial or malformed data', () {
      final parsed = PointsPolicy.fromJson(<String, dynamic>{
        'disposalAward': 40,
        'claimAward': 'not a number',
        'lockoutHours': null,
      });
      expect(parsed.disposalAward, 40);
      expect(parsed.claimAward, PointsPolicyDefaults.claimAward);
      expect(parsed.lockoutHours, PointsPolicyDefaults.lockoutHours);
    });

    test('accepts a numeric field stored as a double', () {
      // Firestore number fields can come back as double.
      final parsed = PointsPolicy.fromJson(<String, dynamic>{
        'disposalAward': 40.0,
      });
      expect(parsed.disposalAward, 40);
    });

    test('reads tolerantly but does not silently fix an invalid policy', () {
      // A config document that breaks the verification-strength invariant parses
      // fine — validate() is what catches it, and the server must call it.
      final parsed = PointsPolicy.fromJson(<String, dynamic>{'claimAward': 90});
      expect(parsed.claimAward, 90);
      expect(parsed.validate(), isNotEmpty);
    });
  });
}
