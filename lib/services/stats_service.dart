import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/network_errors.dart';
import '../models/stats_model.dart';

/// The admin dashboard's counters (F5.1).
///
/// One document read, not a scan of four collections. §6.3 is explicit about
/// why: the counters are incremented with `FieldValue.increment()` inside the
/// same server transactions that cause them, so the dashboard costs one read
/// however much data accumulates.
///
/// Read-only by construction — `firestore.rules` denies every client write to
/// `stats`, an administrator included, because a counter somebody could edit
/// would stop being evidence of anything.
class StatsService {
  StatsService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  /// The document id the server writes to. One document, named rather than
  /// implied, so a second dashboard cannot invent its own.
  static const String platformDocId = 'platform';

  /// Live counters.
  ///
  /// A missing document emits zeros rather than an error: it does not exist
  /// until the first transaction increments something, and a dashboard on a
  /// fresh database should read empty rather than broken.
  Stream<PlatformStats> watchPlatformStats() => _db
      .collection('stats')
      .doc(platformDocId)
      // The metadata event matters when a fresh database genuinely has no
      // stats document: the first cache-only miss is inconclusive, while the
      // following server-confirmed miss is an authoritative zero snapshot.
      .snapshots(includeMetadataChanges: true)
      .map((doc) {
        if (!doc.exists && doc.metadata.isFromCache) {
          throw const PlatformStatsUnavailableException();
        }
        return PlatformStats.fromMap(
          doc.data(),
          isFromCache: doc.metadata.isFromCache,
        );
      });
}

/// A missing cache entry cannot prove that the platform has no activity.
///
/// This is deliberately distinct from a server-confirmed missing document,
/// which is a valid fresh-install state and maps to [PlatformStats.empty].
class PlatformStatsUnavailableException implements UserFacingException {
  const PlatformStatsUnavailableException();

  @override
  String get message =>
      'Chokro could not confirm the platform counters. Check your connection '
      'and try again.';

  @override
  String toString() => message;
}
