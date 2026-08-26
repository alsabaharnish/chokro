import 'package:chokro/controllers/admin_review_controller.dart';
import 'package:chokro/controllers/claim_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// One in-flight decision must not clear another's spinner.
///
/// Both review states held a single busy id and every entry point replaced the
/// whole state. Deciding a second row during the first's 90-second timeout
/// window blanked the first row's spinner and re-armed its Approve and Reject
/// buttons — so an admin could send a second decision for a submission that
/// was already being decided.
void main() {
  group('ReviewUiState', () {
    test('tracks several rows at once', () {
      const initial = ReviewUiState();

      final two = initial.busy('disposal-1').busy('disposal-2');

      expect(two.isBusy('disposal-1'), isTrue);
      expect(two.isBusy('disposal-2'), isTrue);
    });

    test('finishing one row leaves the other spinning', () {
      final state = const ReviewUiState()
          .busy('disposal-1')
          .busy('disposal-2')
          .done('disposal-1', message: 'Approved — 50 points credited.');

      expect(state.isBusy('disposal-1'), isFalse);
      expect(
        state.isBusy('disposal-2'),
        isTrue,
        reason: 'the second decision is still in flight',
      );
      expect(state.lastMessage, contains('50 points'));
    });

    test('clearing messages keeps the in-flight set', () {
      final state = const ReviewUiState().busy('disposal-1');

      expect(
        ReviewUiState(busyIds: state.busyIds).isBusy('disposal-1'),
        isTrue,
      );
    });

    test('a failure on one row does not free the others', () {
      final state = const ReviewUiState()
          .busy('disposal-1')
          .busy('disposal-2')
          .done('disposal-1', failure: 'Something went wrong. Try again.');

      expect(state.error, isNotNull);
      expect(state.isBusy('disposal-2'), isTrue);
    });
  });

  group('ClaimReviewUiState', () {
    test('behaves the same way, because the two queues are the same shape', () {
      final state = const ClaimReviewUiState()
          .busy('claim-1')
          .busy('claim-2')
          .done('claim-1', message: 'Approved — 15 points credited.');

      expect(state.isBusy('claim-1'), isFalse);
      expect(state.isBusy('claim-2'), isTrue);
      expect(state.lastMessage, contains('15 points'));
    });
  });
}
