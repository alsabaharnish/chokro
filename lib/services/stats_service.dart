import 'package:cloud_firestore/cloud_firestore.dart';

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
      .snapshots()
      .map((doc) => PlatformStats.fromMap(doc.data()));
}
