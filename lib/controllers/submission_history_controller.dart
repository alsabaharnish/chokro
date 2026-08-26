import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/disposal_model.dart';
import 'current_user_provider.dart';
import 'disposal_controller.dart' show disposalServiceProvider;

/// The signed-in user's own submissions, newest first (F7.2).
///
/// Read-only. Nothing on this screen can change a status — a status is a payout
/// decision and only the server writes one.
final submissionHistoryProvider =
    StreamProvider.autoDispose<List<DisposalModel>>((ref) {
      final uid = ref.watch(currentUidProvider);
      if (uid == null) {
        return Stream<List<DisposalModel>>.value(const <DisposalModel>[]);
      }
      return ref.watch(disposalServiceProvider).watchUserDisposals(uid);
    });

/// How many submissions are waiting on a human decision. Drives the badge on
/// the history entry point so a user does not have to open the screen to find
/// out whether anything is outstanding.
final pendingSubmissionCountProvider = Provider.autoDispose<int>((ref) {
  final items = ref.watch(submissionHistoryProvider).asData?.value ?? const [];
  return items.where((d) => d.status.isPending).length;
});

/// Points credited across the loaded submissions.
///
/// Reads `pointsAwarded` rather than recomputing from the policy: awards are
/// snapshotted at decision time, so an administrator lowering the disposal
/// award must not change what a past submission was worth (§6.2).
final earnedFromDisposalsProvider = Provider.autoDispose<int>((ref) {
  final items = ref.watch(submissionHistoryProvider).asData?.value ?? const [];
  return items
      .where((d) => d.status.isApproved)
      .fold<int>(0, (sum, d) => sum + (d.pointsAwarded ?? 0));
});
