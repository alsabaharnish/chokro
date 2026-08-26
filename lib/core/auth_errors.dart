/// Turns an authentication failure into something a user can act on.
///
/// The login and register screens were showing `error.toString()` in a
/// snackbar, which puts text like
///
///   [firebase_auth/invalid-credential] The supplied auth credential is
///   incorrect, malformed or has expired.
///
/// in front of someone who mistyped their password. It names our vendor, leaks
/// the exception class, and does not say what to do next.
///
/// Deliberately no Flutter and no Firebase import, so this is unit-testable
/// without a binding or a live project. The code is read off the exception by
/// the caller.
library;

import 'network_errors.dart';

/// An authentication failure carrying a message already fit to display.
///
/// The controller converts the vendor exception into this at the boundary, so
/// no view has to know that Firebase exists or what shape its errors are.
class AuthFailure implements UserFacingException {
  const AuthFailure(this.message, {this.code});

  /// Ready to show. Never null, never a stack trace, never a vendor prefix.
  @override
  final String message;

  /// The originating Firebase code, kept for logging and tests. Not shown.
  final String? code;

  @override
  String toString() => message;
}

/// Maps a Firebase Auth error code to a message worth reading.
///
/// Unknown codes fall through to a generic message rather than exposing the
/// code itself: an unrecognised code means we have not thought about that case,
/// and the raw string helps the user no more than silence would.
String authErrorMessage(String? code) {
  switch (code) {
    // Firebase collapses wrong-password and user-not-found into
    // invalid-credential when email enumeration protection is on (the default
    // for projects created since late 2023). All three must say the same thing
    // anyway — telling an attacker which half of the pair was wrong is exactly
    // the enumeration leak that protection exists to close.
    case 'invalid-credential':
    case 'wrong-password':
    case 'user-not-found':
      return 'That email and password do not match. Check both and try again.';

    case 'invalid-email':
      return 'That does not look like an email address.';

    case 'user-disabled':
      return 'This account has been disabled. Contact a 3ZERO Admin.';

    case 'email-already-in-use':
      return 'An account already exists with that email. Sign in instead.';

    case 'weak-password':
      return 'Choose a longer password — at least six characters.';

    case 'operation-not-allowed':
      return 'Email sign-in is not enabled for this app. Contact a 3ZERO Admin.';

    case 'too-many-requests':
      return 'Too many attempts. Wait a few minutes before trying again.';

    case 'network-request-failed':
      return 'No connection. Check your network and try again.';

    case 'requires-recent-login':
      return 'For security, sign in again before making this change.';

    default:
      // Deliberately not "signing you in": this same fallback is what the
      // registration screen reaches when the Firebase *account* was created and
      // the Firestore profile write then failed. Telling someone who is
      // registering that we could not sign them in describes the wrong step and
      // sends them to the sign-in screen, where their new credentials do work.
      return 'Something went wrong. Try again in a moment.';
  }
}

/// The message for a **password reset** request, which is not a sign-in.
///
/// `authErrorMessage` cannot be reused here, and reusing it was a real leak.
/// Reset is asked for with an email address and no password, so its
/// `user-not-found` / `invalid-credential` answer rendered as *"That email and
/// password do not match. Check both and try again."* — nonsense to someone who
/// typed no password, and worse than nonsense in what it discloses.
///
/// The success wording on that screen is deliberately non-committal — "If an
/// account exists for this address, a reset link is on its way" — precisely so
/// that asking for a reset cannot be used to test whether an address is
/// registered. Reporting "no such account" in the failure branch handed the
/// attacker exactly the answer the success branch withholds.
///
/// So only failures that are about the *request* rather than about who exists
/// are reported. Everything else returns null, and the caller shows the same
/// neutral confirmation it would have shown on success.
String? passwordResetMessage(String? code) {
  switch (code) {
    case 'invalid-email':
      return 'That does not look like an email address.';

    case 'too-many-requests':
      return 'Too many attempts. Wait a few minutes before trying again.';

    case 'network-request-failed':
      return 'No connection. Check your network and try again.';

    // Includes `user-not-found` and `invalid-credential`: whether an account
    // exists is not something this screen will confirm either way.
    default:
      return null;
  }
}
