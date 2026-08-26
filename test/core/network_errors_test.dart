import 'package:chokro/controllers/appeals_controller.dart';
import 'package:chokro/core/auth_errors.dart';
import 'package:chokro/core/network_errors.dart';
import 'package:chokro/services/claim_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

/// What reaches a user, and what must not.
///
/// `friendlyErrorMessage` used to end in a *blocklist*: return
/// `error.toString()` unless it started with `Instance of` or a bracketed
/// vendor prefix. Every plain `StateError` and `Exception` in the codebase
/// therefore went to the user verbatim, Dart prefix and all — a Champion whose
/// session lapsed mid-appeal read "The appeal could not be sent. Bad state:
/// Not signed in." The set of exception types reaching this function is
/// open-ended, so recognition is now by opt-in.
void main() {
  group('the app\'s own failures are shown as written', () {
    test('an AuthFailure keeps its prepared sentence', () {
      const failure = AuthFailure(
        'An account already exists for that email. Sign in instead.',
        code: 'email-already-in-use',
      );

      expect(friendlyErrorMessage(failure), failure.message);
    });

    test('a ClaimException keeps its prepared sentence', () {
      const failure = ClaimException('That eco-action was already reviewed.');

      expect(friendlyErrorMessage(failure), failure.message);
    });

    test('an AppealValidationException keeps its prepared sentence', () {
      final failure = AppealValidationException(
        'This appeal is not attached to a submission.',
      );

      expect(friendlyErrorMessage(failure), failure.message);
    });
  });

  group('internal failures are replaced, not forwarded', () {
    test('a StateError does not reach the user with its Dart prefix', () {
      final message = friendlyErrorMessage(StateError('Not signed in.'));

      expect(message, isNot(contains('Bad state')));
      expect(message, isNot(contains('Not signed in.')));
      expect(message, 'Something went wrong. Try again.');
    });

    test('a bare Exception does not reach the user either', () {
      final message = friendlyErrorMessage(Exception('Not signed in'));

      expect(message, isNot(contains('Exception')));
      expect(message, 'Something went wrong. Try again.');
    });

    test('a type error is not narrated to the user', () {
      expect(
        friendlyErrorMessage(TypeError()),
        'Something went wrong. Try again.',
      );
    });
  });

  group('Firestore codes keep their specific guidance', () {
    test('permission-denied is explained rather than generalised', () {
      final message = friendlyErrorMessage(
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
      );

      expect(message, isNot('Something went wrong. Try again.'));
      expect(message.toLowerCase(), contains('permission'));
    });

    test('an unrecognised Firestore code still gets the read wording', () {
      final message = friendlyErrorMessage(
        FirebaseException(plugin: 'cloud_firestore', code: 'aborted'),
      );

      expect(message, 'Something went wrong loading this. Try again.');
    });
  });
}
