import 'package:chokro/models/bin_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  BinModel validBin() => const BinModel(
    id: 'bin_001',
    label: 'Merul Badda — Block C gate',
    lat: 23.7808,
    lng: 90.4074,
    radiusMeters: 50,
    qrPayload: 'chokro:bin:001',
    active: true,
    createdBy: 'admin_uid',
  );

  group('serialization', () {
    test('round-trips through JSON', () {
      final bin = validBin();
      final parsed = BinModel.fromJson(bin.toJson(), id: bin.id);
      expect(parsed, bin);
    });

    test('omits createdAt from the write map', () {
      // The service layer writes it with a server timestamp; a client-authored
      // clock value must never reach Firestore (§7.4).
      expect(validBin().toJson().containsKey('createdAt'), isFalse);
    });

    test('takes the document id from the parameter over the payload', () {
      final parsed = BinModel.fromJson(<String, dynamic>{
        'id': 'from_payload',
        'label': 'x',
      }, id: 'from_parameter');
      expect(parsed.id, 'from_parameter');
    });

    test('reads integer coordinates stored as ints', () {
      final parsed = BinModel.fromJson(<String, dynamic>{
        'lat': 23,
        'lng': 90,
        'radiusMeters': 50,
      });
      expect(parsed.lat, 23.0);
      expect(parsed.lng, 90.0);
      expect(parsed.radiusMeters, 50.0);
    });

    test('defaults a missing radius rather than producing a zero geofence', () {
      // A zero radius would silently reject every submission at the bin.
      final parsed = BinModel.fromJson(<String, dynamic>{'label': 'x'});
      expect(parsed.radiusMeters, 50.0);
    });

    test('defaults a missing active flag to true', () {
      final parsed = BinModel.fromJson(<String, dynamic>{'label': 'x'});
      expect(parsed.active, isTrue);
    });

    test('wrongly typed fields use safe defaults instead of throwing', () {
      final parsed = BinModel.fromJson(<String, dynamic>{
        'id': 7,
        'label': false,
        'active': 'yes',
        'createdAt': <String, dynamic>{},
      });

      expect(parsed.id, isNull);
      expect(parsed.label, isEmpty);
      expect(parsed.active, isTrue);
      expect(parsed.createdAt, isNull);
    });
  });

  group('validation', () {
    test('a well-formed bin passes', () {
      expect(validBin().validate(), isEmpty);
      expect(validBin().isValid, isTrue);
      expect(validBin().acceptsSubmissions, isTrue);
    });

    test('requires a label, payload and creator', () {
      expect(validBin().copyWith(label: '   ').validate(), isNotEmpty);
      expect(validBin().copyWith(qrPayload: '').validate(), isNotEmpty);
      expect(validBin().copyWith(createdBy: '').validate(), isNotEmpty);
    });

    test('rejects out-of-range coordinates', () {
      expect(validBin().copyWith(lat: 91).validate(), isNotEmpty);
      expect(validBin().copyWith(lng: -181).validate(), isNotEmpty);
    });

    test('rejects a failed GPS fix at null island', () {
      final bin = validBin().copyWith(lat: 0, lng: 0);
      expect(bin.validate(), isNotEmpty);
      expect(bin.isValid, isFalse);
    });

    test('rejects a non-positive radius', () {
      expect(validBin().copyWith(radiusMeters: 0).validate(), isNotEmpty);
      expect(validBin().copyWith(radiusMeters: -5).validate(), isNotEmpty);
    });

    test('rejects a geofence so large it proves nothing', () {
      final bin = validBin().copyWith(radiusMeters: 5000);
      expect(bin.validate(), isNotEmpty);
      expect(bin.validate().single, contains('no longer proves'));
    });

    test('an inactive bin is still valid but accepts nothing', () {
      final bin = validBin().copyWith(active: false);
      expect(bin.isValid, isTrue);
      expect(bin.acceptsSubmissions, isFalse);
    });
  });

  group('copyWith', () {
    test('changes only the named field', () {
      final bin = validBin();
      final renamed = bin.copyWith(label: 'New label');
      expect(renamed.label, 'New label');
      expect(renamed.lat, bin.lat);
      expect(renamed.qrPayload, bin.qrPayload);
    });

    test('returns an equal object when given nothing', () {
      expect(validBin().copyWith(), validBin());
    });
  });
}
