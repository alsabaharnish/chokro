import 'package:chokro/models/claim_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClaimStatus', () {
    test('parses the three known states', () {
      expect(ClaimStatus.fromName('pending'), ClaimStatus.pending);
      expect(ClaimStatus.fromName('approved'), ClaimStatus.approved);
      expect(ClaimStatus.fromName('rejected'), ClaimStatus.rejected);
    });

    test(
      'anything unrecognised falls back to pending — fail toward no payout',
      () {
        expect(ClaimStatus.fromName('autoApproved'), ClaimStatus.pending);
        expect(ClaimStatus.fromName(null), ClaimStatus.pending);
        expect(ClaimStatus.fromName(''), ClaimStatus.pending);
      },
    );

    test('there is no auto-approved state', () {
      // Claims are never auto-approved: the automatic lane exists only where
      // mechanical checks can pass, and none can here.
      expect(
        ClaimStatus.values.map((s) => s.name),
        isNot(contains('autoApproved')),
      );
      expect(ClaimStatus.values, hasLength(3));
    });
  });

  group('ClaimActionType', () {
    test('the vocabulary is closed and complete', () {
      expect(ClaimActionType.values, hasLength(5));
      for (final type in ClaimActionType.values) {
        expect(ClaimActionType.fromName(type.name), type);
      }
    });

    test('an invented action type does not parse', () {
      expect(ClaimActionType.fromName('recycling'), isNull);
      expect(ClaimActionType.fromName(null), isNull);
    });

    test('every type has a label and an evidence hint', () {
      for (final type in ClaimActionType.values) {
        expect(type.label, isNotEmpty);
        expect(type.evidenceHint, isNotEmpty);
      }
    });
  });

  group('toCreateJson', () {
    final claim = ClaimModel(
      userId: 'u1',
      actionType: ClaimActionType.composting,
      photoUrl: 'https://res.cloudinary.test/p.jpg',
      photoPublicId: 'chokro/claims/u1/p',
    );

    test('carries exactly the five client-writable keys', () {
      expect(claim.toCreateJson().keys.toSet(), {
        'userId',
        'actionType',
        'photoUrl',
        'photoPublicId',
        'status',
      });
    });

    test('always writes pending, whatever the model says', () {
      final approved = claim.copyWith(
        status: ClaimStatus.approved,
        pointsAwarded: 15,
      );
      expect(approved.toCreateJson()['status'], 'pending');
    });

    test('omits every server-owned field', () {
      final decided = claim.copyWith(
        status: ClaimStatus.approved,
        pointsAwarded: 15,
        photoHash: 'deadbeef',
        reviewedBy: 'admin_uid',
      );
      final json = decided.toCreateJson();

      for (final key in [
        'pointsAwarded',
        'photoHash',
        'reviewedBy',
        'reviewedAt',
      ]) {
        expect(json.containsKey(key), isFalse, reason: '$key must not be sent');
      }
    });
  });

  group('fromJson', () {
    test('wrongly typed fields fail closed instead of throwing', () {
      final claim = ClaimModel.fromJson(<String, dynamic>{
        'id': 7,
        'userId': false,
        'actionType': <String>['composting'],
        'status': 99,
        'pointsAwarded': 12.5,
        'reviewedAt': <String, dynamic>{},
      });

      expect(claim.id, isNull);
      expect(claim.userId, isEmpty);
      expect(claim.actionType, ClaimActionType.reusableBagOrBottle);
      expect(claim.status, ClaimStatus.pending);
      expect(claim.pointsAwarded, isNull);
      expect(claim.reviewedAt, isNull);
    });
  });

  group('validate', () {
    ClaimModel base({
      ClaimStatus status = ClaimStatus.pending,
      int? points,
      String? reason,
      String? reviewedBy,
    }) => ClaimModel(
      userId: 'u1',
      actionType: ClaimActionType.treePlanting,
      photoUrl: 'https://res.cloudinary.test/p.jpg',
      status: status,
      pointsAwarded: points,
      rejectionReason: reason,
      reviewedBy: reviewedBy,
    );

    test('a well-formed pending claim is valid', () {
      expect(base().validate(), isEmpty);
    });

    test('a photograph is required', () {
      final claim = ClaimModel(
        userId: 'u1',
        actionType: ClaimActionType.treePlanting,
        photoUrl: '',
      );
      expect(claim.validate(), isNotEmpty);
    });

    test('a rejection must carry a reason', () {
      expect(
        base(status: ClaimStatus.rejected, reviewedBy: 'admin').validate(),
        isNotEmpty,
      );
      expect(
        base(
          status: ClaimStatus.rejected,
          reason: 'Photo does not show a planted tree.',
          reviewedBy: 'admin',
        ).validate(),
        isEmpty,
      );
    });

    test('an approval must carry points', () {
      expect(
        base(status: ClaimStatus.approved, reviewedBy: 'admin').validate(),
        isNotEmpty,
      );
    });

    test('every decided claim must name its reviewer', () {
      // Unlike a disposal, there is no path here that decides without a person,
      // so reviewedBy is never legitimately null on a terminal claim.
      expect(
        base(status: ClaimStatus.approved, points: 15).validate(),
        isNotEmpty,
      );
    });
  });

  group('creditedPoints', () {
    ClaimModel withStatus(ClaimStatus status) => ClaimModel(
      userId: 'u1',
      actionType: ClaimActionType.composting,
      photoUrl: 'p',
      status: status,
      pointsAwarded: 15,
    );

    test('is zero unless approved, even when points are recorded', () {
      // A pending claim has awarded nothing yet, and a rejected one never will.
      expect(withStatus(ClaimStatus.pending).creditedPoints, 0);
      expect(withStatus(ClaimStatus.rejected).creditedPoints, 0);
    });

    test('is the snapshotted award once approved', () {
      expect(withStatus(ClaimStatus.approved).creditedPoints, 15);
    });
  });

  group('ClaimQuota week keys', () {
    test('formats as YYYY-Www with a padded week', () {
      expect(
        ClaimQuota.weekKey(DateTime.utc(2026, 8, 1)),
        matches(r'^\d{4}-W\d{2}$'),
      );
    });

    test('every day of one ISO week shares a key', () {
      // Monday 27 July 2026 through Sunday 2 August 2026.
      final keys = <String>{};
      for (var day = 27; day <= 31; day++) {
        keys.add(ClaimQuota.weekKey(DateTime.utc(2026, 7, day)));
      }
      keys.add(ClaimQuota.weekKey(DateTime.utc(2026, 8, 1)));
      keys.add(ClaimQuota.weekKey(DateTime.utc(2026, 8, 2)));
      expect(keys, hasLength(1));
    });

    test('the following Monday starts a new week', () {
      final sunday = ClaimQuota.weekKey(DateTime.utc(2026, 8, 2));
      final monday = ClaimQuota.weekKey(DateTime.utc(2026, 8, 3));
      expect(sunday, isNot(monday));
    });

    test('early January can belong to the previous ISO year', () {
      // 1 January 2027 is a Friday, so it falls in the ISO week whose Thursday
      // is 31 December 2026 — ISO week-year 2026. Getting this wrong silently
      // corrupts quota enforcement at year boundaries.
      expect(ClaimQuota.weekKey(DateTime.utc(2027, 1, 1)), startsWith('2026-'));
    });

    test('docId combines the user and the week', () {
      final id = ClaimQuota.docId('user_1', DateTime.utc(2026, 8, 1));
      expect(id, startsWith('user_1_'));
      expect(id, contains('-W'));
    });
  });
}
