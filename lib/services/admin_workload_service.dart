import 'package:cloud_firestore/cloud_firestore.dart';

/// Reads the decisions one administrator has completed during the current day.
///
/// Pending work already has one live queue per subject. Completed work is read
/// from the existing `reviewedAt` and `reviewedBy` audit fields rather than from
/// a second counter that could drift away from the decision itself.
class AdminWorkloadService {
  AdminWorkloadService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  Stream<int> watchCompletedDisposals({
    required String adminUid,
    required DateTime day,
  }) => _watchCompleted(collection: 'disposals', adminUid: adminUid, day: day);

  Stream<int> watchCompletedClaims({
    required String adminUid,
    required DateTime day,
  }) => _watchCompleted(collection: 'claims', adminUid: adminUid, day: day);

  Stream<int> watchCompletedAppeals({
    required String adminUid,
    required DateTime day,
  }) => _watchCompleted(collection: 'appeals', adminUid: adminUid, day: day);

  Stream<int> watchCompletedApplications({
    required String adminUid,
    required DateTime day,
  }) => _watchCompleted(
    collection: 'sellerApplications',
    adminUid: adminUid,
    day: day,
  );

  Stream<int> _watchCompleted({
    required String collection,
    required String adminUid,
    required DateTime day,
  }) {
    final start = DateTime(day.year, day.month, day.day);
    final end = start.add(const Duration(days: 1));

    // Range-only queries use Firestore's automatic single-field index. Filtering
    // reviewedBy client-side avoids requiring four new composite indexes for a
    // very small, day-bounded audit set while still returning only this admin's
    // count to the UI.
    return _db
        .collection(collection)
        .where('reviewedAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .where('reviewedAt', isLessThan: Timestamp.fromDate(end))
        .limit(250)
        .snapshots()
        .map(
          (snapshot) => snapshot.docs
              .where((doc) => doc.data()['reviewedBy'] == adminUid)
              .length,
        );
  }
}
