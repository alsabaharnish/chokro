import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
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
    } on SocketException {
      throw const ReviewException(
        'Could not reach the server. Check your connection.',
      );
    } catch (_) {
      throw const ReviewException(
        'The server took too long to respond. Try again in a moment.',
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
    throw ReviewException(message);
  }

  Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }
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
