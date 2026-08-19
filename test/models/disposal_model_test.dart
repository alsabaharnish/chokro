import 'package:chokro/models/disposal_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  DisposalModel pendingSubmission() => const DisposalModel(
    id: 'disposal_001',
    userId: 'user_uid',
    binId: 'bin_001',
    photoUrl: 'https://storage.example/photo.jpg',
    capturedLat: 23.7809,
    capturedLng: 90.4074,
    distanceMeters: 11.2,
    declaredItemCount: 2,
    itemType: DisposalItemType.plasticBottle,
  );

  group('status machine', () {
    test('both approved states count as approved', () {
      expect(DisposalStatus.autoApproved.isApproved, isTrue);
      expect(DisposalStatus.manualApproved.isApproved, isTrue);
      expect(DisposalStatus.pending.isApproved, isFalse);
      expect(DisposalStatus.rejected.isApproved, isFalse);
    });

    test('only pending is non-terminal', () {
      expect(DisposalStatus.pending.isTerminal, isFalse);
      for (final status in DisposalStatus.values) {
        if (status != DisposalStatus.pending) {
          expect(status.isTerminal, isTrue, reason: status.name);
        }
      }
    });

    test('distinguishes human decisions from automatic ones', () {
      expect(DisposalStatus.autoApproved.wasHumanDecided, isFalse);
      expect(DisposalStatus.manualApproved.wasHumanDecided, isTrue);
      expect(DisposalStatus.rejected.wasHumanDecided, isTrue);
    });

    test(
      'an unknown stored status falls back to pending, never to approved',
      () {
        // Fail toward no payout. A corrupted or future status value must not be
        // readable as "this user has been paid".
        expect(
          DisposalStatus.fromName('someFutureState'),
          DisposalStatus.pending,
        );
        expect(DisposalStatus.fromName(null), DisposalStatus.pending);
        expect(DisposalStatus.fromName(''), DisposalStatus.pending);
        expect(DisposalStatus.fromName('autoApproved').isApproved, isTrue);
      },
    );
  });

  group('credited points', () {
    test('a pending submission has credited nothing', () {
      final pending = pendingSubmission().copyWith(pointsAwarded: 50);
      expect(pending.isPending, isTrue);
      expect(pending.creditedPoints, 0);
    });

    test('a rejected submission has credited nothing', () {
      final rejected = pendingSubmission().copyWith(
        status: DisposalStatus.rejected,
        rejectionReason: 'Photo does not show the declared items.',
        pointsAwarded: 50,
      );
      expect(rejected.creditedPoints, 0);
    });

    test('an approved submission credits its snapshotted award', () {
      final auto = pendingSubmission().copyWith(
        status: DisposalStatus.autoApproved,
        pointsAwarded: 50,
      );
      expect(auto.creditedPoints, 50);
      expect(auto.wasAutoApproved, isTrue);
      expect(auto.wasManuallyApproved, isFalse);
    });

    test('the award is a snapshot, not a lookup', () {
      // A submission approved under an older policy keeps its old value even
      // after an admin changes the current disposal award.
      final old = pendingSubmission().copyWith(
        status: DisposalStatus.manualApproved,
        pointsAwarded: 50,
        reviewedBy: 'admin_uid',
      );
      expect(old.creditedPoints, 50);
    });
  });

  group('flags', () {
    test('parses a flag list from storage, skipping unknown entries', () {
      final parsed = DisposalModel.fromJson(<String, dynamic>{
        'userId': 'u',
        'binId': 'b',
        'flags': <dynamic>['outsideRadius', 'notARealFlag', 'lowConfidence'],
      });
      expect(parsed.flags, <DisposalFlag>[
        DisposalFlag.outsideRadius,
        DisposalFlag.lowConfidence,
      ]);
    });

    test('tolerates a missing or malformed flags field', () {
      expect(
        DisposalModel.fromJson(<String, dynamic>{'userId': 'u'}).flags,
        isEmpty,
      );
      expect(
        DisposalModel.fromJson(<String, dynamic>{'flags': 'nonsense'}).flags,
        isEmpty,
      );
    });

    test('every flag has an explanation for the review queue', () {
      for (final flag in DisposalFlag.values) {
        expect(flag.explanation.trim(), isNotEmpty, reason: flag.name);
      }
    });

    test('a submission can carry several flags at once', () {
      final flagged = pendingSubmission().copyWith(
        flags: const <DisposalFlag>[
          DisposalFlag.countMismatch,
          DisposalFlag.duplicatePhoto,
        ],
      );
      expect(flagged.hasFlags, isTrue);
      expect(flagged.flags.length, 2);
    });
  });

  group('item types', () {
    test('every type has a label', () {
      for (final type in DisposalItemType.values) {
        expect(type.label.trim(), isNotEmpty, reason: type.name);
      }
    });

    test('an unknown stored type parses as null', () {
      expect(DisposalItemType.fromName('unobtanium'), isNull);
      expect(
        DisposalItemType.fromName('plasticBottle'),
        DisposalItemType.plasticBottle,
      );
    });
  });

  group('serialization', () {
    test('round-trips through JSON', () {
      final submission = pendingSubmission().copyWith(
        status: DisposalStatus.manualApproved,
        pointsAwarded: 50,
        reviewedBy: 'admin_uid',
        flags: const <DisposalFlag>[DisposalFlag.lowConfidence],
        screenConfidence: 0.42,
        screenItemCount: 1,
        screenNotes: 'blurry',
        photoHash: 'abc123',
        photoPublicId: 'chokro/disposals/user_uid/photo123',
        verificationCompleted: true,
      );
      final parsed = DisposalModel.fromJson(
        submission.toJson(),
        id: submission.id,
      );

      expect(parsed.status, DisposalStatus.manualApproved);
      expect(parsed.pointsAwarded, 50);
      expect(parsed.reviewedBy, 'admin_uid');
      expect(parsed.flags, <DisposalFlag>[DisposalFlag.lowConfidence]);
      expect(parsed.screenConfidence, 0.42);
      expect(parsed.screenItemCount, 1);
      expect(parsed.photoHash, 'abc123');
      expect(parsed.photoPublicId, 'chokro/disposals/user_uid/photo123');
      expect(parsed.verificationCompleted, isTrue);
      expect(parsed.itemType, DisposalItemType.plasticBottle);
    });

    test('omits timestamps from the write map', () {
      final map = pendingSubmission().toJson();
      expect(map.containsKey('createdAt'), isFalse);
      expect(map.containsKey('reviewedAt'), isFalse);
    });

    test('the create map carries nothing that decides a payout', () {
      final map = pendingSubmission()
          .copyWith(
            status: DisposalStatus.autoApproved,
            pointsAwarded: 9999,
            photoHash: 'forged',
            screenConfidence: 1.0,
            reviewedBy: 'admin_uid',
          )
          .toCreateJson();

      // Even when the in-memory object has been tampered with, the map the
      // client sends cannot claim an approval or an award.
      expect(map['status'], DisposalStatus.pending.name);
      expect(map['flags'], isEmpty);
      expect(map.containsKey('pointsAwarded'), isFalse);
      expect(map.containsKey('photoHash'), isFalse);
      expect(map.containsKey('screenConfidence'), isFalse);
      expect(map.containsKey('screenItemCount'), isFalse);
      expect(map.containsKey('screenNotes'), isFalse);
      expect(map.containsKey('reviewedBy'), isFalse);
      expect(map.containsKey('rejectionReason'), isFalse);
      expect(map.containsKey('verificationCompleted'), isFalse);
    });

    test('the create map keeps what the server needs to verify', () {
      final map = pendingSubmission().toCreateJson();
      expect(map['userId'], 'user_uid');
      expect(map['binId'], 'bin_001');
      expect(map['capturedLat'], 23.7809);
      expect(map['capturedLng'], 90.4074);
      expect(map['declaredItemCount'], 2);
      expect(map['itemType'], 'plasticBottle');
    });

    test('an unknown stored item type falls back rather than throwing', () {
      final parsed = DisposalModel.fromJson(<String, dynamic>{
        'userId': 'u',
        'itemType': 'unobtanium',
      });
      expect(parsed.itemType, DisposalItemType.plasticOther);
    });
  });

  group('validation', () {
    test('a well-formed pending submission passes', () {
      expect(pendingSubmission().validate(), isEmpty);
    });

    test('requires user, bin and photo', () {
      expect(pendingSubmission().copyWith(userId: ' ').validate(), isNotEmpty);
      expect(pendingSubmission().copyWith(binId: '').validate(), isNotEmpty);
      expect(pendingSubmission().copyWith(photoUrl: '').validate(), isNotEmpty);
    });

    test('requires a plausible item count', () {
      expect(
        pendingSubmission().copyWith(declaredItemCount: 0).validate(),
        isNotEmpty,
      );
      expect(
        pendingSubmission().copyWith(declaredItemCount: -3).validate(),
        isNotEmpty,
      );
      expect(
        pendingSubmission().copyWith(declaredItemCount: 5000).validate(),
        isNotEmpty,
      );
    });

    test('rejects a failed location fix', () {
      final broken = pendingSubmission().copyWith(
        capturedLat: 0,
        capturedLng: 0,
      );
      expect(broken.validate(), isNotEmpty);
    });

    test('a rejection must record a reason', () {
      final noReason = pendingSubmission().copyWith(
        status: DisposalStatus.rejected,
      );
      expect(noReason.validate(), isNotEmpty);

      final withReason = pendingSubmission().copyWith(
        status: DisposalStatus.rejected,
        rejectionReason: 'Photo shows an empty bin.',
      );
      expect(withReason.validate(), isEmpty);
    });

    test('an approval must record the points awarded', () {
      final noPoints = pendingSubmission().copyWith(
        status: DisposalStatus.autoApproved,
      );
      expect(noPoints.validate(), isNotEmpty);
    });

    test('a manual approval must record the reviewing administrator', () {
      final noReviewer = pendingSubmission().copyWith(
        status: DisposalStatus.manualApproved,
        pointsAwarded: 50,
      );
      expect(noReviewer.validate(), isNotEmpty);

      final withReviewer = noReviewer.copyWith(reviewedBy: 'admin_uid');
      expect(withReviewer.validate(), isEmpty);
    });

    test('an auto-approval needs no reviewer', () {
      final auto = pendingSubmission().copyWith(
        status: DisposalStatus.autoApproved,
        pointsAwarded: 50,
      );
      expect(auto.validate(), isEmpty);
      expect(auto.reviewedBy, isNull);
    });
  });

  group('user-facing status', () {
    test('every status has a message', () {
      for (final status in DisposalStatus.values) {
        final submission = pendingSubmission().copyWith(status: status);
        expect(
          submission.userFacingStatus.trim(),
          isNotEmpty,
          reason: status.name,
        );
      }
    });

    test('a manual approval is announced as manually verified', () {
      final manual = pendingSubmission().copyWith(
        status: DisposalStatus.manualApproved,
      );
      expect(manual.userFacingStatus, 'Manually verified');
    });
  });
}
