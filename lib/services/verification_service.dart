import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';

/// Asks the trusted service to verify a pending submission (F2.5, F2.12).
///
/// The submission already exists as a `pending` document before this is called.
/// That ordering matters: the document is the record, and this call only
/// decides whether it can be credited immediately or needs a person. **A failed
/// verification is not a failed submission** — the document stands, the admin
/// queue will show it, and the user's history already lists it.
///
/// So every failure here returns a [VerificationOutcome] describing the pending
/// state rather than throwing. The one thing this must never do is leave the
/// user believing their submission was lost when it was not.
class VerificationService {
  final http.Client _client;

  VerificationService({http.Client? client})
      : _client = client ?? http.Client();

  Future<VerificationOutcome> verify(String disposalId) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      return VerificationOutcome.pending(
        disposalId,
        note: 'Not signed in; the submission will be reviewed.',
      );
    }

    try {
      final token = await user.getIdToken();
      final response = await _client
          .post(
            ApiConfig.path('/disposals/$disposalId/verify'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
          )
          .timeout(ApiConfig.coldStartTimeout);

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        if (body is Map<String, dynamic>) {
          return VerificationOutcome.fromJson(disposalId, body);
        }
      }

      _log('verify returned ${response.statusCode}', response.body);
      return VerificationOutcome.pending(disposalId);
    } on TimeoutException catch (error) {
      // The server may well have finished the work and credited the award —
      // the response was simply lost. Saying "pending" is the honest answer,
      // and the history screen will show the real outcome when it syncs.
      _log('verify timed out', error);
      return VerificationOutcome.pending(
        disposalId,
        note: 'The server is taking a while. Check your history shortly.',
      );
    } on SocketException catch (error) {
      _log('verify socket failure', error);
      return VerificationOutcome.pending(disposalId);
    } on http.ClientException catch (error) {
      _log('verify client exception — on web, check CORS', error);
      return VerificationOutcome.pending(disposalId);
    } catch (error, stackTrace) {
      _log('verify failed unexpectedly', error, stackTrace);
      return VerificationOutcome.pending(disposalId);
    }
  }
}

/// What the server decided, or the pending fallback when it could not be asked.
class VerificationOutcome {
  const VerificationOutcome({
    required this.disposalId,
    required this.status,
    this.pointsAwarded = 0,
    this.balanceAfter,
    this.flags = const <String>[],
    this.reasons = const <String>[],
    this.note,
  });

  /// The fallback. Matches the document's real state: it was created pending
  /// and nothing has changed it.
  factory VerificationOutcome.pending(String disposalId, {String? note}) {
    return VerificationOutcome(
      disposalId: disposalId,
      status: 'pending',
      note: note,
    );
  }

  factory VerificationOutcome.fromJson(
    String disposalId,
    Map<String, dynamic> json,
  ) {
    final rawFlags = json['flags'];
    final rawReasons = json['reasons'];

    return VerificationOutcome(
      disposalId: disposalId,
      status: (json['status'] as String?) ?? 'pending',
      pointsAwarded: (json['pointsAwarded'] as num?)?.toInt() ?? 0,
      balanceAfter: (json['balanceAfter'] as num?)?.toInt(),
      flags: rawFlags is List
          ? rawFlags.map((f) => '$f').toList(growable: false)
          : const <String>[],
      reasons: rawReasons is List
          ? rawReasons.map((r) => '$r').toList(growable: false)
          : const <String>[],
    );
  }

  final String disposalId;
  final String status;
  final int pointsAwarded;
  final int? balanceAfter;
  final List<String> flags;
  final List<String> reasons;

  /// Extra context for the user when the outcome is the pending fallback.
  final String? note;

  bool get wasAutoApproved => status == 'autoApproved';
  bool get needsReview => status == 'pending';

  /// One line for the confirmation screen.
  String get userMessage {
    if (wasAutoApproved) {
      return 'Approved — $pointsAwarded points added to your wallet.';
    }
    if (note != null) return note!;
    if (reasons.isNotEmpty) {
      return 'Sent for review: ${reasons.first}';
    }
    return 'Submitted. A reviewer will check this shortly.';
  }
}

void _log(String context, Object error, [StackTrace? stackTrace]) {
  if (!kDebugMode) return;
  debugPrint('[VerificationService] $context: $error');
  if (stackTrace != null) debugPrint('$stackTrace');
}
