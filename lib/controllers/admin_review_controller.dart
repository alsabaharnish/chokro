import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// The bin a submission was made at, for its label and radius.
final binForReviewProvider = FutureProvider.family<BinModel?, String>((
  ref,
  binId,
) async {
  if (binId.isEmpty) return null;
  return ref.watch(binServiceProvider).getBin(binId);
});

/// Which row is currently being decided, and any error from the last attempt.
class ReviewUiState {
  final String? busyDisposalId;
  final String? error;
  final String? lastMessage;

  const ReviewUiState({this.busyDisposalId, this.error, this.lastMessage});

  bool isBusy(String disposalId) => busyDisposalId == disposalId;
}

class AdminReviewController extends Notifier<ReviewUiState> {
  @override
  ReviewUiState build() => const ReviewUiState();

  void clearMessages() =>
      state = ReviewUiState(busyDisposalId: state.busyDisposalId);

  Future<void> approve(String disposalId) async {
    state = ReviewUiState(busyDisposalId: disposalId);
    try {
      final outcome = await ref.read(reviewServiceProvider).approve(disposalId);
      state = ReviewUiState(
        lastMessage:
            'Approved — ${outcome.pointsAwarded ?? 0} points credited.',
      );
    } on ReviewException catch (err) {
      state = ReviewUiState(error: err.message);
    } catch (_) {
      state = const ReviewUiState(error: 'Something went wrong. Try again.');
    }
  }

  Future<void> reject(String disposalId, String reason) async {
    if (reason.trim().isEmpty) {
      state = const ReviewUiState(
        error: 'A rejection needs a reason — the user is shown it.',
      );
      return;
    }

    state = ReviewUiState(busyDisposalId: disposalId);
    try {
      await ref.read(reviewServiceProvider).reject(disposalId, reason.trim());
      state = const ReviewUiState(
        lastMessage: 'Rejected, and the user told why.',
      );
    } on ReviewException catch (err) {
      state = ReviewUiState(error: err.message);
    } catch (_) {
      state = const ReviewUiState(error: 'Something went wrong. Try again.');
    }
  }
}

final adminReviewControllerProvider =
    NotifierProvider<AdminReviewController, ReviewUiState>(
      AdminReviewController.new,
    );
