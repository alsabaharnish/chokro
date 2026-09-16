import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/network_errors.dart';
import '../models/admin_oversight_model.dart';
import 'organization_service.dart' show OrgActionException;

/// The Admin oversight surfaces (EPR-43 to EPR-48).
///
/// ## Why this is one service rather than six
///
/// Every route here shares the same guard on the server (`requireAdmin`), the
/// same failure vocabulary, and the same reason: Chokro checking its own work.
/// Splitting them by requirement would produce six near-identical classes whose
/// `_headers` implementations would drift, which is the fate
/// `organization_service.dart` already documents for the eight hand-written
/// cards that became `ActionCard`.
///
/// ## Reads return a typed failure; writes throw
///
/// The same split `OrganizationService` makes, and for the same reason. A
/// console that cannot load its queue should say what went wrong; an Admin who
/// pressed "dismiss" and had it silently fail would believe the finding was
/// closed. The second case is the one that matters here — every write on these
/// surfaces is an override with a recorded reason, and a silent failure would
/// leave the reason recorded nowhere.
///
/// ## Nothing here computes a compliance figure
///
/// Every percentage, mass and variance is parsed from the server and rendered.
/// The client does not derive one, and where the server sends null this passes
/// the null through with the server's stated reason — see
/// `admin_oversight_model.dart`.
class AdminOversightService {
  AdminOversightService({http.Client? client, FirebaseAuth? auth})
    : _client = client ?? http.Client(),
      _auth = auth ?? FirebaseAuth.instance;

  final http.Client _client;
  final FirebaseAuth _auth;

  Future<Map<String, String>> _headers() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw const OrgActionException(
        'Sign in to continue.',
        code: 'unauthenticated',
      );
    }
    final token = await user.getIdToken();
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  Future<http.Response> _authedGet(String path) async => _client
      .get(ApiConfig.path(path), headers: await _headers())
      .timeout(ApiConfig.coldStartTimeout);

  Future<http.Response> _authedPost(String path, [Map<String, dynamic>? body]) async =>
      _client
          .post(
            ApiConfig.path(path),
            headers: await _headers(),
            body: jsonEncode(body ?? const <String, dynamic>{}),
          )
          .timeout(ApiConfig.coldStartTimeout);

  // -------------------------------------------------------------------------
  // The anomaly queue (EPR-45)
  // -------------------------------------------------------------------------

  /// The queue, by status.
  ///
  /// Sorted worst-first here rather than on the server, because ordering is a
  /// presentation decision and the server's own ordering is by first-seen —
  /// which is what a re-scan must not disturb.
  Future<List<AnomalyFinding>> listAnomalies({
    String status = AnomalyStatus.open,
    String? orgId,
  }) async {
    final query = orgId == null || orgId.isEmpty
        ? '?status=$status'
        : '?status=$status&orgId=$orgId';
    final response = await _authedGet('/epr/admin/anomalies$query');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final rows = body is Map<String, dynamic> ? body['anomalies'] : null;
    if (rows is! List) return const <AnomalyFinding>[];

    final findings = rows
        .whereType<Map<String, dynamic>>()
        .map(AnomalyFinding.fromJson)
        .toList();

    findings.sort((a, b) {
      final bySeverity = AnomalySeverity.rank(a.severity)
          .compareTo(AnomalySeverity.rank(b.severity));
      if (bySeverity != 0) return bySeverity;
      // Then oldest first within a severity: a finding that has been open
      // longest is the one most overdue a decision.
      final aSeen = a.firstSeenAt;
      final bSeen = b.firstSeenAt;
      if (aSeen == null || bSeen == null) return 0;
      return aSeen.compareTo(bSeen);
    });

    return findings;
  }

  /// Runs a scan over one organisation and period.
  ///
  /// Returns how many findings were created and how many refreshed, because a
  /// scan that produced nothing new is a meaningfully different outcome from
  /// one that produced nothing at all.
  Future<AnomalyScanResult> scanForAnomalies({
    required String orgId,
    required String periodId,
  }) async {
    final response =
        await _authedPost('/epr/admin/anomalies/$orgId/$periodId/scan');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final map = body is Map<String, dynamic> ? body : const <String, dynamic>{};
    return AnomalyScanResult(
      attributionsExamined: _int(map['attributionsExamined']),
      findings: _int(map['findings']),
      created: _int(map['created']),
      updated: _int(map['updated']),
    );
  }

  /// Closes a finding, with a reason.
  ///
  /// `outcome` distinguishes "this had an innocent explanation" from "this was
  /// real and something was done". Collapsing them would make the queue's own
  /// history useless for the question an auditor asks — how many of these
  /// turned out to be real.
  Future<void> closeAnomaly({
    required String id,
    required String reason,
    required String outcome,
  }) async {
    final response = await _authedPost(
      '/epr/admin/anomalies/$id/close',
      {'reason': reason, 'outcome': outcome},
    );
    if (response.statusCode != 200) throw _exceptionFor(response);
  }

  // -------------------------------------------------------------------------
  // Reconciliation (EPR-48)
  // -------------------------------------------------------------------------

  Future<ReconciliationOverview> loadReconciliation() async {
    final response = await _authedGet('/epr/admin/reconciliation');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    return ReconciliationOverview.fromJson(
      body is Map<String, dynamic> ? body : const <String, dynamic>{},
    );
  }

  Future<List<ReconciliationRow>> loadOrganizationReconciliation(String orgId) async {
    final response = await _authedGet('/epr/admin/reconciliation/$orgId');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final rows = body is Map<String, dynamic> ? body['periods'] : null;
    if (rows is! List) return const <ReconciliationRow>[];

    return rows
        .whereType<Map<String, dynamic>>()
        .map((row) => ReconciliationRow.fromJson({...row, 'orgId': orgId}))
        .toList(growable: false);
  }

  /// Triggers a recompute of one period.
  ///
  /// Resumable on the server, so a large period may need more than one call.
  /// The returned cursor says whether there is more; a console that ignored it
  /// would report a partial recompute as a complete one.
  Future<RecomputeResult> recompute({
    required String orgId,
    required String periodId,
    String? cursor,
  }) async {
    final response = await _authedPost(
      '/epr/admin/periods/$orgId/$periodId/recompute',
      {'cursor': ?cursor},
    );
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final map = body is Map<String, dynamic> ? body : const <String, dynamic>{};
    return RecomputeResult(
      complete: map['cursor'] == null,
      cursor: map['cursor'] is String ? map['cursor'] as String : null,
      incrementedMassMg: _int(map['incrementedMassMg']),
      recomputedMassMg: _int(map['recomputedMassMg']),
      variance: _int(map['variance']),
      matched: map['matched'] == true,
    );
  }

  // -------------------------------------------------------------------------
  // The accuracy audit (EPR-17)
  // -------------------------------------------------------------------------

  Future<List<SampledMatch>> loadAccuracyQueue({String? reason}) async {
    final query = reason == null || reason.isEmpty ? '' : '?reason=$reason';
    final response = await _authedGet('/epr/admin/accuracy-queue$query');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final rows = body is Map<String, dynamic> ? body['pending'] : null;
    if (rows is! List) return const <SampledMatch>[];

    return rows
        .whereType<Map<String, dynamic>>()
        .map(SampledMatch.fromJson)
        .toList(growable: false);
  }

  /// Records a verdict on a sampled match.
  ///
  /// A verdict is evidence about the model, NOT a correction: marking a match
  /// incorrect does not reverse the attribution. Reversal is its own act, with
  /// its own reason — and the console says so beside this button rather than
  /// leaving a reviewer to assume.
  Future<void> reviewSampledMatch({
    required String confirmationId,
    required String verdict,
    String note = '',
  }) async {
    final response = await _authedPost(
      '/epr/admin/accuracy-queue/$confirmationId',
      {'verdict': verdict, 'note': note},
    );
    if (response.statusCode != 200) throw _exceptionFor(response);
  }

  Future<AccuracySnapshot> loadAccuracy(String periodId) async {
    final response = await _authedGet('/epr/admin/accuracy/$periodId');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    return AccuracySnapshot.fromJson(
      body is Map<String, dynamic> ? body : const <String, dynamic>{},
    );
  }

  // -------------------------------------------------------------------------
  // The issuance register (EPR-47)
  // -------------------------------------------------------------------------

  Future<IssuanceRegister> loadIssuance({String? status, String? periodId}) async {
    final parts = <String>[
      if (status != null && status.isNotEmpty) 'status=$status',
      if (periodId != null && periodId.isNotEmpty) 'periodId=$periodId',
    ];
    final query = parts.isEmpty ? '' : '?${parts.join('&')}';

    final response = await _authedGet('/epr/admin/issuance$query');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    return IssuanceRegister.fromJson(
      body is Map<String, dynamic> ? body : const <String, dynamic>{},
    );
  }

  /// Withdraws every standing certificate for one organisation and period.
  ///
  /// Supersession, not revocation. The distinction is not cosmetic: superseding
  /// says the figures have moved on, revoking says the certificate should never
  /// have been relied on — and a recognition fault is the first.
  Future<int> supersedeIssuance({
    required String orgId,
    required String periodId,
    required String reason,
  }) async {
    final response = await _authedPost(
      '/epr/admin/issuance/$orgId/$periodId/supersede',
      {'reason': reason},
    );
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    return body is Map<String, dynamic> ? _int(body['superseded']) : 0;
  }

  Future<void> revokeCertificate({
    required String serial,
    required String reason,
  }) async {
    final response = await _authedPost(
      '/epr/admin/passports/$serial/revoke',
      {'reason': reason},
    );
    if (response.statusCode != 200) throw _exceptionFor(response);
  }

  Future<String> issueCertificate({
    required String orgId,
    required String periodId,
  }) async {
    final response =
        await _authedPost('/epr/admin/passports/$orgId/$periodId/issue');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    return body is Map<String, dynamic> && body['serial'] is String
        ? body['serial'] as String
        : '';
  }

  // -------------------------------------------------------------------------
  // The declaration review queue (EPR-43)
  // -------------------------------------------------------------------------

  Future<List<DeclarationReviewRow>> loadDeclarationReview() async {
    final response = await _authedGet('/epr/admin/declarations/review');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final rows = body is Map<String, dynamic> ? body['declarations'] : null;
    if (rows is! List) return const <DeclarationReviewRow>[];

    final parsed = rows
        .whereType<Map<String, dynamic>>()
        .map(DeclarationReviewRow.fromJson)
        .toList();

    // Flagged first. The server decides WHAT is flagged; this decides what an
    // Admin sees at the top, which is a different question.
    parsed.sort((a, b) {
      if (a.flagged != b.flagged) return a.flagged ? -1 : 1;
      return b.periodId.compareTo(a.periodId);
    });

    return parsed;
  }

  // -------------------------------------------------------------------------
  // View as organisation, and the timeline (EPR-44, EPR-46)
  // -------------------------------------------------------------------------

  /// Opens the read-only producer view. The server records it before assembling.
  ///
  /// A typed failure rather than a throw, because the screen must be able to
  /// say WHY — and the most likely why is the one that matters: the view could
  /// not be recorded, so it was not opened.
  Future<OrganizationViewResult> viewAsOrganization({
    required String orgId,
    String? periodId,
  }) async {
    try {
      final query = periodId == null || periodId.isEmpty
          ? ''
          : '?periodId=$periodId';
      final response =
          await _authedGet('/epr/admin/organizations/$orgId/view$query');

      if (response.statusCode != 200) {
        return OrganizationViewResult.failed(_messageFor(response));
      }

      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) {
        return OrganizationViewResult.failed('The view could not be read.');
      }

      final view = OrganizationView.fromJson(body);

      // THE CHECK THIS RESULT TYPE EXISTS FOR.
      //
      // EPR-46: no Admin action is ever taken under a producer's identity. If a
      // future server change ever sent a writable payload down this route, the
      // screen must refuse rather than quietly render a write affordance.
      // Asserted here, once, rather than trusted at every widget.
      if (!view.isSafeReadOnlyView) {
        return OrganizationViewResult.failed(
          'This view came back without its read-only guarantee, so it was not '
          'opened. No Admin action may be taken under a producer’s identity.',
        );
      }

      return OrganizationViewResult(view: view);
    } catch (error, stackTrace) {
      _log('view-as failed', error, stackTrace);
      return OrganizationViewResult.failed(friendlyErrorMessage(error));
    }
  }

  /// One organisation's chronological history.
  ///
  /// `verify` walks the whole hash chain, which a list refreshing on screen
  /// should not pay for and an export should.
  Future<ActivityTimeline> loadTimeline({
    required String orgId,
    bool verify = false,
  }) async {
    final response = await _authedGet(
      '/epr/admin/organizations/$orgId/timeline${verify ? '?verify=true' : ''}',
    );
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    return ActivityTimeline.fromJson(
      body is Map<String, dynamic> ? body : const <String, dynamic>{},
    );
  }

  // -------------------------------------------------------------------------
  // Failures
  // -------------------------------------------------------------------------

  OrgActionException _exceptionFor(http.Response response) {
    String? code;
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic> && body['error'] is String) {
        code = body['error'] as String;
      }
    } catch (_) {
      // A non-JSON body from a proxy or a cold start.
    }
    return OrgActionException(_messageFor(response), code: code);
  }

  String _messageFor(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        final message = body['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    } catch (_) {
      // Fall through to the generic sentence rather than showing raw HTML.
    }
    return switch (response.statusCode) {
      401 => 'Sign in to continue.',
      403 => 'You do not have permission to do that.',
      404 => 'That record no longer exists.',
      409 => 'That has already been done.',
      422 => 'That cannot be produced as things stand.',
      429 => 'Too many attempts. Wait a minute and try again.',
      503 => 'The service is waking up. Try again in a moment.',
      _ => 'That action could not be completed.',
    };
  }

  void _log(String what, Object error, StackTrace stackTrace) {
    if (kDebugMode) {
      debugPrint('[admin-oversight] $what: $error');
      debugPrintStack(stackTrace: stackTrace, maxFrames: 6);
    }
  }
}

/// What a scan found, so "nothing new" reads differently from "nothing".
class AnomalyScanResult {
  const AnomalyScanResult({
    required this.attributionsExamined,
    required this.findings,
    required this.created,
    required this.updated,
  });

  final int attributionsExamined;
  final int findings;
  final int created;
  final int updated;

  /// The sentence a console shows after a scan.
  ///
  /// "We looked and found nothing" is a different statement from "we never
  /// looked", and an Admin who triggered a scan needs to see which happened.
  String get summary {
    if (attributionsExamined == 0) {
      return 'No attributions in this period — nothing to examine.';
    }
    if (findings == 0) {
      return 'Examined $attributionsExamined attributions. Nothing flagged.';
    }
    if (created == 0) {
      return 'Examined $attributionsExamined attributions. '
          '$updated existing ${updated == 1 ? 'finding' : 'findings'} '
          'refreshed, nothing new.';
    }
    return 'Examined $attributionsExamined attributions. '
        '$created new ${created == 1 ? 'finding' : 'findings'}'
        '${updated > 0 ? ', $updated refreshed' : ''}.';
  }
}

/// A recompute pass, which may be one of several.
class RecomputeResult {
  const RecomputeResult({
    required this.complete,
    required this.incrementedMassMg,
    required this.recomputedMassMg,
    required this.variance,
    required this.matched,
    this.cursor,
  });

  /// Whether the whole period was read.
  ///
  /// A console that ignored this would report a partial recompute as a complete
  /// one — and a partial recompute's "variance" is meaningless, because it is
  /// comparing a full counter against a fraction of the rows.
  final bool complete;

  final int incrementedMassMg;
  final int recomputedMassMg;
  final int variance;
  final bool matched;
  final String? cursor;
}

/// The read-only producer view, or the reason it was not opened.
class OrganizationViewResult {
  const OrganizationViewResult({this.view, this.error});

  const OrganizationViewResult.failed(String message)
    : view = null,
      error = message;

  final OrganizationView? view;
  final String? error;

  bool get hasError => error != null;
}

int _int(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.round();
  return 0;
}
