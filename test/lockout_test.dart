import 'package:chokro/core/label_format.dart';
import 'package:chokro/services/lockout_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Duplicate-submission lockout, the client's read of it (F2.6).
///
/// The window itself is enforced by `firestore.rules`; these cover the two
/// things the app has to get right to describe it honestly — the document ID it
/// looks under, and the countdown it prints.

void main() {
  group('lockoutId', () {
    test('matches the id the server writes', () {
      // `server/src/award.js` composes `${uid}_${disposal.binId}` and the rules
      // read `$(uid + '_' + binId)`. Three places, one format: if this drifts,
      // the client reads a document that does not exist and cheerfully reports
      // no lockout, while the write is still refused.
      expect(
        LockoutService.lockoutId(uid: 'user123', binId: 'binABC'),
        'user123_binABC',
      );
    });

    test('is stable for the same pair', () {
      expect(
        LockoutService.lockoutId(uid: 'u', binId: 'b'),
        LockoutService.lockoutId(uid: 'u', binId: 'b'),
      );
    });

    test('distinguishes users at the same bin', () {
      // The window is per user per bin, not per bin. Two people may use the same
      // bin in the same hour.
      expect(
        LockoutService.lockoutId(uid: 'alice', binId: 'bin1'),
        isNot(LockoutService.lockoutId(uid: 'bob', binId: 'bin1')),
      );
    });

    test('distinguishes bins for the same user', () {
      expect(
        LockoutService.lockoutId(uid: 'alice', binId: 'bin1'),
        isNot(LockoutService.lockoutId(uid: 'alice', binId: 'bin2')),
      );
    });
  });

  group('formatCountdown', () {
    final now = DateTime(2026, 8, 18, 12, 0);

    test('hours and minutes', () {
      expect(
        formatCountdown(now.add(const Duration(hours: 4, minutes: 12)), now: now),
        '4h 12m',
      );
    });

    test('whole hours drop the minutes', () {
      expect(
        formatCountdown(now.add(const Duration(hours: 6)), now: now),
        '6h',
      );
    });

    test('under an hour shows minutes only', () {
      expect(
        formatCountdown(now.add(const Duration(minutes: 42)), now: now),
        '42m',
      );
    });

    test('rounds down rather than up', () {
      // Telling someone 5m when 4m 59s remain invites them to come back and be
      // refused again.
      expect(
        formatCountdown(
          now.add(const Duration(minutes: 4, seconds: 59)),
          now: now,
        ),
        '4m',
      );
    });

    test('the last minute reads as under a minute', () {
      expect(
        formatCountdown(now.add(const Duration(seconds: 30)), now: now),
        'under a minute',
      );
    });

    test('an elapsed window never reads as negative', () {
      // The document outlives its expiry — nothing deletes it, because there is
      // no scheduler in this system. A lapsed window must not print "-3h".
      expect(
        formatCountdown(now.subtract(const Duration(hours: 3)), now: now),
        'under a minute',
      );
    });

    test('null is empty, not the word null', () {
      expect(formatCountdown(null, now: now), '');
    });

    test('the default six-hour window reads sensibly', () {
      // `PointsPolicyDefaults.lockoutHours` is 6.
      expect(
        formatCountdown(now.add(const Duration(hours: 6)), now: now),
        '6h',
      );
      expect(
        formatCountdown(
          now.add(const Duration(hours: 5, minutes: 59)),
          now: now,
        ),
        '5h 59m',
      );
    });
  });
}
