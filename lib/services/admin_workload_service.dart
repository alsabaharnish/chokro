import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/constants.dart';

class AdminCompletedCount {
  const AdminCompletedCount({required this.count, required this.atCap});

  final int count;
  final bool atCap;
}

/// Reads the decisions one administrator has completed during the current day.
///
/// Pending work already has one live queue per subject. Completed work is read
/// from the existing `reviewedAt` and `reviewedBy` audit fields rather than from
/// a second counter that could drift away from the decision itself.
class AdminWorkloadService {
  AdminWorkloadService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  Stream<AdminCompletedCount> watchCompletedDisposals({
    required String adminUid,
    required DateTime day,
  }) => _watchCompleted(collection: 'disposals', adminUid: adminUid, day: day);

  Stream<AdminCompletedCount> watchCompletedClaims({
    required String adminUid,
    required DateTime day,
  }) => _watchCompleted(collection: 'claims', adminUid: adminUid, day: day);

  Stream<AdminCompletedCount> watchCompletedAppeals({
    required String adminUid,
    required DateTime day,
  }) => _watchCompleted(collection: 'appeals', adminUid: adminUid, day: day);

  Stream<AdminCompletedCount> watchCompletedApplications({
    required String adminUid,
    required DateTime day,
  }) => _watchCompleted(
    collection: 'sellerApplications',
    adminUid: adminUid,
    day: day,
  );

  Stream<AdminCompletedCount> _watchCompleted({
    required String collection,
    required String adminUid,
    required DateTime day,
  }) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));

    // Apply the administrator filter before the cap. Filtering a platform-wide
    // 250-document window in Dart made one person's count freeze as soon as
    // other reviewers filled that window. The matching composite indexes live
    // in firestore.indexes.json.
    return _db
        .collection(collection)
        .where('reviewedBy', isEqualTo: adminUid)
        .where('reviewedAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('reviewedAt', isLessThan: Timestamp.fromDate(end))
        .limit(QueryLimits.adminDailyReviews + 1)
        .snapshots()
        .map((snapshot) {
          final atCap = snapshot.docs.length > QueryLimits.adminDailyReviews;
          return AdminCompletedCount(
            count: atCap ? QueryLimits.adminDailyReviews : snapshot.docs.length,
            atCap: atCap,
          );
        });
  }
}
