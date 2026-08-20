import 'package:chokro/core/constants.dart';
import 'package:chokro/models/seller_application_model.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SellerApplicationModel.fromMap', () {
    test('reads a complete application', () {
      final submitted = DateTime.utc(2026, 8, 20);
      final application = SellerApplicationModel.fromMap({
        'userId': 'u1',
        'businessName': 'Green Corner',
        'description': 'Locally made reusable goods.',
        'status': AppConstants.statusPending,
        'createdAt': Timestamp.fromDate(submitted),
      }, id: 'a1');

      expect(application.id, 'a1');
      expect(application.businessName, 'Green Corner');
      expect(application.createdAt?.toUtc(), submitted);
      expect(application.isPending, isTrue);
    });

    test('malformed data fails toward a pending empty record', () {
      final application = SellerApplicationModel.fromMap({
        'userId': 7,
        'businessName': false,
        'description': <String>[],
        'status': 99,
        'createdAt': <String, dynamic>{},
        'reviewedBy': true,
      }, id: 'a1');

      expect(application.userId, isEmpty);
      expect(application.businessName, isEmpty);
      expect(application.description, isEmpty);
      expect(application.status, AppConstants.statusPending);
      expect(application.createdAt, isNull);
      expect(application.reviewedBy, isNull);
    });

    test('a non-map payload does not throw', () {
      final application = SellerApplicationModel.fromMap(null, id: 'a1');
      expect(application.isPending, isTrue);
    });
  });
}
