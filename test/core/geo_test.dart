import 'package:chokro/core/geo.dart';
import 'package:flutter_test/flutter_test.dart';

/// Expected distances were computed independently against a reference Haversine
/// implementation and cross-checked at known geodesic landmarks (one degree of
/// longitude at the equator, quarter circumference, antipodes).
void main() {
  // A reference bin, Merul Badda.
  const binLat = 23.7808;
  const binLng = 90.4074;

  group('haversine distance', () {
    test('is zero for an identical point', () {
      expect(
        haversineDistance(
          lat1: binLat,
          lng1: binLng,
          lat2: binLat,
          lng2: binLng,
        ),
        0.0,
      );
    });

    test('one thousandth of a degree of latitude is about 111 m', () {
      final d = haversineDistance(
        lat1: binLat,
        lng1: binLng,
        lat2: binLat + 0.001,
        lng2: binLng,
      );
      expect(d, closeTo(111.195, 0.05));
    });

    test('a degree of longitude shortens with latitude', () {
      // At 23.78°N a degree of longitude is cos(23.78) ≈ 0.915 of one at the
      // equator, so the same delta covers less ground east-west than north-south.
      final northSouth = haversineDistance(
        lat1: binLat,
        lng1: binLng,
        lat2: binLat + 0.001,
        lng2: binLng,
      );
      final eastWest = haversineDistance(
        lat1: binLat,
        lng1: binLng,
        lat2: binLat,
        lng2: binLng + 0.001,
      );
      expect(eastWest, closeTo(101.754, 0.05));
      expect(eastWest, lessThan(northSouth));
    });

    test('scales linearly at short range', () {
      final half = haversineDistance(
        lat1: binLat,
        lng1: binLng,
        lat2: binLat + 0.0005,
        lng2: binLng,
      );
      expect(half, closeTo(55.597, 0.05));
    });

    test('handles a cross-city distance', () {
      final d = haversineDistance(
        lat1: binLat,
        lng1: binLng,
        lat2: 23.7925,
        lng2: 90.4078,
      );
      expect(d, closeTo(1301.6, 1.0));
    });

    test('is symmetric', () {
      final forward = haversineDistance(
        lat1: binLat,
        lng1: binLng,
        lat2: 22.3569,
        lng2: 91.7832,
      );
      final backward = haversineDistance(
        lat1: 22.3569,
        lng1: 91.7832,
        lat2: binLat,
        lng2: binLng,
      );
      expect(forward, closeTo(backward, 0.001));
    });

    test('matches known geodesic landmarks', () {
      // One degree of longitude at the equator.
      expect(
        haversineDistance(lat1: 0, lng1: 0, lat2: 0, lng2: 1),
        closeTo(111194.9, 1.0),
      );
      // Equator to pole: a quarter of the circumference.
      expect(
        haversineDistance(lat1: 0, lng1: 0, lat2: 90, lng2: 0),
        closeTo(10007543.4, 1.0),
      );
      // Antipodal points: half the circumference, and no NaN from a rounding
      // error pushing the term above 1.
      final antipodal = haversineDistance(lat1: 0, lng1: 0, lat2: 0, lng2: 180);
      expect(antipodal.isNaN, isFalse);
      expect(antipodal, closeTo(20015086.8, 1.0));
    });

    test('is never negative', () {
      expect(
        haversineDistance(lat1: 10, lng1: 20, lat2: -30, lng2: -40),
        greaterThanOrEqualTo(0),
      );
    });
  });

  group('radius check', () {
    test('accepts a point comfortably inside', () {
      expect(
        isWithinRadius(
          binLat: binLat,
          binLng: binLng,
          capturedLat: binLat + 0.0002, // ~22 m
          capturedLng: binLng,
          radiusMeters: 50,
        ),
        isTrue,
      );
    });

    test('rejects a point outside', () {
      expect(
        isWithinRadius(
          binLat: binLat,
          binLng: binLng,
          capturedLat: binLat + 0.001, // ~111 m
          capturedLng: binLng,
          radiusMeters: 50,
        ),
        isFalse,
      );
    });

    test('is inclusive at the boundary', () {
      // GPS precision makes the edge fuzzy; refusing an honest user for a
      // sub-metre difference is the wrong failure direction.
      const radius = 111.195;
      expect(
        isWithinRadius(
          binLat: binLat,
          binLng: binLng,
          capturedLat: binLat + 0.001,
          capturedLng: binLng,
          radiusMeters: radius + 0.01,
        ),
        isTrue,
      );
    });

    test('a non-positive radius accepts nothing, including the exact spot', () {
      expect(
        isWithinRadius(
          binLat: binLat,
          binLng: binLng,
          capturedLat: binLat,
          capturedLng: binLng,
          radiusMeters: 0,
        ),
        isFalse,
      );
      expect(
        isWithinRadius(
          binLat: binLat,
          binLng: binLng,
          capturedLat: binLat,
          capturedLng: binLng,
          radiusMeters: -10,
        ),
        isFalse,
      );
    });
  });

  group('coordinate validation', () {
    test('accepts real coordinates', () {
      expect(isValidLatitude(23.7808), isTrue);
      expect(isValidLongitude(90.4074), isTrue);
      expect(isPlausibleCoordinate(23.7808, 90.4074), isTrue);
    });

    test('rejects out-of-range values', () {
      expect(isValidLatitude(91), isFalse);
      expect(isValidLatitude(-90.1), isFalse);
      expect(isValidLongitude(180.1), isFalse);
      expect(isValidLongitude(-181), isFalse);
    });

    test('accepts the exact poles and antimeridian', () {
      expect(isValidLatitude(90), isTrue);
      expect(isValidLatitude(-90), isTrue);
      expect(isValidLongitude(180), isTrue);
      expect(isValidLongitude(-180), isTrue);
    });

    test('rejects NaN', () {
      expect(isValidLatitude(double.nan), isFalse);
      expect(isValidLongitude(double.nan), isFalse);
      expect(isPlausibleCoordinate(double.nan, 90.4), isFalse);
    });

    test('rejects null island as a failed fix', () {
      // A real point in the Gulf of Guinea, and never anywhere a bin will be.
      expect(isPlausibleCoordinate(0, 0), isFalse);
      // But a genuine zero on one axis only is fine.
      expect(isPlausibleCoordinate(0, 90.4074), isTrue);
    });
  });

  group('distance formatting', () {
    test('shows whole metres below a kilometre', () {
      expect(formatDistance(0), '0 m');
      expect(formatDistance(42.4), '42 m');
      expect(formatDistance(999.4), '999 m');
    });

    test('shows kilometres above that', () {
      expect(formatDistance(1000), '1.0 km');
      expect(formatDistance(1301.6), '1.3 km');
    });

    test('degrades gracefully on bad input', () {
      expect(formatDistance(double.nan), '—');
      expect(formatDistance(-5), '—');
    });
  });
}
