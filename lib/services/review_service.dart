import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';

/// Administrator decisions on pending submissions (F2.8).
///
/// The approve button calls the trusted service; it does not write Firestore.
/// Rules deny an administrator every write to `wallets`, `transactions` and
/// `disposals` — see `rules_test/m2.rules.test.js`, which has a test named
/// exactly that. There is one code path that credits a wallet, and this is how
/// the UI reaches it.
class ReviewService {
  final http.Client _client;

  ReviewService({http.Client? client}) : _client = client ?? http.Client();

  Future<ReviewOutcome> approve(String disposalId) =>
      _review(disposalId, decision: 'approve');

  Future<ReviewOutcome> reject(String disposalId, String reason) =>
      _review(disposalId, decision: 'reject', reason: reason);

  Future<ReviewOutcome> _review(
    String disposalId, {
    required String decision,
    String? reason,
  }) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const ReviewException('You are not signed in.');
    }

    final token = await user.getIdToken();

    http.Response response;
    try {
      response = await _client
          .post(
            ApiConfig.path('/disposals/$disposalId/review'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({'decision': decision, 'reason': ?reason}),
          )
          .timeout(ApiConfig.coldStartTimeout);
    } on TimeoutException catch (error) {
      // The genuine cold start. Only this clause should say "took too long".
      //
      // Worth knowing when this fires on an approval: the request may still
      // have reached the server and been applied. `award.js` is transactional
      // and the endpoint refuses a second decision with a 409, so retrying is
      // safe — a duplicate credit is not possible.
      _log('timed out after ${ApiConfig.coldStartTimeout}', error);
      throw const ReviewException(
        'The server took too long to respond. It may be starting up — try '
        'again in a moment.',
      );
    } on SocketException catch (error) {
      _log('socket failure — no route to the host', error);
      throw const ReviewException(
        'Could not reach the server. Check your connection.',
      );
    } on http.ClientException catch (error) {
      // The review queue is web-primary, so this is the clause that matters
      // here. A CORS rejection arrives as a ClientException with no detail —
      // not as a SocketException — which is why it used to be reported as a
      // timeout. Run the web build on an origin listed in ALLOWED_ORIGINS.
      _log('client exception — on web, check CORS and the origin', error);
      throw const ReviewException(
        'Could not reach the server. Check your connection.',
      );
    } catch (error, stackTrace) {
      _log('unexpected failure recording the decision', error, stackTrace);
      throw const ReviewException(
        'Something went wrong recording the decision. Try again.',
      );
    }

    final body = _decode(response.body);

    if (response.statusCode == 200) {
      return ReviewOutcome(
        disposalId: disposalId,
        status: body['status'] as String? ?? 'unknown',
        pointsAwarded: body['pointsAwarded'] as int?,
        balanceAfter: body['balanceAfter'] as int?,
      );
    }

    // 409 carries a message written for an administrator to read — already
    // decided, daily cap reached, no wallet. Surface it verbatim.
    final message =
        body['message'] as String? ??
        'The decision could not be recorded (${response.statusCode}).';
    _log('server refused the decision (${response.statusCode})', message);
    throw ReviewException(message);
  }

  Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (error) {
      _log('response body was not JSON', error);
      return <String, dynamic>{};
    }
  }
}

/// Writes the underlying failure to the debug console without changing what the
/// administrator is told. Stripped from release builds.
void _log(String context, Object error, [StackTrace? stackTrace]) {
  if (!kDebugMode) return;
  debugPrint('[ReviewService] $context: $error');
  if (stackTrace != null) debugPrint('$stackTrace');
}

class ReviewOutcome {
  final String disposalId;
  final String status;
  final int? pointsAwarded;
  final int? balanceAfter;

  const ReviewOutcome({
    required this.disposalId,
    required this.status,
    this.pointsAwarded,
    this.balanceAfter,
  });
}

class ReviewException implements Exception {
  final String message;
  const ReviewException(this.message);

  @override
  String toString() => message;
}
