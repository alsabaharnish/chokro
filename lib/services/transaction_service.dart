import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/transaction_model.dart';

/// Read-only access to the `transactions` ledger.
///
/// There is no write method here and there will not be one. Rules deny client
/// writes to `transactions` for every role; the server writes a ledger entry in
/// the same transaction as the balance it explains (§5.1, NFR-4).
class TransactionService {
  TransactionService({FirebaseFirestore? firestore})
      : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  static const String collection = 'transactions';

  /// The signed-in user's own ledger, newest first.
  ///
  /// Backed by the deployed composite index (`userId` ascending, `createdAt`
  /// descending). A missing index surfaces as a `failed-precondition` error
  /// with a console link, not as an empty list.
  Stream<List<TransactionModel>> watchUserTransactions(
    String userId, {
    int limit = 50,
  }) {
    return _db
        .collection(collection)
        .where('userId', isEqualTo: userId)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .snapshots()
        .map(_mapSnapshot);
  }

  /// One page, for a pull-to-refresh or a non-streaming caller.
  Future<List<TransactionModel>> fetchUserTransactions(
    String userId, {
    int limit = 50,
  }) async {
    final snapshot = await _db
        .collection(collection)
        .where('userId', isEqualTo: userId)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get();
    return _mapSnapshot(snapshot);
  }

  List<TransactionModel> _mapSnapshot(QuerySnapshot<Map<String, dynamic>> snap) {
    return snap.docs.map((doc) {
      final data = Map<String, dynamic>.from(doc.data());
      // Timestamp -> DateTime happens here, never in the model.
      final created = data['createdAt'];
      data['createdAt'] = created is Timestamp ? created.toDate() : null;
      return TransactionModel.fromMap(doc.id, data);
    }).toList(growable: false);
  }
}
