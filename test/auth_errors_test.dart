import 'package:chokro/core/auth_errors.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('authErrorMessage', () {
    test('never leaks the vendor, the code, or a bracketed prefix', () {
      // The reason this function exists. The login screen used to show
      // `error.toString()`, which reads:
      //   [firebase_auth/invalid-credential] The supplied auth credential is
      //   incorrect, malformed or has expired.
      const codes = <String?>[
        'invalid-credential',
        'wrong-password',
        'user-not-found',
        'invalid-email',
        'user-disabled',
        'email-already-in-use',
        'weak-password',
        'operation-not-allowed',
        'too-many-requests',
        'network-request-failed',
        'requires-recent-login',
        null,
        'some-code-we-have-never-seen',
      ];

      for (final code in codes) {
        final message = authErrorMessage(code);
        expect(message, isNotEmpty, reason: 'no message for $code');
        expect(message, isNot(contains('firebase')), reason: 'for $code');
        expect(message, isNot(contains('[')), reason: 'for $code');
        expect(message, isNot(contains('Exception')), reason: 'for $code');
        // An unrecognised code must not be echoed at the user either.
        if (code != null) {
          expect(message, isNot(contains(code)), reason: 'for $code');
        }
      }
    });

    test('every message is a complete sentence', () {
      for (final code in <String?>[
        'invalid-credential',
        'weak-password',
        null,
      ]) {
        final message = authErrorMessage(code);
        expect(message.endsWith('.'), isTrue, reason: 'for $code: $message');
        expect(message[0], message[0].toUpperCase(), reason: 'for $code');
      }
    });

    test('the three credential failures are indistinguishable', () {
      // Not tidiness. Firebase collapses these into invalid-credential when
      // email enumeration protection is on, and saying which half of the pair
      // was wrong would hand an attacker a way to confirm an address exists.
      final byCode = [
        authErrorMessage('invalid-credential'),
        authErrorMessage('wrong-password'),
        authErrorMessage('user-not-found'),
      ];
      expect(byCode.toSet(), hasLength(1));
    });

    test('a wrong password and an existing email lead somewhere different', () {
      // Registration is the one place where "this email is taken" is safe to
      // say — the user is being told about an account they are trying to create.
      expect(
        authErrorMessage('email-already-in-use'),
        isNot(authErrorMessage('invalid-credential')),
      );
      expect(authErrorMessage('email-already-in-use'), contains('Sign in'));
    });

    test('a lost connection is not reported as a credential problem', () {
      // Previously every failure looked the same to the user, so someone on a
      // dropped connection concluded they had forgotten their password.
      final network = authErrorMessage('network-request-failed');
      expect(network, contains('connection'));
      expect(network, isNot(authErrorMessage('invalid-credential')));
    });
  });

  group('AuthFailure', () {
    test('toString is the display message, not the class name', () {
      // Views that fall back to interpolating the error still produce something
      // readable.
      const failure = AuthFailure('That did not work.', code: 'x');
      expect('$failure', 'That did not work.');
    });

    test('keeps the originating code for logs without showing it', () {
      const failure = AuthFailure('Message.', code: 'too-many-requests');
      expect(failure.code, 'too-many-requests');
      expect(failure.message, isNot(contains('too-many-requests')));
    });
  });
}
