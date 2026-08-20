import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/constants.dart';
import '../models/claim_model.dart';

import '../core/network_errors.dart';
import '../core/wire_values.dart';

/// Self-reported eco-action claims (F6.1–F6.4).
///
/// Split along the trust boundary, like disposals: the client creates a pending
/// document and reads its own history directly from Firestore, while every
/// decision goes through the trusted service. There is no `verify` call here
/// and there should not be one — claims are never auto-approved, because the
/// auto-approve lane exists only where mechanical checks can pass.
class ClaimService {
  ClaimService({http.Client? client, FirebaseFirestore? firestore})
    : _client = client ?? http.Client(),
      _db = firestore ?? FirebaseFirestore.instance;

  final http.Client _client;
  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _claims =>
      _db.collection('claims');

  // ---------------------------------------------------------------------------
  // Firestore reads and the one permitted write
  // ---------------------------------------------------------------------------

  /// Writes a pending claim and returns its document ID.
  ///
  /// `createdAt` is a server timestamp: the rules require it to equal
  /// `request.time`, so a client clock value is refused outright. The weekly
  /// quota is measured in ISO weeks, and a client that could backdate a claim
  /// could place it in a week it had not yet used.
  Future<String> createPendingClaim(ClaimModel claim) async {
    final doc = await _claims.add(<String, dynamic>{
      ...claim.toCreateJson(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return doc.id;
  }

  /// A user's own claims, newest first.
  Stream<List<ClaimModel>> watchUserClaims(String uid) => _claims
      .where('userId', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .limit(QueryLimits.ownHistory)
      .snapshots()
      .map((snap) => snap.docs.map(_fromDoc).toList());

  /// Everything awaiting a decision, oldest first.
  ///
  /// Oldest first for the same reason as the disposal queue: working newest
  /// first leaves the earliest submissions waiting longest.
  Stream<List<ClaimModel>> watchPendingClaims() => _claims
      .where('status', isEqualTo: 'pending')
      .orderBy('createdAt')
      .limit(QueryLimits.reviewQueue)
      .snapshots()
      .map((snap) => snap.docs.map(_fromDoc).toList());

  ClaimModel _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.from(doc.data() ?? <String, dynamic>{});
    for (final key in ['createdAt', 'reviewedAt']) {
      final value = data[key];
      data[key] = value is Timestamp ? value.toDate() : null;
    }
    return ClaimModel.fromJson(data, id: doc.id);
  }

  // ---------------------------------------------------------------------------
  // Server calls
  // ---------------------------------------------------------------------------

  /// The signed-in user's quota position for the current ISO week.
  Future<ClaimQuotaStatus> fetchQuota() async {
    final response = await _send(
      () async => _client
          .get(ApiConfig.path('/claims/quota'), headers: await _headers())
          .timeout(ApiConfig.coldStartTimeout),
      action: 'checking your weekly quota',
    );

    if (response.statusCode == 200) {
      final body = _decode(response.body);
      return ClaimQuotaStatus(
        weekKey: wireString(body['weekKey']) ?? '',
        approvedThisWeek: wireInt(body['approvedThisWeek']) ?? 0,
        limit: wireInt(body['limit']) ?? 3,
      );
    }

    throw ClaimException(
      _messageFor(response, 'Your quota could not be checked.'),
    );
  }

  Future<ClaimReviewOutcome> approve(String claimId) =>
      _review(claimId, decision: 'approve');

  Future<ClaimReviewOutcome> reject(String claimId, String reason) =>
      _review(claimId, decision: 'reject', reason: reason);

  Future<ClaimReviewOutcome> _review(
    String claimId, {
    required String decision,
    String? reason,
  }) async {
    final response = await _send(
      () async => _client
          .post(
            ApiConfig.path('/claims/$claimId/review'),
            headers: await _headers(),
            body: jsonEncode({'decision': decision, 'reason': ?reason}),
          )
          .timeout(ApiConfig.coldStartTimeout),
      action: 'recording the decision',
    );

    final body = _decode(response.body);

    if (response.statusCode == 200) {
      return ClaimReviewOutcome(
        claimId: claimId,
        status: wireString(body['status']) ?? 'unknown',
        pointsAwarded: wireInt(body['pointsAwarded']),
        balanceAfter: wireInt(body['balanceAfter']),
      );
    }

    // A 409 carries a message written for an administrator: already decided,
    // quota exhausted, no wallet. Surface it verbatim.
    throw ClaimException(
      wireString(body['message']) ??
          'The decision could not be recorded (${response.statusCode}).',
    );
  }

  Future<Map<String, String>> _headers() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw const ClaimException('You are not signed in.');
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
      throw ClaimException(slowServerMessage);
    } on SocketException catch (error) {
      _log('socket failure $action', error);
      throw ClaimException(unreachableServerMessage);
    } on http.ClientException catch (error) {
      _log('client exception $action — on web, check CORS', error);
      throw ClaimException(unreachableServerMessage);
    } on ClaimException {
      rethrow;
    } catch (error, stackTrace) {
      _log('unexpected failure $action', error, stackTrace);
      throw ClaimException('Something went wrong $action. Try again.');
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
    final message = wireString(_decode(response.body)['message']);
    if (message != null && message.isNotEmpty) return message;
    return '$fallback (${response.statusCode})';
  }
}

/// A user's quota position for the current ISO week (F6.4).
///
/// Distinct from `ClaimQuota` in the model, which is a static ISO-week key
/// helper mirroring the server's `isoWeekKey`. This is the server's answer
/// about a particular person right now.
class ClaimQuotaStatus {
  const ClaimQuotaStatus({
    required this.weekKey,
    required this.approvedThisWeek,
    required this.limit,
  });

  final String weekKey;
  final int approvedThisWeek;
  final int limit;

  int get remaining {
    final left = limit - approvedThisWeek;
    return left < 0 ? 0 : left;
  }

  bool get isExhausted => remaining == 0;

  String get summary {
    if (isExhausted) return 'You have used all $limit claims for this week.';
    return remaining == 1
        ? '1 claim left this week.'
        : '$remaining claims left this week.';
  }
}

class ClaimReviewOutcome {
  const ClaimReviewOutcome({
    required this.claimId,
    required this.status,
    this.pointsAwarded,
    this.balanceAfter,
  });

  final String claimId;
  final String status;
  final int? pointsAwarded;
  final int? balanceAfter;
}

void _log(String context, Object error, [StackTrace? stackTrace]) {
  if (!kDebugMode) return;
  debugPrint('[ClaimService] $context: $error');
  if (stackTrace != null) debugPrint('$stackTrace');
}

class ClaimException implements Exception {
  final String message;
  const ClaimException(this.message);

  @override
  String toString() => message;
}
