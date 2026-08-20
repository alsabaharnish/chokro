import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/constants.dart';
import '../models/appeal_model.dart';

/// Appeals against a rejection (F5.4).
///
/// Both sides are Firestore writes and neither touches the server, because
/// resolving an appeal moves no points. That is what lets the whole decision be
/// expressed in `firestore.rules`, in exactly the shape `sellerApplications`
/// already uses: the user creates one pending document against their own
/// rejected submission, an administrator flips it once and writes an answer.
///
/// The rules go further than this service can: creation is refused unless the
/// named disposal or claim exists, belongs to the caller, and was actually
/// rejected. Without that, `appeals` would be an unmoderated text collection any
/// account could write into against any id.
class AppealService {
  AppealService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  CollectionReference<Map<String, dynamic>> get _appeals =>
      _db.collection('appeals');

  /// Raises an appeal and returns its deterministic document id.
  ///
  /// A second write for the same user and subject becomes an update, which the
  /// rules deny. This protects the review queue even when the UI is bypassed.
  Future<String> create(AppealModel appeal) async {
    final id = appeal.documentId;
    await _appeals.doc(id).set(<String, dynamic>{
      ...appeal.toCreateJson(),
      'createdAt': FieldValue.serverTimestamp(),
    });
    return id;
  }

  /// A user's own appeals, newest first.
  Stream<List<AppealModel>> watchUserAppeals(String uid) => _appeals
      .where('userId', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .limit(QueryLimits.ownHistory)
      .snapshots()
      .map((snap) => snap.docs.map(_fromDoc).toList());

  /// The administrator's queue, oldest first — the same ordering as the disposal
  /// and claim queues, so the earliest appeal is not the one left waiting
  /// longest.
  Stream<List<AppealModel>> watchPendingAppeals() => _appeals
      .where('status', isEqualTo: 'pending')
      .orderBy('createdAt')
      .limit(QueryLimits.reviewQueue)
      .snapshots()
      .map((snap) => snap.docs.map(_fromDoc).toList());

  /// Every appeal a given user has raised, for the administrator reviewing one
  /// of them. Somebody appealing their fifth rejection this week is context a
  /// reviewer should have.
  Stream<List<AppealModel>> watchAppealsFor(String uid) =>
      watchUserAppeals(uid);

  /// Resolves an appeal.
  ///
  /// [response] is mandatory on either outcome and the rules enforce a minimum
  /// length: an appeal answered with a status and no words is not an answer.
  /// `reviewedAt` must be the server clock, and `reviewedBy` must be the calling
  /// administrator — the rules check both, so passing anything else is a
  /// permission denial rather than a wrong value being stored.
  Future<void> resolve({
    required String appealId,
    required String adminUid,
    required bool uphold,
    required String response,
  }) {
    return _appeals.doc(appealId).update(<String, dynamic>{
      'status': uphold ? AppealStatus.upheld.name : AppealStatus.declined.name,
      'response': response.trim(),
      'reviewedBy': adminUid,
      'reviewedAt': FieldValue.serverTimestamp(),
    });
  }

  AppealModel _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.from(doc.data() ?? <String, dynamic>{});
    for (final key in ['createdAt', 'reviewedAt']) {
      final value = data[key];
      data[key] = value is Timestamp ? value.toDate() : null;
    }
    return AppealModel.fromMap(data, id: doc.id);
  }
}
