import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/epr_period.dart';
import '../models/epr_period_model.dart';
import 'organization_service.dart';

/// A producer's attributed mass, read from the period rollups (EPR-22).
///
/// ## Why this reads rollups and never attribution rows
///
/// Two reasons, and the privacy one is the stronger.
///
/// A rollup carries no disposal reference, so there is nothing in it that could
/// correlate an event — or a person — across two producers' views (SEC-3). Row
/// level access needs the per-organisation pseudonymous reference that arrives
/// with the chain-of-custody export, and until that exists the safe surface is
/// the one that cannot leak.
///
/// The second reason is §3.3's: "A producer's annual report spans potentially
/// hundreds of thousands of disposals; it can never be a client query." The
/// rollup exists precisely so that it need not be.
class AttributionReadService {
  AttributionReadService({http.Client? client, FirebaseAuth? auth})
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

  /// This organisation's recent periods, newest first.
  Future<List<EprPeriodModel>> listPeriods() async {
    final response = await _client
        .get(ApiConfig.path('/epr/periods'), headers: await _headers())
        .timeout(ApiConfig.coldStartTimeout);

    if (response.statusCode != 200) {
      throw OrgActionException(_messageFor(response));
    }

    final body = jsonDecode(response.body);
    final rows = body is Map<String, dynamic> ? body['periods'] : null;
    if (rows is! List) return const <EprPeriodModel>[];

    return rows
        .whereType<Map<String, dynamic>>()
        .map((row) => EprPeriodModel.fromJson(_dates(row)))
        .where((period) => period.periodId.isNotEmpty)
        .toList(growable: false);
  }

  /// One period, which may legitimately be empty.
  ///
  /// A month with nothing in it is a valid answer rather than a 404, so the
  /// screen renders "no activity recorded" from a period that knows its own id
  /// instead of from an absence it has to interpret.
  Future<EprPeriodModel> loadPeriod(String periodId) async {
    if (!isValidPeriodId(periodId)) {
      throw const OrgActionException('That is not a reporting period.');
    }

    final response = await _client
        .get(
          ApiConfig.path('/epr/periods/$periodId'),
          headers: await _headers(),
        )
        .timeout(ApiConfig.coldStartTimeout);

    if (response.statusCode != 200) {
      throw OrgActionException(_messageFor(response));
    }

    final body = jsonDecode(response.body);
    final row = body is Map<String, dynamic> ? body['period'] : null;
    if (row is! Map<String, dynamic>) {
      throw const OrgActionException('That period could not be read.');
    }
    return EprPeriodModel.fromJson(_dates(row));
  }

  String _messageFor(http.Response response) {
    try {
      final body = jsonDecode(response.body);
      if (body is Map<String, dynamic>) {
        final message = body['message'];
        if (message is String && message.isNotEmpty) return message;
      }
    } catch (_) {
      // A non-JSON body from a proxy or a cold start.
    }
    return switch (response.statusCode) {
      401 => 'Sign in to continue.',
      403 => 'You do not have permission to view this.',
      429 => 'Too many requests. Wait a minute and try again.',
      503 => 'The service is waking up. Try again in a moment.',
      _ => 'That could not be loaded.',
    };
  }
}

/// Firestore Admin SDK JSON renders a timestamp as `{_seconds, _nanoseconds}`.
Map<String, dynamic> _dates(Map<String, dynamic> json) {
  // `lastAttributionAt` is deliberately absent: the server projects it out of
  // every producer response (SEC-3), because on a period with one disposal a
  // second-precision instant is the exact moment of one person's act.
  const dateKeys = {'recomputedAt'};
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
