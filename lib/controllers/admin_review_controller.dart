import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/submitter_record.dart';
import '../models/bin_model.dart';
import '../models/disposal_model.dart';
import '../models/user_model.dart';
import '../services/review_service.dart';
import '../services/user_service.dart';
import 'disposal_controller.dart';
import 'scan_controller.dart';

final reviewServiceProvider = Provider<ReviewService>((ref) => ReviewService());

/// Everything awaiting a decision, oldest first.
///
/// Oldest first is deliberate: a queue worked newest-first leaves the earliest
/// submissions waiting longest, which is exactly backwards for the person who
/// has been staring at a "pending" badge since yesterday.
final pendingDisposalsProvider = StreamProvider<List<DisposalModel>>((ref) {
  return ref.watch(disposalServiceProvider).watchPendingDisposals();
});

/// Submitter details for a queue row. Cached per uid by Riverpod, so a user with
/// several pending submissions is fetched once rather than once per card.
final submitterProvider = FutureProvider.family<UserModel?, String>((
  ref,
  uid,
) async {
  return UserService().getUser(uid);
});

/// The submitter's prior record, for the reviewer's context (F2.7).
///
/// Keyed by uid and cached by Riverpod, so a user with several pending
/// submissions costs one query rather than one per card — the same reason
/// [submitterProvider] is a family.
///
/// Deliberately a `FutureProvider` rather than a stream. A live subscription per
/// card on a screen an administrator keeps open all shift would hold one
/// Firestore listener per submitter for a figure that only needs to be right at
/// the moment of the decision.
final submitterRecordProvider = FutureProvider.family<SubmitterRecord, String>((
  ref,
  uid,
) async {
  if (uid.isEmpty) return SubmitterRecord.empty;
  final recent = await ref.watch(disposalServiceProvider).recentForUser(uid);
  return SubmitterRecord.from(recent);
});

/// The bin a submission was made at, for its label and radius.
final binForReviewProvider = FutureProvider.family<BinModel?, String>((
  ref,
  binId,
) async {
  if (binId.isEmpty) return null;
  return ref.watch(binServiceProvider).getBin(binId);
});

/// Which rows are currently being decided, and any error from the last attempt.
///
/// `busyIds` is a **set**, not a single id. It held one id, and every entry
/// point replaced the whole state — so an admin who approved one disposal and,
/// during the 90-second timeout window, approved a second, watched the first
/// row's spinner vanish and its Approve and Reject buttons come back to life
/// while that decision was still in flight. Pressing them again sent a second
/// decision for a submission already being decided.
class ReviewUiState {
  final Set<String> busyIds;
  final String? error;
  final String? lastMessage;

  const ReviewUiState({
    this.busyIds = const <String>{},
    this.error,
    this.lastMessage,
  });

  bool isBusy(String disposalId) => busyIds.contains(disposalId);

  /// Adds a row to the in-flight set, leaving the messages alone.
  ReviewUiState busy(String id) =>
      ReviewUiState(busyIds: {...busyIds, id}, error: error);

  /// Removes a row and states the outcome. Other in-flight rows keep their
  /// spinners, which is the whole point of the set.
  ReviewUiState done(String id, {String? message, String? failure}) =>
      ReviewUiState(
        busyIds: busyIds.where((each) => each != id).toSet(),
        lastMessage: message,
        error: failure,
      );
}

class AdminReviewController extends Notifier<ReviewUiState> {
  @override
  ReviewUiState build() => const ReviewUiState();

  void clearMessages() => state = ReviewUiState(busyIds: state.busyIds);

  Future<void> approve(String disposalId) async {
    state = state.busy(disposalId);
    try {
      final outcome = await ref.read(reviewServiceProvider).approve(disposalId);
      state = state.done(
        disposalId,
        message: 'Approved — ${outcome.pointsAwarded ?? 0} points credited.',
      );
    } on ReviewException catch (err) {
      state = state.done(disposalId, failure: err.message);
    } catch (_) {
      state = state.done(
        disposalId,
        failure: 'Something went wrong. Try again.',
      );
    }
  }

  Future<void> reject(String disposalId, String reason) async {
    if (reason.trim().isEmpty) {
      state = ReviewUiState(
        busyIds: state.busyIds,
        error: 'A rejection needs a reason — the user is shown it.',
      );
      return;
    }

    state = state.busy(disposalId);
    try {
      await ref.read(reviewServiceProvider).reject(disposalId, reason.trim());
      state = state.done(
        disposalId,
        message: 'Rejected, and the user told why.',
      );
    } on ReviewException catch (err) {
      state = state.done(disposalId, failure: err.message);
    } catch (_) {
      state = state.done(
        disposalId,
        failure: 'Something went wrong. Try again.',
      );
    }
  }
}

final adminReviewControllerProvider =
    NotifierProvider<AdminReviewController, ReviewUiState>(
      AdminReviewController.new,
    );
