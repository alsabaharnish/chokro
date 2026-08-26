/// Messages for the ways a call to the trusted service can fail to happen at
/// all.
///
/// Six services each spoke to the server and each wrote the same three
/// sentences by hand. That was survivable while the sentences were right; it
/// stopped being survivable when one of them turned out to be wrong in the same
/// way six times.
library;

import 'package:firebase_core/firebase_core.dart' show FirebaseException;
import 'package:flutter/foundation.dart' show kIsWeb;

/// What to say when the request never reached the server.
///
/// `http.ClientException` means different things on different platforms, and the
/// services were reporting only one of them.
///
/// On mobile it really is the network. On **web** it is most often CORS: the
/// browser refused the request because the response carried no
/// `Access-Control-Allow-Origin` for this page's origin. Every one of these
/// services already logged "on web, check CORS" to the debug console — and then
/// told the user to check their connection.
///
/// That cost real time: registering a bin from a local build served on a port
/// missing from the server's `ALLOWED_ORIGINS` produced "check your connection"
/// while the server was up and answering `/health` in 300 ms.
///
/// So the web wording names both possibilities without jargon. It has to stay
/// true in production, where a signed-in administrator on the hosted origin sees
/// this only if the service is genuinely down.
String get unreachableServerMessage => kIsWeb
    ? 'Could not reach the server. It may be offline, or it may be refusing '
          'requests from this address.'
    : 'Could not reach the server. Check your connection.';

/// What to say when the server was reached but took too long.
///
/// Render's free instance sleeps after about 15 minutes idle and takes 30–60
/// seconds to wake, so the first action after a quiet period can time out
/// through no fault of the user or the network.
const String slowServerMessage =
    'The server took too long to respond. It may be starting up — try again in '
    'a moment.';

/// A readable sentence for anything that reached a view's error branch.
///
/// This file was imported by six *services* and by nothing in `lib/views/`, so
/// eight screens still rendered `Text('$error')` or `error.toString()`. What that
/// puts in front of an administrator is
/// `[cloud_firestore/permission-denied] Missing or insufficient permissions.` —
/// a vendor prefix, a class name and no next step. Three of those files even
/// carried comments describing this as already fixed; the reasoning had landed
/// and the change had not.
///
/// Most of these branches receive a [FirebaseException] from a Firestore stream,
/// so the codes worth naming are named. Anything carrying its own prepared
/// message is used as-is, since the app's own exception types exist precisely to
/// hold one.
String friendlyErrorMessage(Object? error) {
  if (error == null) return 'Something went wrong.';

  if (error is FirebaseException) {
    switch (error.code) {
      case 'permission-denied':
        return 'You do not have permission to view this. If you were just '
            'signed in as someone else, try signing out and back in.';

      case 'unavailable':
      case 'deadline-exceeded':
        return 'Could not reach the database. Check your connection and try '
            'again.';

      case 'unauthenticated':
        return 'Your session has expired. Sign out and back in.';

      // A missing composite index. Named because the remedy is specific and
      // otherwise invisible: Firestore puts a create-index URL in the message,
      // which is exactly the part `$error` was burying in vendor noise.
      case 'failed-precondition':
        return 'This list needs a database index that has not been created yet. '
            'Check the server logs for the index link.';

      case 'not-found':
        return 'That is no longer there. It may have been removed.';

      case 'resource-exhausted':
        return 'The database is over quota. Try again later.';

      default:
        return 'Something went wrong loading this. Try again.';
    }
  }

  // The app's own exception types (AuthFailure, PolicyException,
  // ClaimException, BinAdminException…) all carry a message written to be
  // shown, and all override toString to return it.
  //
  // Recognised by opting in, not by blocklist. This used to return
  // `error.toString()` for anything that did not start with `Instance of` or a
  // bracketed vendor prefix — which meant every plain `StateError` and
  // `Exception` in the codebase went to the user verbatim. A Champion whose
  // session had lapsed mid-appeal read "The appeal could not be sent. Bad
  // state: Not signed in."; an applicant with one already pending read
  // "Exception: A Greenpreneur application is already pending." Dart's
  // `toString()` prefixes are not sentences, and the set of exception types
  // reaching here is open-ended, so a blocklist can only ever be behind.
  if (error is UserFacingException) return error.message;

  return 'Something went wrong. Try again.';
}

/// Marks an exception whose `message` was written to be read by a user.
///
/// Implemented by the app's own failure types so [friendlyErrorMessage] can
/// recognise them by intent rather than by guessing from the shape of a
/// `toString()`. Anything that does not implement this is treated as internal
/// and replaced with a general sentence.
abstract interface class UserFacingException implements Exception {
  String get message;
}
