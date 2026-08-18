/// The submitter's prior record, for the review queue (F2.7).
///
/// The brief asks the queue to show "photo, distance, flags and the user's
/// history". The first three were there; this is the fourth, and it is the one
/// that changes a decision rather than describing a submission.
///
/// A photograph that is merely ambiguous means something different depending on
/// who sent it. From an account with thirty clean approvals it is almost
/// certainly a bad camera angle. From one with four rejections in its last ten
/// it is worth a closer look. Without this, every borderline case is judged in
/// isolation and the reviewer has no way to tell those two situations apart.
///
/// Pure and countable so it can be unit-tested without Firestore.
library;

import '../models/disposal_model.dart';

class SubmitterRecord {
  const SubmitterRecord({
    required this.approved,
    required this.rejected,
    required this.pending,
    required this.considered,
  });

  /// Both `autoApproved` and `manualApproved`. The distinction matters to the
  /// user's history screen, not to a reviewer asking "does this person submit
  /// honestly".
  final int approved;

  final int rejected;

  /// Still awaiting a decision — other cards in this same queue.
  final int pending;

  /// How many submissions were examined, which is bounded. Reported so the
  /// interface can say "of their last 12" rather than implying an all-time
  /// count it did not compute.
  final int considered;

  static const empty = SubmitterRecord(
    approved: 0,
    rejected: 0,
    pending: 0,
    considered: 0,
  );

  /// Counts [disposals], skipping [excludeId].
  ///
  /// The submission being reviewed is in that list and is itself pending.
  /// Counting it would add one to `pending` on every card and make the record
  /// describe the present rather than the past.
  factory SubmitterRecord.from(
    List<DisposalModel> disposals, {
    String? excludeId,
  }) {
    var approved = 0;
    var rejected = 0;
    var pending = 0;
    var considered = 0;

    for (final disposal in disposals) {
      if (excludeId != null && disposal.id == excludeId) continue;
      considered++;

      switch (disposal.status) {
        case DisposalStatus.autoApproved:
        case DisposalStatus.manualApproved:
          approved++;
        case DisposalStatus.rejected:
          rejected++;
        case DisposalStatus.pending:
          pending++;
      }
    }

    return SubmitterRecord(
      approved: approved,
      rejected: rejected,
      pending: pending,
      considered: considered,
    );
  }

  /// Nothing decided before this one.
  bool get isFirstSubmission => considered == 0;

  /// Whether the record is worth the reviewer's attention.
  ///
  /// Any prior rejection qualifies. Deliberately not a ratio: with a handful of
  /// submissions a ratio swings wildly, and "two of their last five were
  /// rejected" is exactly the case a threshold would hide.
  bool get hasRejections => rejected > 0;

  /// One line for the card.
  ///
  /// Reports decisions only. [pending] is deliberately left out: the record is
  /// fetched per submitter and cached, so it cannot exclude the specific card
  /// being viewed, and that card is itself pending. Printing "1 awaiting review"
  /// beside the very submission under review invents a second one that does not
  /// exist. Decided outcomes are also the only part that answers the reviewer's
  /// actual question, which is whether this person submits honestly.
  ///
  /// [considered] is still the full window, so the count in brackets is the
  /// number of submissions looked at rather than the number decided.
  String get summary {
    if (isFirstSubmission) return 'First submission';

    final parts = <String>[
      '$approved approved',
      if (rejected > 0) '$rejected rejected',
    ];

    return '${parts.join(' · ')} (last $considered)';
  }
}
