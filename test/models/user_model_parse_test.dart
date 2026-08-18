import 'package:chokro/core/constants.dart';
import 'package:chokro/models/user_model.dart';
import 'package:chokro/models/wallet_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reading a user document (F1.1).
///
/// These matter more than their size suggests. This parsing sits under
/// `watchUser` -> `currentUserProvider` -> the router's auth gate, so a throw in
/// here is not a broken widget: the gate sees a stream with an error and no
/// value, reads it as "signed in with no profile", and redirects a valid account
/// to the recovery screen. Every cast below used to be unchecked.

UserModel _user(Object? data) => UserModel.fromMap(data, uid: 'uid-1');
WalletModel _wallet(Object? data) => WalletModel.fromMap(data, uid: 'uid-1');

void main() {
  group('UserModel.fromMap', () {
    test('reads a complete document', () {
      final user = _user({
        'name': 'Nabil',
        'email': 'nabil@example.com',
        'role': AppConstants.roleSeller,
        'status': AppConstants.statusActive,
        'createdAt': Timestamp.fromDate(DateTime.utc(2026, 3, 4)),
      });

      expect(user.uid, 'uid-1');
      expect(user.name, 'Nabil');
      expect(user.email, 'nabil@example.com');
      expect(user.isSeller, isTrue);
      expect(user.isActive, isTrue);
      // `Timestamp.toDate()` returns local time, so compare the instant rather
      // than the wall clock — this would otherwise pass or fail by timezone.
      expect(user.createdAt?.toUtc(), DateTime.utc(2026, 3, 4));
    });

    test('survives a pending server timestamp', () {
      // The case that actually broke. `createdAt` is written with
      // `FieldValue.serverTimestamp()`, so Firestore's immediate local echo of
      // the registration write carries null — and the old
      // `(data['createdAt'] as Timestamp)` threw on the very document signup
      // had just created.
      final user = _user({
        'name': 'Nabil',
        'email': 'nabil@example.com',
        'role': AppConstants.roleBuyer,
        'status': AppConstants.statusActive,
        'createdAt': null,
      });

      expect(user.createdAt, isNull);
      expect(user.isActive, isTrue, reason: 'a new account can act');
    });

    test('an empty document does not throw', () {
      final user = _user(<String, dynamic>{});

      expect(user.uid, 'uid-1');
      expect(user.name, isEmpty);
      expect(user.createdAt, isNull);
    });

    test('a null payload does not throw', () {
      // A deleted document races with a listener that has not torn down yet.
      expect(_user(null).name, isEmpty);
    });

    test('fields of the wrong type fall back instead of throwing', () {
      final user = _user({
        'name': 42,
        'email': ['not', 'a', 'string'],
        'role': 99,
        'status': false,
        'createdAt': 'nonsense',
      });

      expect(user.name, isEmpty);
      expect(user.email, isEmpty);
      expect(user.createdAt, isNull);
    });

    group('failing closed', () {
      test('a missing role reads as buyer, never as admin', () {
        // `isAdmin` gates the admin routes and the review queues. Guessing
        // upward on malformed data would hand out privileges.
        final user = _user({'name': 'X', 'email': 'x@y.z'});

        expect(user.role, AppConstants.roleBuyer);
        expect(user.isAdmin, isFalse);
        expect(user.isSeller, isFalse);
      });

      test('a missing status reads as suspended, never as active', () {
        final user = _user({'name': 'X', 'email': 'x@y.z'});

        expect(user.status, AppConstants.statusSuspended);
        expect(user.isActive, isFalse);
      });
    });

    test('accepts a date stored as ISO text or epoch millis', () {
      // Not written by this app, but a migration script or the emulator UI can
      // leave one behind, and reading it beats throwing.
      expect(
        _user({'createdAt': '2026-03-04T00:00:00Z'}).createdAt?.toUtc(),
        DateTime.utc(2026, 3, 4),
      );
      expect(
        _user({
          'createdAt': DateTime.utc(2026, 3, 4).millisecondsSinceEpoch,
        }).createdAt?.toUtc(),
        DateTime.utc(2026, 3, 4),
      );
    });
  });

  group('UserModel.toFirestore', () {
    UserModel sample({DateTime? createdAt}) => UserModel(
      uid: 'uid-1',
      name: 'Nabil',
      email: 'nabil@example.com',
      role: AppConstants.roleBuyer,
      status: AppConstants.statusActive,
      createdAt: createdAt,
    );

    test('omits createdAt, leaving it to the server', () {
      // §6 of the brief: every createdAt uses FieldValue.serverTimestamp(). This
      // map used to carry `Timestamp.fromDate(DateTime.now())` from the device,
      // so a phone with a skewed clock recorded a join date the server never
      // agreed to — and nothing downstream ever re-checks it.
      final map = sample(createdAt: DateTime.utc(2020)).toFirestore();

      expect(map.containsKey('createdAt'), isFalse);
    });

    test('carries every key the create rule requires, minus the timestamp', () {
      // The rule is hasAll(['name', 'email', 'role', 'status', 'createdAt']),
      // and the service adds the server timestamp for the last one.
      expect(
        sample().toFirestore().keys,
        containsAll(['name', 'email', 'role', 'status']),
      );
    });

    test('omits suspendedUntil rather than writing an explicit null', () {
      expect(sample().toFirestore().containsKey('suspendedUntil'), isFalse);
    });
  });

  group('WalletModel', () {
    test('survives a pending server timestamp', () {
      // Same failure as the user document, on the same screen: this is the
      // balance the home screen shows, so a throw greeted a brand-new account
      // with an error where its zero balance belonged.
      final wallet = _wallet({
        'userId': 'uid-1',
        'balance': 0,
        'updatedAt': null,
      });

      expect(wallet.balance, 0);
      expect(wallet.updatedAt, isNull);
    });

    test('a missing balance reads as zero, never as a guess', () {
      final wallet = _wallet(<String, dynamic>{});

      expect(wallet.balance, 0);
      expect(wallet.userId, 'uid-1', reason: 'falls back to the document id');
    });

    test('omits updatedAt on write, leaving it to the server', () {
      final map = const WalletModel(userId: 'uid-1', balance: 0).toFirestore();

      expect(map.containsKey('updatedAt'), isFalse);
      expect(map['balance'], 0);
      expect(map['userId'], 'uid-1');
    });
  });
}
