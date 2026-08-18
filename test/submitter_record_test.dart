import 'package:chokro/core/submitter_record.dart';
import 'package:chokro/models/disposal_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// The submitter's prior record shown in the review queue (F2.7).
///
/// Counting is the whole of it, and counting the wrong thing here is the sort of
/// error that never announces itself — a reviewer would simply be shown a
/// reassuring number and approve on it.

DisposalModel _disposal({required String id, required DisposalStatus status}) {
  return DisposalModel(
    id: id,
    userId: 'user-1',
    binId: 'bin-1',
    itemType: DisposalItemType.plasticBottle,
    declaredItemCount: 3,
    photoUrl: 'https://example.com/a.jpg',
    photoPublicId: 'a',
    capturedLat: 23.78,
    capturedLng: 90.4,
    distanceMeters: 10,
    status: status,
    pointsAwarded: status == DisposalStatus.autoApproved ||
            status == DisposalStatus.manualApproved
        ? 50
        : 0,
  );
}

void main() {
  group('SubmitterRecord.from', () {
    test('counts both kinds of approval as approved', () {
      // `autoApproved` and `manualApproved` are separate statuses, and the
      // distinction matters on the user's own history screen. To a reviewer
      // asking "does this person submit honestly" they are the same answer, and
      // counting only one of them would halve every good record.
      final record = SubmitterRecord.from([
        _disposal(id: '1', status: DisposalStatus.autoApproved),
        _disposal(id: '2', status: DisposalStatus.manualApproved),
      ]);

      expect(record.approved, 2);
      expect(record.rejected, 0);
      expect(record.considered, 2);
    });

    test('counts rejections and pendings separately', () {
      final record = SubmitterRecord.from([
        _disposal(id: '1', status: DisposalStatus.autoApproved),
        _disposal(id: '2', status: DisposalStatus.rejected),
        _disposal(id: '3', status: DisposalStatus.rejected),
        _disposal(id: '4', status: DisposalStatus.pending),
      ]);

      expect(record.approved, 1);
      expect(record.rejected, 2);
      expect(record.pending, 1);
      expect(record.considered, 4);
    });

    test('excludes the submission being reviewed', () {
      // The card's own disposal is in the query result and is itself pending.
      // Counting it would add one to `pending` on every card in the queue and
      // make the record describe the present instead of the past.
      final record = SubmitterRecord.from(
        [
          _disposal(id: 'current', status: DisposalStatus.pending),
          _disposal(id: 'old', status: DisposalStatus.autoApproved),
        ],
        excludeId: 'current',
      );

      expect(record.considered, 1);
      expect(record.pending, 0);
      expect(record.approved, 1);
    });

    test('an empty history is a first submission', () {
      final record = SubmitterRecord.from([]);

      expect(record.isFirstSubmission, isTrue);
      expect(record.summary, 'First submission');
    });

    test('excluding the only entry is still a first submission', () {
      final record = SubmitterRecord.from(
        [_disposal(id: 'current', status: DisposalStatus.pending)],
        excludeId: 'current',
      );

      expect(record.isFirstSubmission, isTrue);
    });
  });

  group('hasRejections', () {
    test('any single rejection counts', () {
      // Deliberately not a ratio. With a handful of submissions a ratio swings
      // wildly, and "two of their last five were rejected" is exactly the case a
      // threshold would hide.
      final record = SubmitterRecord.from([
        for (var i = 0; i < 30; i++)
          _disposal(id: '$i', status: DisposalStatus.autoApproved),
        _disposal(id: 'bad', status: DisposalStatus.rejected),
      ]);

      expect(record.hasRejections, isTrue);
    });

    test('a clean record is not flagged', () {
      final record = SubmitterRecord.from([
        _disposal(id: '1', status: DisposalStatus.autoApproved),
        _disposal(id: '2', status: DisposalStatus.pending),
      ]);

      expect(record.hasRejections, isFalse);
    });

    test('a first submission is not flagged', () {
      expect(SubmitterRecord.empty.hasRejections, isFalse);
    });
  });

  group('summary', () {
    test('names the window rather than implying an all-time count', () {
      // The query is bounded, so the line must not read as a lifetime total.
      final record = SubmitterRecord.from([
        for (var i = 0; i < 8; i++)
          _disposal(id: '$i', status: DisposalStatus.autoApproved),
      ]);

      expect(record.summary, '8 approved (last 8)');
    });

    test('omits zero counts instead of printing them', () {
      final record = SubmitterRecord.from([
        _disposal(id: '1', status: DisposalStatus.autoApproved),
      ]);

      expect(record.summary, isNot(contains('0 rejected')));
    });

    test('never mentions pending submissions', () {
      // The record is fetched per submitter and cached, so it cannot exclude the
      // specific card being viewed — and that card is pending. Printing a
      // pending count beside the submission under review would invent a second
      // one. The count is still available on the object for anything that has
      // the context to use it.
      final record = SubmitterRecord.from([
        _disposal(id: 'current', status: DisposalStatus.pending),
        _disposal(id: 'other', status: DisposalStatus.pending),
        _disposal(id: 'done', status: DisposalStatus.autoApproved),
      ]);

      expect(record.pending, 2, reason: 'still counted on the object');
      expect(record.summary, isNot(contains('awaiting')));
      expect(record.summary, isNot(contains('pending')));
      expect(record.summary, '1 approved (last 3)');
    });

    test('reports rejections when there are any', () {
      final record = SubmitterRecord.from([
        _disposal(id: '1', status: DisposalStatus.autoApproved),
        _disposal(id: '2', status: DisposalStatus.rejected),
      ]);

      expect(record.summary, contains('1 approved'));
      expect(record.summary, contains('1 rejected'));
    });
  });
}
