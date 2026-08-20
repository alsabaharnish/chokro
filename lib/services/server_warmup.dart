import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';

/// Wakes the trusted service in the background at app start.
///
/// ## Why this exists
///
/// The service runs on Render's free tier, which suspends the instance after
/// about fifteen minutes idle and takes 30–60 seconds to bring it back. Nothing
/// about that is a fault, but the *first* call after a quiet period pays the
/// whole cost — and in this app the first call is usually something the user is
/// staring at: the points policy behind the checkout screen, or a bin
/// registration.
///
/// The symptom is severe out of proportion to the cause. Every server call
/// allows [ApiConfig.coldStartTimeout] — ninety seconds — so a sleeping instance
/// looked exactly like a broken feature, and the honest error arrived long after
/// the user had given up. The project brief already says to warm the service
/// before demonstrating; this does it automatically, on every launch, so nobody
/// has to remember.
///
/// ## Why `/health` and why nothing is awaited
///
/// `/health` requires no authentication and touches no Firestore, so it can run
/// before anyone signs in — which is the point, since the wake-up then overlaps
/// with the user typing their password rather than with their first real
/// request.
///
/// Every failure is swallowed. This is an optimisation: if the service is down,
/// the screen that actually needs it will say so with a message written for that
/// screen. Reporting it here would put an error in front of someone who has not
/// asked for anything yet.
class ServerWarmup {
  const ServerWarmup._();

  /// How long to wait before giving up on the ping.
  ///
  /// Deliberately shorter than [ApiConfig.coldStartTimeout]: this call exists to
  /// *start* the wake-up, and Render continues booting the instance whether or
  /// not this particular request is still listening. Holding a socket open for
  /// ninety seconds to learn something nobody is waiting for is pure cost.
  static const Duration _timeout = Duration(seconds: 30);

  /// Fire-and-forget. Never throws, never blocks the caller.
  static void ping({http.Client? client}) {
    unawaited(_ping(client ?? http.Client()));
  }

  static Future<void> _ping(http.Client client) async {
    final started = DateTime.now();
    try {
      final response = await client
          .get(ApiConfig.path('/health'))
          .timeout(_timeout);

      if (kDebugMode) {
        final ms = DateTime.now().difference(started).inMilliseconds;
        debugPrint(
          '[warmup] ${ApiConfig.baseUrl} responded ${response.statusCode} '
          'in ${ms}ms',
        );
      }
    } catch (error) {
      // Swallowed on purpose — see the class comment. Logged in debug only,
      // because a failure here is the first hint that the service is
      // unreachable and that is worth seeing while developing.
      if (kDebugMode) {
        debugPrint('[warmup] ${ApiConfig.baseUrl} unreachable: $error');
      }
    } finally {
      client.close();
    }
  }
}
