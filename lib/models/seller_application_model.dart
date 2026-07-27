import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/constants.dart';

class SellerApplicationModel {
  final String id;
  final String userId;
  final String businessName;
  final String description;
  final String status;
  final DateTime createdAt;
  final String? reviewedBy;
  final DateTime? reviewedAt;
  final String? reason;

  const SellerApplicationModel({
    required this.id,
    required this.userId,
    required this.businessName,
    required this.description,
    required this.status,
    required this.createdAt,
    this.reviewedBy,
    this.reviewedAt,
    this.reason,
  });

  bool get isPending => status == AppConstants.statusPending;
  bool get isApproved => status == AppConstants.statusApproved;

  factory SellerApplicationModel.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return SellerApplicationModel(
      id: doc.id,
      userId: data['userId'] as String,
      businessName: data['businessName'] as String,
      description: data['description'] as String,
      status: data['status'] as String,
      createdAt: (data['createdAt'] as Timestamp).toDate(),
      reviewedBy: data['reviewedBy'] as String?,
      reviewedAt: data['reviewedAt'] != null
          ? (data['reviewedAt'] as Timestamp).toDate()
          : null,
      reason: data['reason'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() => {
        'userId': userId,
        'businessName': businessName,
        'description': description,
        'status': status,
        'createdAt': Timestamp.fromDate(createdAt),
        if (reviewedBy != null) 'reviewedBy': reviewedBy,
        if (reviewedAt != null) 'reviewedAt': Timestamp.fromDate(reviewedAt!),
        if (reason != null) 'reason': reason,
      };
}
