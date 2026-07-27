import 'package:cloud_firestore/cloud_firestore.dart';

class WalletModel {
  final String userId;
  final int balance;
  final DateTime updatedAt;

  const WalletModel({
    required this.userId,
    required this.balance,
    required this.updatedAt,
  });

  factory WalletModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return WalletModel(
      userId: data['userId'] as String,
      balance: (data['balance'] as num).toInt(),
      updatedAt: (data['updatedAt'] as Timestamp).toDate(),
    );
  }

  Map<String, dynamic> toFirestore() => {
        'userId': userId,
        'balance': balance,
        'updatedAt': Timestamp.fromDate(updatedAt),
      };
}
