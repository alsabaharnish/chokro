import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/points_policy.dart';

import '../core/network_errors.dart';
import '../core/wire_values.dart';

/// Reads and writes `config/points` through the trusted service (F3.3).
///
/// The policy is not written from the client even though an administrator is
/// the one editing it. Rules cannot express the invariant that matters — that
/// the claim award stays below the disposal award — so the write goes where
/// that check can run. The client validates too, but only to give immediate
/// feedback; the server is not trusting it.
class PointsPolicyService {
  final http.Client _client;

  PointsPolicyService({http.Client? client})
    : _client = client ?? http.Client();

  /// Current policy. Any signed-in user may read it — the values are visible
  /// in the app anyway, as the amount a disposal is worth.
  Future<PolicySnapshot> fetch() async {
    final response = await _send(
      () async => _client
          .get(ApiConfig.path('/config/points'), headers: await _headers())
          .timeout(ApiConfig.coldStartTimeout),
      action: 'loading the points policy',
    );

    if (response.statusCode == 200) {
      final body = _decode(response.body);
      // The provenance rides alongside the policy numbers in the same object,
      // so the editor gets both from one request (F3.3).
      return PolicySnapshot.fromJson(body);
    }

    throw PolicyException(
      _messageFor(
        response,
        'The policy could not be '
        'loaded.',
      ),
    );
  }

  /// Writes [policy] after the server revalidates it.
  ///
  /// Returns the policy as the server stored it, which is what the UI should
  /// display afterwards — not the local object, so that any server-side
  /// normalisation is visible rather than assumed away.
  ///
  /// Throws [PolicyException] with [PolicyException.problems] populated when
  /// the server rejects the values.
  Future<PointsPolicy> save(PointsPolicy policy) async {
    final response = await _send(
      () async => _client
          .post(
            ApiConfig.path('/config/points'),
            headers: await _headers(),
            body: jsonEncode(policy.toJson()),
          )
          .timeout(ApiConfig.coldStartTimeout),
      action: 'saving the points policy',
    );

    final body = _decode(response.body);

    if (response.statusCode == 200) {
      final stored = body['policy'];
      return PointsPolicy.fromJson(
        stored is Map<String, dynamic> ? stored : null,
      );
    }

    if (response.statusCode == 400 && body['error'] == 'invalid_policy') {
      final raw = body['problems'];
      final problems = raw is List
          ? raw.map((p) => '$p').toList(growable: false)
          : const <String>[];
      _log('server rejected the policy', problems.join(' | '));
      throw PolicyException(
        'The server rejected these values.',
        problems: problems,
      );
    }

    if (response.statusCode == 401 || response.statusCode == 403) {
      throw const PolicyException(
        'Only a 3ZERO Admin can change the points policy.',
      );
    }

    throw PolicyException(
      _messageFor(response, 'The policy could not be saved.'),
    );
  }

  Future<Map<String, String>> _headers() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw const PolicyException('You are not signed in.');
    }
    final token = await user.getIdToken();
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  /// Shared failure handling, so read and write report the same four causes
  /// distinctly rather than collapsing them into one message.
  Future<http.Response> _send(
    Future<http.Response> Function() request, {
    required String action,
  }) async {
    try {
      return await request();
    } on TimeoutException catch (error) {
      _log('timed out $action', error);
      throw PolicyException(slowServerMessage);
    } on SocketException catch (error) {
      _log('socket failure $action', error);
      throw PolicyException(unreachableServerMessage);
    } on http.ClientException catch (error) {
      _log('client exception $action — on web, check CORS', error);
      throw PolicyException(unreachableServerMessage);
    } on PolicyException {
      rethrow;
    } catch (error, stackTrace) {
      _log('unexpected failure $action', error, stackTrace);
      throw PolicyException('Something went wrong $action. Try again.');
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

  String _messageFor(http.Response response, String fallback) {
    final body = _decode(response.body);
    final message = wireString(body['message']);
    if (message != null && message.isNotEmpty) return message;
    return '$fallback (${response.statusCode})';
  }
}

void _log(String context, Object error, [StackTrace? stackTrace]) {
  if (!kDebugMode) return;
  debugPrint('[PointsPolicyService] $context: $error');
  if (stackTrace != null) debugPrint('$stackTrace');
}

class PolicyException implements Exception {
  final String message;

  /// Field-level problems returned by the server's `validate()`. Empty for
  /// transport failures.
  final List<String> problems;

  const PolicyException(this.message, {this.problems = const <String>[]});

  @override
  String toString() => message;
}
