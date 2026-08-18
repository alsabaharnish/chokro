import 'package:cloud_firestore/cloud_firestore.dart';

/// A user's single points balance (F3.1).
///
/// One document per user. Only the Admin SDK ever changes `balance` after
/// creation — the rules refuse a client update outright, including an admin's —
/// so this model is read-only in practice apart from the zero-balance document
/// registration opens.
class WalletModel {
  final String userId;
  final int balance;

  /// When the balance last changed, as the server saw it.
  ///
  /// Nullable for the same reason as `UserModel.createdAt`: it is written with
  /// `FieldValue.serverTimestamp()`, so the locally cached snapshot immediately
  /// after registration carries null until the server round trip completes.
  final DateTime? updatedAt;

  const WalletModel({
    required this.userId,
    required this.balance,
    this.updatedAt,
  });

  /// Reads a wallet document without trusting any field's type.
  ///
  /// Every cast here was previously unchecked, and `updatedAt` in particular
  /// crashed on the document registration had just written, because a pending
  /// server timestamp reads as null locally. This is the balance shown on the
  /// home screen, so a throw here greeted a brand-new account with an error
  /// where its zero balance should be.
  ///
  /// A missing balance reads as zero. That is the safe direction: it under-states
  /// what someone has rather than inventing points, and the authoritative figure
  /// lives in Firestore either way.
  factory WalletModel.fromFirestore(DocumentSnapshot doc) =>
      WalletModel.fromMap(doc.data(), uid: doc.id);

  /// The parsing itself, over a plain map — testable without faking the sealed
  /// `DocumentSnapshot` type.
  factory WalletModel.fromMap(Object? raw, {required String uid}) {
    final data = raw is Map<String, dynamic> ? raw : const <String, dynamic>{};

    final balance = data['balance'];
    final updatedAt = data['updatedAt'];

    return WalletModel(
      userId: data['userId'] is String ? data['userId'] as String : uid,
      balance: balance is num ? balance.toInt() : 0,
      updatedAt: updatedAt is Timestamp ? updatedAt.toDate() : null,
    );
  }

  /// Field map for a Firestore write.
  ///
  /// `updatedAt` is omitted deliberately — §6 of the brief requires a server
  /// timestamp, and the service layer supplies it. The rules require the key to
  /// be present when the document is created, and a server timestamp satisfies
  /// that.
  Map<String, dynamic> toFirestore() => {
        'userId': userId,
        'balance': balance,
      };
}
