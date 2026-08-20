/// The ledger entry written alongside every balance change (NFR-4).
///
/// Plain Dart, no Firebase imports. The service layer converts `Timestamp` to
/// `DateTime` on the way in, so this file stays emulator-free and testable.
///
/// Every field here is written by the trusted server. The client never creates
/// a transaction — rules deny client writes to the collection entirely — so
/// this model is read-only in practice and carries no `toFirestore` path.
library;

/// Where a balance change came from.
///
/// `unknown` exists so that a source value this build does not recognise
/// renders as "Other" instead of crashing the ledger. Reads are forgiving;
/// writes are strict and happen server-side.
enum TransactionSource { disposal, purchase, claim, redemption, unknown }

TransactionSource parseTransactionSource(Object? raw) {
  final name = raw is String ? raw : raw?.toString().split('.').last;
  switch (name) {
    case 'disposal':
      return TransactionSource.disposal;
    case 'purchase':
      return TransactionSource.purchase;
    case 'claim':
      return TransactionSource.claim;
    case 'redemption':
      return TransactionSource.redemption;
    default:
      return TransactionSource.unknown;
  }
}

extension TransactionSourceDisplay on TransactionSource {
  /// The value as stored in Firestore.
  String get wireValue => name;

  /// User-facing label. Named for what the user did, not for the schema.
  String get label {
    switch (this) {
      case TransactionSource.disposal:
        return 'Waste disposal';
      case TransactionSource.purchase:
        return 'Marketplace purchase';
      case TransactionSource.claim:
        return 'Eco-action claim';
      case TransactionSource.redemption:
        return 'Points redeemed';
      case TransactionSource.unknown:
        return 'Other';
    }
  }

  /// One line explaining why the balance moved, shown under the label.
  String get description {
    switch (this) {
      case TransactionSource.disposal:
        return 'Verified disposal at a registered bin';
      case TransactionSource.purchase:
        return 'Reward for a confirmed order';
      case TransactionSource.claim:
        return 'Approved self-reported action';
      case TransactionSource.redemption:
        return 'Spent at checkout';
      case TransactionSource.unknown:
        return '';
    }
  }
}

class TransactionModel {
  const TransactionModel({
    required this.id,
    required this.userId,
    required this.delta,
    required this.source,
    this.refId,
    this.balanceAfter,
    this.createdAt,
  });

  /// Firestore document id.
  final String id;

  final String userId;

  /// Signed. Positive credits, negative debits.
  final int delta;

  final TransactionSource source;

  /// The disposal, claim or order this entry settles. Null only on entries
  /// that reference nothing.
  final String? refId;

  /// The wallet balance immediately after this entry was applied. Server
  /// written inside the same transaction as the balance itself.
  final int? balanceAfter;

  /// Null while the server timestamp is still unresolved locally.
  final DateTime? createdAt;

  bool get isCredit => delta > 0;

  /// `+50` / `-120`.
  String get signedDelta => delta > 0 ? '+$delta' : '$delta';

  /// Tolerant on numbers: Firestore returns integers as `int` but a value that
  /// has been through JSON may arrive as `double` or as a numeric string.
  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.truncateToDouble()) {
      return value.toInt();
    }
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// [data] must already have `createdAt` converted from `Timestamp` to
  /// `DateTime` by the service layer.
  factory TransactionModel.fromMap(String id, Map<String, dynamic> data) {
    final created = data['createdAt'];
    return TransactionModel(
      id: id,
      userId: data['userId'] is String ? data['userId'] as String : '',
      delta: _asInt(data['delta']) ?? 0,
      source: parseTransactionSource(data['source']),
      refId: data['refId'] is String ? data['refId'] as String : null,
      balanceAfter: _asInt(data['balanceAfter']),
      createdAt: created is DateTime ? created : null,
    );
  }

  // `toMap()` was deleted rather than kept.
  //
  // Zero callers in `lib/`, in `test/` and on the server, and it was actively
  // misleading: no client may ever write a `transactions` document — the rules
  // refuse it to an administrator as flatly as to a buyer — so a serialiser for
  // one could only ever have been used by mistake. Every ledger entry is written
  // by `award.js` inside the same transaction that moves the balance, which is
  // what makes "no client writes a balance" true without qualification.

  @override
  String toString() =>
      'TransactionModel($id, ${source.wireValue}, $signedDelta, after=$balanceAfter)';
}
