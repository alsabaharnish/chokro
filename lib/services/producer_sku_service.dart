import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../models/producer_sku_model.dart';
import '../models/sku_revision_model.dart';
import 'organization_service.dart';

/// The product registry's read and write path (EPR-9 to EPR-14).
///
/// HTTP rather than Firestore, for the reason [OrganizationService] gives: every
/// write here is a server write, and several of the reads carry a decision with
/// them — whether a mass is due for re-verification, what tolerance a
/// declaration will be judged against. Resolving those in the same call that
/// returns the list means the screen and the server cannot disagree about them.
class ProducerSkuService {
  ProducerSkuService({http.Client? client, FirebaseAuth? auth})
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
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer ${await user.getIdToken()}',
    };
  }

  Future<http.Response> _get(String path) async => _client
      .get(ApiConfig.path(path), headers: await _headers())
      .timeout(ApiConfig.coldStartTimeout);

  Future<http.Response> _post(String path, [Map<String, dynamic>? body]) async =>
      _client
          .post(
            ApiConfig.path(path),
            headers: await _headers(),
            body: jsonEncode(body ?? const <String, dynamic>{}),
          )
          .timeout(ApiConfig.coldStartTimeout);

  // -------------------------------------------------------------------------
  // Producer
  // -------------------------------------------------------------------------

  Future<SkuCatalogue> listSkus() async {
    final response = await _get('/epr/skus');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw const OrgActionException('The product list could not be read.');
    }
    return SkuCatalogue.fromJson(body);
  }

  Future<SkuHistory> loadHistory(String skuId, {bool asAdmin = false}) async {
    final response = await _get(
      asAdmin
          ? '/epr/admin/skus/$skuId/history'
          : '/epr/skus/$skuId/history',
    );
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw const OrgActionException('The history could not be read.');
    }
    return SkuHistory.fromJson(body);
  }

  /// Creates or replaces a draft. Returns the server's id for it.
  Future<String> saveDraft(ProducerSkuModel sku) async {
    final isNew = sku.id.isEmpty;
    final response = await _post(
      isNew ? '/epr/skus' : '/epr/skus/${sku.id}',
      sku.toDraftJson(),
    );
    if (response.statusCode != (isNew ? 201 : 200)) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final id = body is Map<String, dynamic> ? body['skuId'] : null;
    return id is String ? id : sku.id;
  }

  /// Bulk import (EPR-10). All-or-nothing: the server validates every row
  /// before writing any of them.
  Future<int> importDrafts(List<ProducerSkuModel> drafts) async {
    final response = await _post('/epr/skus/import', {
      'skus': drafts.map((d) => d.toDraftJson()).toList(),
    });
    if (response.statusCode != 201) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    final created = body is Map<String, dynamic> ? body['created'] : null;
    return created is int ? created : drafts.length;
  }

  Future<void> submitForVerification(String skuId) async {
    final response = await _post('/epr/skus/$skuId/submit');
    if (response.statusCode != 200) throw _exceptionFor(response);
  }

  // -------------------------------------------------------------------------
  // Chokro administration (EPR-42)
  // -------------------------------------------------------------------------

  Future<MassQueue> loadMassQueue() async {
    final response = await _get('/epr/admin/mass-queue');
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    if (body is! Map<String, dynamic>) {
      throw const OrgActionException('The queue could not be read.');
    }
    return MassQueue.fromJson(body);
  }

  /// Records a physical re-weighing, which establishes the verified mass.
  Future<MassAuditOutcome> recordAudit({
    required String skuId,
    required int sampleSize,
    required int measuredMeanMg,
    int? measuredStdDevMg,
    String? weighingLocation,
    String? scalePhotoUrl,
    String? note,
  }) async {
    final response = await _post('/epr/admin/skus/$skuId/audit', {
      'sampleSize': sampleSize,
      'measuredMeanMg': measuredMeanMg,
      'measuredStdDevMg': ?measuredStdDevMg,
      'weighingLocation': ?weighingLocation,
      'scalePhotoUrl': ?scalePhotoUrl,
      'note': ?note,
    });
    if (response.statusCode != 200) throw _exceptionFor(response);

    final body = jsonDecode(response.body);
    return MassAuditOutcome.fromJson(
      body is Map<String, dynamic> ? body : const <String, dynamic>{},
    );
  }

  /// Sets a verified mass without a scale — documentary verification or an
  /// Admin override. Both require a stated basis (EPR-11).
  Future<void> setVerifiedMass({
    required String skuId,
    required int verifiedUnitMassMg,
    required String reason,
    required String note,
  }) async {
    final response = await _post('/epr/admin/skus/$skuId/verified-mass', {
      'verifiedUnitMassMg': verifiedUnitMassMg,
      'reason': reason,
      'note': note,
    });
    if (response.statusCode != 200) throw _exceptionFor(response);
  }

  Future<void> rejectSku({required String skuId, required String reason}) async {
    final response = await _post('/epr/admin/skus/$skuId/reject', {
      'reason': reason,
    });
    if (response.statusCode != 200) throw _exceptionFor(response);
  }

  // -------------------------------------------------------------------------

  OrgActionException _exceptionFor(http.Response response) {
    String message;
    String? code;
    List<String>? problems;

    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        final m = body['message'];
        final c = body['error'];
        final p = body['problems'];
        message = m is String && m.isNotEmpty ? m : _fallbackFor(response);
        code = c is String ? c : null;
        problems = p is List ? p.whereType<String>().toList() : null;
      } else {
        message = _fallbackFor(response);
      }
    } catch (_) {
      // A non-JSON body from a proxy or a cold start.
      message = _fallbackFor(response);
    }

    // Every problem, joined, rather than the summary alone. A producer whose
    // declaration was refused for three reasons should see three, not "could
    // not be saved".
    if (problems != null && problems.isNotEmpty) {
      message = problems.join(' ');
    }

    return OrgActionException(message, code: code);
  }

  String _fallbackFor(http.Response response) => switch (response.statusCode) {
    401 => 'Sign in to continue.',
    403 => 'You do not have permission to do that.',
    404 => 'That product no longer exists.',
    429 => 'Too many attempts. Wait a minute and try again.',
    503 => 'The service is waking up. Try again in a moment.',
    _ => 'That action could not be completed.',
  };
}

/// One organisation's registry, with the two facts the list needs beside it.
class SkuCatalogue {
  const SkuCatalogue({
    required this.skus,
    this.revalidationDue = const <String>{},
    this.massToleranceFraction,
    this.massAuditSampleSize,
    this.massRevalidationMonths,
  });

  factory SkuCatalogue.fromJson(Map<String, dynamic> json) {
    final rows = json['skus'];
    final due = json['revalidationDue'];
    final policy = json['policy'];

    return SkuCatalogue(
      skus: rows is List
          ? rows
                .whereType<Map<String, dynamic>>()
                .map(
                  (row) => ProducerSkuModel.fromJson(
                    _dates(row),
                    id: row['skuId'] is String ? row['skuId'] as String : '',
                  ),
                )
                .toList(growable: false)
          : const <ProducerSkuModel>[],
      revalidationDue: due is List ? due.whereType<String>().toSet() : const {},
      massToleranceFraction: policy is Map<String, dynamic>
          ? _double(policy['massToleranceFraction'])
          : null,
      massAuditSampleSize: policy is Map<String, dynamic>
          ? _int(policy['massAuditSampleSize'])
          : null,
      massRevalidationMonths: policy is Map<String, dynamic>
          ? _int(policy['massRevalidationMonths'])
          : null,
    );
  }

  final List<ProducerSkuModel> skus;

  /// SKUs whose verified mass is older than the policy interval (EPR-13).
  ///
  /// Resolved by the server at read time, because nothing runs on a timer
  /// (NFR-E-2) — so the list carries the answer rather than each client
  /// re-deriving it from a policy it would also have to fetch.
  final Set<String> revalidationDue;

  final double? massToleranceFraction;
  final int? massAuditSampleSize;
  final int? massRevalidationMonths;

  List<ProducerSkuModel> get verified =>
      skus.where((s) => s.hasVerifiedMass).toList(growable: false);

  List<ProducerSkuModel> get awaitingVerification =>
      skus.where((s) => s.isAwaitingVerification).toList(growable: false);

  List<ProducerSkuModel> get drafts => skus
      .where((s) => !s.hasVerifiedMass && !s.isAwaitingVerification)
      .toList(growable: false);

  /// What share of the registry has a mass a report could actually use.
  ///
  /// The Admin directory's "verified-mass coverage" (EPR-40), and the single
  /// most useful number on a producer's own registry screen: a catalogue of
  /// forty products with three verified masses can report on three.
  double get verifiedCoverage =>
      skus.isEmpty ? 0 : verified.length / skus.length;

  bool get isEmpty => skus.isEmpty;
}

/// A product's revision history and the weighings behind it.
class SkuHistory {
  const SkuHistory({required this.revisions, required this.audits});

  factory SkuHistory.fromJson(Map<String, dynamic> json) {
    final revisions = json['revisions'];
    final audits = json['audits'];

    return SkuHistory(
      revisions: revisions is List
          ? revisions
                .whereType<Map<String, dynamic>>()
                .map(
                  (row) => SkuRevisionModel.fromJson(
                    _dates(row),
                    id: row['id'] is String ? row['id'] as String : '',
                  ),
                )
                .toList(growable: false)
          : const <SkuRevisionModel>[],
      audits: audits is List
          ? audits
                .whereType<Map<String, dynamic>>()
                .map(
                  (row) => SkuMassAuditModel.fromJson(
                    _dates(row),
                    id: row['id'] is String ? row['id'] as String : '',
                  ),
                )
                .toList(growable: false)
          : const <SkuMassAuditModel>[],
    );
  }

  final List<SkuRevisionModel> revisions;
  final List<SkuMassAuditModel> audits;

  /// The revision in force now, if any.
  SkuRevisionModel? get current {
    for (final revision in revisions) {
      if (revision.isCurrent) return revision;
    }
    return null;
  }

  bool get isEmpty => revisions.isEmpty && audits.isEmpty;
}

/// The Admin mass-verification queue (EPR-42).
class MassQueue {
  const MassQueue({
    required this.skus,
    this.massToleranceFraction = 0.10,
    this.massAuditSampleSize = 5,
  });

  factory MassQueue.fromJson(Map<String, dynamic> json) {
    final rows = json['queue'];
    final policy = json['policy'];

    return MassQueue(
      skus: rows is List
          ? rows
                .whereType<Map<String, dynamic>>()
                .map(
                  (row) => ProducerSkuModel.fromJson(
                    _dates(row),
                    id: row['skuId'] is String ? row['skuId'] as String : '',
                  ),
                )
                .toList(growable: false)
          : const <ProducerSkuModel>[],
      massToleranceFraction: policy is Map<String, dynamic>
          ? (_double(policy['massToleranceFraction']) ?? 0.10)
          : 0.10,
      massAuditSampleSize: policy is Map<String, dynamic>
          ? (_int(policy['massAuditSampleSize']) ?? 5)
          : 5,
    );
  }

  final List<ProducerSkuModel> skus;

  /// The tolerance a declaration will be judged against, and the minimum
  /// sample. Shown on the form so an Admin sees the rule before weighing, not
  /// after being refused.
  final double massToleranceFraction;
  final int massAuditSampleSize;

  bool get isEmpty => skus.isEmpty;
}

/// What a recorded weighing established.
class MassAuditOutcome {
  const MassAuditOutcome({
    required this.verdict,
    required this.verifiedUnitMassMg,
    required this.revision,
  });

  factory MassAuditOutcome.fromJson(Map<String, dynamic> json) =>
      MassAuditOutcome(
        verdict: json['verdict'] is String ? json['verdict'] as String : '',
        verifiedUnitMassMg: _int(json['verifiedUnitMassMg']) ?? 0,
        revision: _int(json['revision']) ?? 0,
      );

  final String verdict;
  final int verifiedUnitMassMg;
  final int revision;

  bool get wasWithinTolerance => verdict == MassAuditVerdict.withinTolerance;
}

/// Firestore Admin SDK JSON renders a timestamp as `{_seconds, _nanoseconds}`.
/// Converted here so the models keep seeing only plain Dart types (§5.1).
Map<String, dynamic> _dates(Map<String, dynamic> json) {
  const dateKeys = {
    'createdAt',
    'updatedAt',
    'verifiedAt',
    'activeFrom',
    'activeTo',
    'submittedAt',
    'reviewedAt',
  };

  return <String, dynamic>{
    for (final entry in json.entries)
      entry.key: dateKeys.contains(entry.key)
          ? _timestamp(entry.value)
          : entry.value,
  };
}

Object? _timestamp(Object? value) {
  if (value is Map && value['_seconds'] is num) {
    return DateTime.fromMillisecondsSinceEpoch(
      (value['_seconds'] as num).round() * 1000,
      isUtc: true,
    );
  }
  return value;
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  return null;
}

double? _double(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;
