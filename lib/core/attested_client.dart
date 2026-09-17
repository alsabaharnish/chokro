/// The HTTP client every call to the trusted service goes through (SEC-10,
/// NFR-E-9).
///
/// ## What App Check adds that authentication does not
///
/// An ID token proves **who** is asking. It says nothing about **what** is
/// asking, so every endpoint on the service accepts traffic from anything
/// holding a valid token — a browser console, a curl loop, a script somebody
/// wrote after reading the Flutter web bundle. App Check attests that the
/// request came from a build this project published.
///
/// The producer portal is where that stops being deferrable. A corporate
/// compliance dataset behind nothing but a rate limit is a dataset with a
/// download schedule attached to it.
///
/// ## Why a client wrapper rather than a header at each call site
///
/// Nineteen places construct an HTTP client and eighteen build their own
/// `Authorization` header. Adding one more header to each of them would be
/// eighteen chances to miss one, and a single missed call site is not a
/// cosmetic defect once enforcement is on — it is an endpoint that 401s for
/// every real user while passing every test that injects a fake client.
///
/// The drift is not hypothetical. The Admin "Their view" tab shipped broken
/// for a release because one call site used GET where the server expected
/// POST, and nothing common existed to check it against.
///
/// So the attestation lives where the requests already converge: a
/// [http.BaseClient] whose [send] adds the header. Services keep their own
/// constructors and their own auth headers, tests keep injecting fakes, and
/// there is exactly one place where a request can fail to be attested.
///
/// ## Best effort here, authoritative there
///
/// A request with no App Check token is sent WITHOUT the header rather than
/// refused locally. The client is not the right place to decide whether
/// attestation is required — the server holds `APP_CHECK_ENFORCED`, and it is
/// fail-closed once set. Refusing here as well would mean a client that cannot
/// attest is broken even against a deployment that does not require it, which
/// is precisely the situation during rollout, on an emulator, and in every
/// local run before the console steps are done.
///
/// So: attach a token when one can be had, proceed without it when it cannot,
/// and let the deployment decide. Failures are logged once, not per request —
/// a device that cannot attest cannot attest for every call, and a log line
/// per request would bury everything else.
library;

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// The header the trusted service reads (`server/src/appCheck.js`).
const String appCheckHeader = 'X-Firebase-AppCheck';

/// Fetches the current App Check token, or null when one cannot be had.
///
/// Injectable so the behaviour is testable without a Firebase binding, which a
/// unit test has no way to provide.
typedef AppCheckTokenReader = Future<String?> Function();

/// The default reader: Firebase's own, which caches internally.
///
/// Calling it per request is therefore cheap — the plugin returns a cached
/// token until it approaches expiry and only then does a round trip.
Future<String?> _firebaseAppCheckToken() =>
    FirebaseAppCheck.instance.getToken();

/// An [http.Client] that attests every request it sends.
class AttestedClient extends http.BaseClient {
  AttestedClient({http.Client? inner, AppCheckTokenReader? readToken})
    : _inner = inner ?? http.Client(),
      _readToken = readToken ?? _firebaseAppCheckToken;

  final http.Client _inner;
  final AppCheckTokenReader _readToken;

  /// Whether a token failure has already been reported.
  ///
  /// Per instance rather than global: a fake in a test starts clean, and each
  /// service's client reports its own first failure rather than one service
  /// silencing the others.
  bool _warned = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final token = await _token();
    if (token != null && token.isNotEmpty) {
      request.headers[appCheckHeader] = token;
    }
    return _inner.send(request);
  }

  Future<String?> _token() async {
    try {
      return await _readToken();
    } catch (error) {
      // Swallowed deliberately, and only after being said once.
      //
      // Every reason this throws is a condition the request itself may well
      // survive: App Check not yet initialised, a debug token not registered,
      // Play Integrity unavailable on a device without Play Services, a web
      // build whose reCAPTCHA key is not yet provisioned. Against a deployment
      // that does not enforce, all of those are fine. Against one that does,
      // the server refuses and says so — which is the honest place for that
      // refusal to come from.
      if (!_warned) {
        _warned = true;
        debugPrint(
          '[appcheck] No App Check token: $error\n'
          '[appcheck] Requests will be sent unattested. They will be REFUSED '
          'if the server has APP_CHECK_ENFORCED=true.',
        );
      }
      return null;
    }
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}
