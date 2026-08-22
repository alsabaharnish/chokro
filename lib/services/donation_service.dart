import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/network_errors.dart';
import '../core/wire_values.dart';
import '../models/donation_model.dart';

/// Sends point donations to the trusted service.
///
/// There is intentionally no Firestore write here. A donation debits a wallet,
/// and only the server can move a balance and write its matching ledger entry.
class DonationService {
  DonationService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<DonationOutcome> donate({
    required String donationId,
    required GreenInitiative initiative,
    required int points,
  }) async {
    final response = await _send(
      () async => _client
          .post(
            ApiConfig.path('/donations'),
            headers: await _headers(),
            body: jsonEncode({
              'donationId': donationId,
              'initiative': initiative.wireValue,
              'points': points,
            }),
          )
          .timeout(ApiConfig.coldStartTimeout),
    );
    final body = _decode(response.body);

    if (response.statusCode == 200 || response.statusCode == 201) {
      final receiptId = wireString(body['donationId']);
      final receiptInitiative = wireString(body['initiative']);
      final receiptPoints = wireInt(body['points']);
      final balanceAfter = wireInt(body['balanceAfter']);
      if (receiptId == null ||
          receiptId != donationId ||
          receiptInitiative != initiative.wireValue ||
          receiptPoints == null ||
          receiptPoints != points ||
          balanceAfter == null ||
          balanceAfter < 0) {
        // A successful HTTP status without a complete matching receipt is
        // ambiguous: the debit may have committed before a proxy damaged the
        // response. The controller retains this request's idempotency key, so
        // retrying safely retrieves the same receipt instead of charging twice.
        throw const DonationException(
          'The server did not return a valid donation receipt. Try the same '
          'donation again; it will not debit your points twice.',
        );
      }
      return DonationOutcome(
        donationId: receiptId,
        initiative: initiative,
        points: receiptPoints,
        balanceAfter: balanceAfter,
      );
    }

    throw DonationException(
      wireString(body['message']) ??
          'The donation could not be completed. No points were taken.',
    );
  }

  Future<Map<String, String>> _headers() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const DonationException('You are not signed in.');
    }
    final token = await user.getIdToken();
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  Future<http.Response> _send(Future<http.Response> Function() request) async {
    try {
      return await request();
    } on TimeoutException catch (error) {
      _log('request timed out', error);
      throw const DonationException(slowServerMessage);
    } on http.ClientException catch (error) {
      _log('request failed — on web, check CORS', error);
      throw DonationException(unreachableServerMessage);
    } on DonationException {
      rethrow;
    } catch (error, stackTrace) {
      _log('unexpected request failure', error, stackTrace);
      throw const DonationException(
        'The donation could not be completed. No points were taken.',
      );
    }
  }

  Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (error) {
      _log('response was not JSON', error);
      return <String, dynamic>{};
    }
  }
}

void _log(String context, Object error, [StackTrace? stackTrace]) {
  if (!kDebugMode) return;
  debugPrint('[DonationService] $context: $error');
  if (stackTrace != null) debugPrint('$stackTrace');
}

class DonationException implements Exception {
  const DonationException(this.message);

  final String message;

  @override
  String toString() => message;
}
