import 'package:chokro/models/user_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart half of the lazy-expiry rule (F5.3). The other half is
/// `rules_test/suspension.rules.test.js`, which asserts the same behaviour in
/// `firestore.rules`. These two must agree: the rules enforce, and this decides
/// what the interface tells the user.
void main() {
  final now = DateTime(2026, 8, 1, 12, 0);

  UserModel user({
    String status = 'active',
    DateTime? suspendedUntil,
    String role = 'buyer',
  }) => UserModel(
    uid: 'u1',
    name: 'Test',
    email: 'test@example.com',
    role: role,
    status: status,
    createdAt: DateTime(2026, 1, 1),
    suspendedUntil: suspendedUntil,
  );

  group('isActiveAt', () {
    test('an active account is active', () {
      expect(user().isActiveAt(now), isTrue);
    });

    test('an indefinite suspension is never active', () {
      expect(user(status: 'suspended').isActiveAt(now), isFalse);
    });

    test('a suspension ending in the future is not active', () {
      final u = user(
        status: 'suspended',
        suspendedUntil: now.add(const Duration(hours: 6)),
      );
      expect(u.isActiveAt(now), isFalse);
    });

    test('a suspension whose date has passed is active again', () {
      final u = user(
        status: 'suspended',
        suspendedUntil: now.subtract(const Duration(minutes: 1)),
      );
      expect(u.isActiveAt(now), isTrue);
    });

    test('the boundary instant is still suspended', () {
      // isAfter, not isAtSameMomentOrAfter — matches the rules' strict `<`.
      final u = user(status: 'suspended', suspendedUntil: now);
      expect(u.isActiveAt(now), isFalse);
      expect(u.isActiveAt(now.add(const Duration(seconds: 1))), isTrue);
    });

    test('an unrecognised status is not active — fail closed', () {
      expect(user(status: 'banished').isActiveAt(now), isFalse);
      expect(user(status: '').isActiveAt(now), isFalse);
    });

    test('a suspendedUntil on an active account does not suspend it', () {
      // Left over from a previous, lifted suspension. Status governs.
      final u = user(
        status: 'active',
        suspendedUntil: now.add(const Duration(days: 1)),
      );
      expect(u.isActiveAt(now), isTrue);
    });

    test('an admin is subject to suspension like anyone else', () {
      expect(user(role: 'admin', status: 'suspended').isActiveAt(now), isFalse);
    });
  });

  group('state predicates', () {
    test('indefinite, temporary and lapsed are mutually exclusive', () {
      final indefinite = user(status: 'suspended');
      final temporary = user(
        status: 'suspended',
        suspendedUntil: DateTime.now().add(const Duration(hours: 2)),
      );
      final lapsed = user(
        status: 'suspended',
        suspendedUntil: DateTime.now().subtract(const Duration(hours: 2)),
      );

      expect(indefinite.isSuspendedIndefinitely, isTrue);
      expect(indefinite.isSuspendedTemporarily, isFalse);
      expect(indefinite.hasLapsedSuspension, isFalse);

      expect(temporary.isSuspendedIndefinitely, isFalse);
      expect(temporary.isSuspendedTemporarily, isTrue);
      expect(temporary.hasLapsedSuspension, isFalse);

      expect(lapsed.isSuspendedIndefinitely, isFalse);
      expect(lapsed.isSuspendedTemporarily, isFalse);
      expect(lapsed.hasLapsedSuspension, isTrue);
    });

    test('an active account is in none of the suspended states', () {
      final u = user();
      expect(u.isSuspendedIndefinitely, isFalse);
      expect(u.isSuspendedTemporarily, isFalse);
      expect(u.hasLapsedSuspension, isFalse);
    });
  });

  group('serialisation', () {
    test('suspendedUntil is omitted when null', () {
      expect(user().toFirestore().containsKey('suspendedUntil'), isFalse);
    });

    test('suspendedUntil round-trips when set', () {
      final until = DateTime(2026, 8, 5, 9, 30);
      final map = user(
        status: 'suspended',
        suspendedUntil: until,
      ).toFirestore();
      expect(map.containsKey('suspendedUntil'), isTrue);
    });
  });

  group('copyWith', () {
    test('clearSuspendedUntil removes the date', () {
      final u = user(
        status: 'suspended',
        suspendedUntil: now.add(const Duration(days: 1)),
      );
      final lifted = u.copyWith(status: 'active', clearSuspendedUntil: true);

      expect(lifted.suspendedUntil, isNull);
      expect(lifted.isActiveAt(now), isTrue);
    });

    test('omitting suspendedUntil preserves it', () {
      final until = now.add(const Duration(days: 1));
      final u = user(status: 'suspended', suspendedUntil: until);
      expect(u.copyWith(name: 'Renamed').suspendedUntil, until);
    });
  });
}
