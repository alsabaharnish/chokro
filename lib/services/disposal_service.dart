import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/disposal_model.dart';

/// Firestore and Storage access for disposal submissions (F2.3, F2.7, F7.2).
///
/// The client's entire write capability on this collection is one thing:
/// creating a `pending` document with an exact set of fields. Screening,
/// approval, rejection and the points award all belong to the trusted server —
/// see the `disposals` block in `firestore.rules`, and the tests in
/// `rules_test/m2.rules.test.js` proving that even an administrator cannot
/// approve from a client.
class DisposalService {
  final FirebaseFirestore _db = FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _disposals =>
      _db.collection('disposals');

  /// Writes a pending submission and returns its document ID.
  ///
  /// The field map comes from [DisposalModel.toCreateJson], which omits every
  /// server-owned field by construction, plus a server timestamp. The rules
  /// require `createdAt == request.time`, so a client clock value is rejected
  /// outright — the lockout window is meaningless if the client supplies the
  /// time it is measured against (§7.4).
  Future<String> createPendingDisposal(DisposalModel disposal) async {
    final data = <String, dynamic>{
      ...disposal.toCreateJson(),
      'createdAt': FieldValue.serverTimestamp(),
    };

    final doc = await _disposals.add(data);
    return doc.id;
  }

  /// A user's submissions, newest first, for the history screen (F7.2).
  Stream<List<DisposalModel>> watchUserDisposals(String uid) => _disposals
      .where('userId', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .snapshots()
      .map((snap) => snap.docs.map(_fromDoc).toList());

  /// A user's most recent submissions, for the reviewer's context (F2.7).
  ///
  /// Bounded on purpose. The review queue renders one card per pending
  /// submission, and each card asks for its submitter's record — so an unbounded
  /// `watchUserDisposals` per card would pull every disposal a prolific user has
  /// ever made, once per card, on a screen an administrator keeps open and
  /// scrolls. A recent window costs one small query.
  ///
  /// Uses the existing `userId` + `createdAt DESC` composite index, so this needs
  /// no addition to `firestore.indexes.json`. Filtering by status here instead
  /// would have: "approved" is two values (`autoApproved` and `manualApproved`),
  /// and an `in` filter alongside the ordering wants an index of its own.
  Future<List<DisposalModel>> recentForUser(String uid, {int limit = 20}) async {
    final snapshot = await _disposals
        .where('userId', isEqualTo: uid)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get();

    return snapshot.docs.map(_fromDoc).toList();
  }

  /// Everything awaiting a decision, for the admin review queue (F2.7).
  Stream<List<DisposalModel>> watchPendingDisposals() => _disposals
      .where('status', isEqualTo: 'pending')
      .orderBy('createdAt')
      .snapshots()
      .map((snap) => snap.docs.map(_fromDoc).toList());

  Future<DisposalModel?> getDisposal(String id) async {
    final doc = await _disposals.doc(id).get();
    if (!doc.exists) return null;
    return _fromDoc(doc);
  }

  DisposalModel _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.from(doc.data() ?? <String, dynamic>{});

    for (final key in ['createdAt', 'reviewedAt']) {
      final value = data[key];
      data[key] = value is Timestamp ? value.toDate() : null;
    }

    return DisposalModel.fromJson(data, id: doc.id);
  }
}
