import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/points_policy.dart';

import '../core/network_errors.dart';
import '../core/wire_values.dart';

/// Reads `config/points` directly and writes it through the trusted service
/// (F3.3).
///
/// The policy is not written from the client even though an administrator is
/// the one editing it. Rules cannot express the invariant that matters — that
/// the claim award stays below the disposal award — so the write goes where
/// that check can run. The client validates too, but only to give immediate
/// feedback; the server is not trusting it.
class PointsPolicyService {
  final http.Client _client;
  final FirebaseFirestore _db;

  PointsPolicyService({http.Client? client, FirebaseFirestore? firestore})
    : _client = client ?? http.Client(),
      _db = firestore ?? FirebaseFirestore.instance;

  /// Current policy. Any signed-in user may read it — the values are visible
  /// in the app anyway, as the amount a disposal is worth.
  Future<PolicySnapshot> fetch() async {
    // Reads go straight to Firestore. Routing this harmless, read-only document
    // through the free trusted service made the editor wait for a 30–60 second
    // cold start even though the rules already allow every signed-in client to
    // read `config/points`. Writes still use the server below because validation
    // across policy fields is the trust boundary.
    try {
      final document = await _db.collection('config').doc('points').get();
      final data = Map<String, dynamic>.from(
        document.data() ?? const <String, dynamic>{},
      );

      final updatedAt = data['updatedAt'];
      if (updatedAt is Timestamp) {
        data['updatedAt'] = updatedAt.toDate().toIso8601String();
      }

      final updatedBy = data['updatedBy'];
      if (updatedBy is String && updatedBy.isNotEmpty) {
        try {
          final editor = await _db.collection('users').doc(updatedBy).get();
          final name = editor.data()?['name'];
          if (name is String && name.trim().isNotEmpty) {
            data['updatedByName'] = name;
          }
        } catch (_) {
          // Buyers may read the public policy but cannot read another user's
          // profile. The name is provenance convenience, never a reason to fail
          // checkout or the policy read.
        }
      }

      return PolicySnapshot.fromJson(data);
    } on FirebaseException catch (error) {
      _log('Firestore policy read failed', error);
      throw const PolicyException(
        'The points policy could not be read. Check your connection and try again.',
      );
    }
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

class PolicyException implements UserFacingException {
  @override
  final String message;

  /// Field-level problems returned by the server's `validate()`. Empty for
  /// transport failures.
  final List<String> problems;

  const PolicyException(this.message, {this.problems = const <String>[]});

  @override
  String toString() => message;
}
