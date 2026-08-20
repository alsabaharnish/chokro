import 'package:cloud_firestore/cloud_firestore.dart';
import '../core/constants.dart';

class SellerApplicationModel {
  final String id;
  final String userId;
  final String businessName;
  final String description;
  final String status;

  /// Server time the application was submitted.
  ///
  /// Nullable because it is written with `FieldValue.serverTimestamp()` per §6 —
  /// this model was the last one still stamping the device clock — and Firestore
  /// resolves that on the server, so the local echo carries null briefly.
  final DateTime? createdAt;
  final String? reviewedBy;
  final DateTime? reviewedAt;
  final String? reason;

  const SellerApplicationModel({
    required this.id,
    required this.userId,
    required this.businessName,
    required this.description,
    required this.status,
    this.createdAt,
    this.reviewedBy,
    this.reviewedAt,
    this.reason,
  });

  bool get isPending => status == AppConstants.statusPending;
  bool get isApproved => status == AppConstants.statusApproved;

  factory SellerApplicationModel.fromFirestore(DocumentSnapshot doc) {
    return SellerApplicationModel.fromMap(doc.data(), id: doc.id);
  }

  factory SellerApplicationModel.fromMap(Object? raw, {required String id}) {
    final data = raw is Map<String, dynamic> ? raw : const <String, dynamic>{};
    return SellerApplicationModel(
      id: id,
      userId: _string(data['userId']),
      businessName: _string(data['businessName']),
      description: _string(data['description']),
      // Unknown data must not acquire a decided state in the UI.
      status: _string(data['status'], fallback: AppConstants.statusPending),
      // Nullable-tolerant: `createdAt` is a pending server timestamp for one
      // round trip after the write, and the old unchecked cast threw on exactly
      // the document it had just created.
      createdAt: _date(data['createdAt']),
      reviewedBy: _nullableString(data['reviewedBy']),
      reviewedAt: _date(data['reviewedAt']),
      reason: _nullableString(data['reason']),
    );
  }

  Map<String, dynamic> toFirestore() => {
    'userId': userId,
    'businessName': businessName,
    'description': description,
    'status': status,
    // Omitted deliberately; the service supplies
    // `FieldValue.serverTimestamp()`. Writing the device clock here let a
    // phone with a skewed clock date its own application (§6).
    if (reviewedBy != null) 'reviewedBy': reviewedBy,
    if (reviewedAt != null) 'reviewedAt': Timestamp.fromDate(reviewedAt!),
    if (reason != null) 'reason': reason,
  };
}

String _string(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;
String? _nullableString(Object? value) => value is String ? value : null;

DateTime? _date(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
