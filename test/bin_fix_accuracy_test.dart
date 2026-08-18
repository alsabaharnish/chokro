import 'package:chokro/core/geo.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rule that decides whether a GPS fix is precise enough to register a bin
/// on (F2.1).
///
/// Worth testing on its own because getting it wrong is invisible: a bin
/// registered from a rough fix works perfectly for the administrator standing
/// next to it and then quietly refuses residents forever after.
void main() {
  group('isFixTooRoughForRadius', () {
    test('a good fix on a tight street bin passes', () {
      expect(
        isFixTooRoughForRadius(accuracyMeters: 8, radiusMeters: 50),
        isFalse,
      );
    });

    test('a rough fix on a tight street bin is refused', () {
      // ±35 m inside a 50 m radius: the centre alone can eat 70% of the margin.
      expect(
        isFixTooRoughForRadius(accuracyMeters: 35, radiusMeters: 50),
        isTrue,
      );
    });

    test('the same rough fix is fine for a large compound', () {
      // The point of judging against the radius rather than a fixed number.
      expect(
        isFixTooRoughForRadius(accuracyMeters: 35, radiusMeters: 200),
        isFalse,
      );
    });

    test('exactly half the radius is accepted', () {
      // The boundary is inclusive on the passing side, matching
      // `isWithinRadius`: refusing an administrator at the exact threshold
      // would be arbitrary.
      expect(
        isFixTooRoughForRadius(accuracyMeters: 25, radiusMeters: 50),
        isFalse,
      );
      expect(
        isFixTooRoughForRadius(accuracyMeters: 25.1, radiusMeters: 50),
        isTrue,
      );
    });

    test('an unknown accuracy is not reported as too rough', () {
      // Some platforms report no accuracy at all. Claiming the fix is bad on no
      // evidence would block registration for a reason nobody could act on.
      expect(
        isFixTooRoughForRadius(accuracyMeters: null, radiusMeters: 50),
        isFalse,
      );
    });

    test('a radius not yet typed in is not judged', () {
      // The administrator can clear the radius field mid-form. There is nothing
      // to compare against until they type one.
      expect(
        isFixTooRoughForRadius(accuracyMeters: 40, radiusMeters: null),
        isFalse,
      );
    });

    test('a nonsensical radius is left to the validator', () {
      // `BinModel.validate` and the server both refuse these with a message of
      // their own; this rule must not also fire and produce two complaints
      // about one field.
      expect(
        isFixTooRoughForRadius(accuracyMeters: 40, radiusMeters: 0),
        isFalse,
      );
      expect(
        isFixTooRoughForRadius(accuracyMeters: 40, radiusMeters: -50),
        isFalse,
      );
    });

    test('NaN never reports a verdict', () {
      expect(
        isFixTooRoughForRadius(accuracyMeters: double.nan, radiusMeters: 50),
        isFalse,
      );
      expect(
        isFixTooRoughForRadius(accuracyMeters: 10, radiusMeters: double.nan),
        isFalse,
      );
    });

    test('a very precise fix passes even the tightest sane radius', () {
      // 1000 m is the ceiling `BinModel.validate` enforces; 5 m is a good
      // open-sky phone fix. Neither end of the range should misbehave.
      expect(
        isFixTooRoughForRadius(accuracyMeters: 5, radiusMeters: 11),
        isFalse,
      );
      expect(
        isFixTooRoughForRadius(accuracyMeters: 5, radiusMeters: 1000),
        isFalse,
      );
    });
  });
}
