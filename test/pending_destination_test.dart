import 'package:chokro/routing/router.dart';
import 'package:flutter_test/flutter_test.dart';

/// The destination the auth gate defers (F7.1 deep links, admin deep links).
///
/// The gate has to send an unresolved or anonymous visitor to the splash or the
/// sign-in screen, and that destination used to replace the requested one
/// permanently — `return '/home'` was hardcoded on the signed-in branch. Two
/// paths lost: an administrator cold-opening `/admin/bins`, and a push tap from a
/// terminated state, which is the notification path most worth demonstrating.

void main() {
  group('PendingDestination', () {
    test('nothing is remembered by default', () {
      expect(PendingDestination().consume(), isNull);
    });

    test('a remembered path is returned', () {
      final pending = PendingDestination()..remember('/admin/bins');
      expect(pending.consume(), '/admin/bins');
    });

    test('consuming clears it', () {
      // Cleared on read so a later sign-out and sign-in as somebody else cannot
      // teleport the new session to a screen the previous one asked for.
      final pending = PendingDestination()..remember('/admin/users');

      expect(pending.consume(), '/admin/users');
      expect(pending.consume(), isNull);
    });

    test('the newest intention wins', () {
      // Someone taps a notification while sitting on the splash. That is a more
      // recent expression of where they want to be than the cold-start path.
      final pending = PendingDestination()
        ..remember('/admin/bins')
        ..remember('/history');

      expect(pending.consume(), '/history');
    });

    test('a path can be remembered again after being consumed', () {
      final pending = PendingDestination()..remember('/wallet');
      expect(pending.consume(), '/wallet');

      pending.remember('/history');
      expect(pending.consume(), '/history');
    });

    test('it holds a path, not a decision', () {
      // Worth stating: this class grants nothing. `redirect` returns the value as
      // a *location*, so GoRouter re-matches it and re-runs the target route's own
      // redirect — `requireAdmin` still refuses a buyer who somehow arrives with
      // an admin path remembered. Restoring an intention is not authorising it.
      final pending = PendingDestination()..remember('/admin/users');
      expect(pending.consume(), '/admin/users');
    });
  });
}
