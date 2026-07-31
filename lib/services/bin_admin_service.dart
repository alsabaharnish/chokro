import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../models/bin_model.dart';

/// Bin registration through the trusted service (F2.1).
///
/// Separate from [BinService], which reads bins from Firestore directly. The
/// split follows the trust boundary: reading a bin is a plain query the rules
/// allow, while creating one writes coordinates this service later trusts when
/// deciding a payout, so it goes through the server like every other write that
/// feeds a decision.
class BinAdminService {
  final http.Client _client;

  BinAdminService({http.Client? client}) : _client = client ?? http.Client();

  /// Registers a bin and returns it, including the server-generated id and QR
  /// payload.
  ///
  /// Throws [BinAdminException], carrying `problems` when the server's
  /// validation refused the values.
  Future<BinModel> createBin({
    required String label,
    required double lat,
    required double lng,
    required double radiusMeters,
  }) async {
    final response = await _send(
      () async => _client
          .post(
            ApiConfig.path('/bins'),
            headers: await _headers(),
            body: jsonEncode({
              'label': label,
              'lat': lat,
              'lng': lng,
              'radiusMeters': radiusMeters,
            }),
          )
          .timeout(ApiConfig.coldStartTimeout),
      action: 'registering the bin',
    );

    final body = _decode(response.body);

    if (response.statusCode == 200 || response.statusCode == 201) {
      final bin = body['bin'];
      if (bin is Map<String, dynamic>) {
        return BinModel.fromJson(bin, id: bin['id'] as String?);
      }
      throw const BinAdminException('The server did not return the new bin.');
    }

    if (response.statusCode == 400 && body['error'] == 'invalid_bin') {
      final raw = body['problems'];
      final problems = raw is List
          ? raw.map((p) => '$p').toList(growable: false)
          : const <String>[];
      throw BinAdminException(
        'The server rejected these values.',
        problems: problems,
      );
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const BinAdminException(
        'Only an administrator can register a bin.',
      );
    }

    throw BinAdminException(
      (body['message'] as String?) ??
          'The bin could not be registered (${response.statusCode}).',
    );
  }

  /// Takes a bin in or out of service. Bins are never deleted — past disposals
  /// reference them.
  Future<void> setActive({required String binId, required bool active}) async {
    final response = await _send(
      () async => _client
          .post(
            ApiConfig.path('/bins/$binId/active'),
            headers: await _headers(),
            body: jsonEncode({'active': active}),
          )
          .timeout(ApiConfig.coldStartTimeout),
      action: active ? 'reopening the bin' : 'closing the bin',
    );

    if (response.statusCode == 200) return;

    final body = _decode(response.body);
    throw BinAdminException(
      (body['message'] as String?) ??
          'The change could not be saved (${response.statusCode}).',
    );
  }

  Future<Map<String, String>> _headers() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const BinAdminException('You are not signed in.');
    }
    final token = await user.getIdToken();
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  Future<http.Response> _send(
    Future<http.Response> Function() request, {
    required String action,
  }) async {
    try {
      return await request();
    } on TimeoutException catch (error) {
      _log('timed out $action', error);
      throw const BinAdminException(
        'The server took too long to respond. It may be starting up — try '
        'again in a moment.',
      );
    } on SocketException catch (error) {
      _log('socket failure $action', error);
      throw const BinAdminException(
        'Could not reach the server. Check your connection.',
      );
    } on http.ClientException catch (error) {
      _log('client exception $action — on web, check CORS', error);
      throw const BinAdminException(
        'Could not reach the server. Check your connection.',
      );
    } on BinAdminException {
      rethrow;
    } catch (error, stackTrace) {
      _log('unexpected failure $action', error, stackTrace);
      throw BinAdminException('Something went wrong $action. Try again.');
    }
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

void _log(String context, Object error, [StackTrace? stackTrace]) {
  if (!kDebugMode) return;
  debugPrint('[BinAdminService] $context: $error');
  if (stackTrace != null) debugPrint('$stackTrace');
}

class BinAdminException implements Exception {
  final String message;
  final List<String> problems;

  const BinAdminException(this.message, {this.problems = const <String>[]});

  @override
  String toString() => message;
}
