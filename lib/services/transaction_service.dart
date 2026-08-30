import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/constants.dart';
import '../models/transaction_model.dart';

/// A bounded ledger read and whether an older entry exists.
///
/// The extra bit matters to the wallet UI: a capped list must not look like the
/// user's complete financial history, and it is also what lets the screen offer
/// an explicit "load older" path without guessing from an exact page length.
class TransactionPage {
  const TransactionPage({required this.entries, required this.truncated});

  final List<TransactionModel> entries;
  final bool truncated;
}

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
  Stream<TransactionPage> watchUserTransactions(
    String userId, {
    int limit = QueryLimits.ledger,
  }) {
    return _db
        .collection(collection)
        .where('userId', isEqualTo: userId)
        .orderBy('createdAt', descending: true)
        // Read one beyond the requested window so "more" is a fact, not an
        // inference that is wrong for a user with exactly [limit] entries.
        .limit(limit + 1)
        .snapshots()
        .map((snapshot) {
          final truncated = snapshot.docs.length > limit;
          final docs = truncated ? snapshot.docs.take(limit) : snapshot.docs;
          return TransactionPage(entries: _mapDocs(docs), truncated: truncated);
        });
  }

  /// One page, for a pull-to-refresh or a non-streaming caller.
  Future<List<TransactionModel>> fetchUserTransactions(
    String userId, {
    int limit = QueryLimits.ledger,
  }) async {
    final snapshot = await _db
        .collection(collection)
        .where('userId', isEqualTo: userId)
        .orderBy('createdAt', descending: true)
        .limit(limit)
        .get();
    return _mapDocs(snapshot.docs);
  }

  List<TransactionModel> _mapDocs(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    return docs
        .map((doc) {
          final data = Map<String, dynamic>.from(doc.data());
          // Timestamp -> DateTime happens here, never in the model.
          final created = data['createdAt'];
          data['createdAt'] = created is Timestamp ? created.toDate() : null;
          return TransactionModel.fromMap(doc.id, data);
        })
        .toList(growable: false);
  }
}
