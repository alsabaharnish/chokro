/// Regulator disclosure models (SEC-13).
///
/// Every test here is about a value that must not be allowed to render as
/// something milder than it is: a refusal that could look like a blank, a
/// truncated register that could look complete, a stopped-early search that
/// could look like a not-found.
library;

import 'package:chokro/models/disclosure_model.dart';
import 'package:chokro/services/location_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('location records its own absence', () {
    test('a refusal is denied, not unavailable', () {
      // "Would not say" and "could not say" are different things to read six
      // months later — one is a choice.
      for (final outcome in [
        LocationOutcome.denied,
        LocationOutcome.deniedForever,
      ]) {
        final l = DisclosureLocation.fromResult(LocationResult(outcome: outcome));
        expect(l.status, 'denied');
        expect(l.label, 'Refused by the Admin’s device');
      }
    });

    test('a timeout or disabled radio is unavailable, not denied', () {
      for (final outcome in [
        LocationOutcome.timedOut,
        LocationOutcome.serviceDisabled,
        LocationOutcome.error,
      ]) {
        expect(
          DisclosureLocation.fromResult(LocationResult(outcome: outcome)).status,
          'unavailable',
        );
      }
    });

    test('a fix carries coordinates and accuracy', () {
      final l = DisclosureLocation.fromResult(
        const LocationResult(
          outcome: LocationOutcome.fixed,
          latitude: 23.8103,
          longitude: 90.4125,
          accuracyMeters: 12.4,
        ),
      );
      expect(l.status, 'granted');
      expect(l.hasCoordinates, isTrue);
      expect(l.label, '23.81030, 90.41250 ±12m');
    });

    test('a "fixed" outcome with no coordinates is not granted', () {
      final l = DisclosureLocation.fromResult(
        const LocationResult(outcome: LocationOutcome.fixed),
      );
      expect(l.status, 'unavailable');
    });

    test('the label is never a dash and never empty', () {
      for (final status in ['granted', 'denied', 'unavailable', 'nonsense']) {
        final l = DisclosureLocation.fromJson({'status': status});
        expect(l.label.trim(), isNotEmpty);
        expect(l.label, isNot('—'));
      }
    });

    test('an unrecognised status reads as unavailable', () {
      expect(DisclosureLocation.fromJson({'status': 'somewhere'}).status,
          'unavailable');
    });
  });

  group('a stopped-early search is not a not-found', () {
    test('an absent `exhaustive` reads as NOT exhaustive', () {
      // A missing field must never become the stronger claim. Telling a
      // regulator a genuine row is unknown is the worst answer this can give.
      final r = DisclosureResult.fromJson(const {'found': false});
      expect(r.exhaustive, isFalse);
    });

    test('an exhaustive not-found is distinguishable', () {
      final r = DisclosureResult.fromJson(const {
        'found': false,
        'exhaustive': true,
        'note': 'Check the organisation',
      });
      expect(r.found, isFalse);
      expect(r.exhaustive, isTrue);
    });
  });

  group('the result carries what an exhibit needs', () {
    test('an unkeyed reference is reported, not dropped', () {
      final r = DisclosureResult.fromJson(const {
        'found': true,
        'exhaustive': true,
        'referenceKeyed': false,
        'disposalId': 'd1',
        'evidence': {'disposalPresent': true, 'binId': 'bin-7'},
        'attributions': [],
      });
      expect(r.referenceKeyed, isFalse);
      expect(r.binId, 'bin-7');
    });

    test('an absent referenceKeyed is null, not false', () {
      // Null means "the server did not say"; false means "minted unkeyed".
      // Conflating them would put a caveat on an exhibit that does not need one.
      final r = DisclosureResult.fromJson(const {'found': true});
      expect(r.referenceKeyed, isNull);
    });

    test('an erased disposal still carries its attributions', () {
      final r = DisclosureResult.fromJson(const {
        'found': true,
        'exhaustive': true,
        'evidence': {'disposalPresent': false},
        'attributions': [
          {'attributionId': 'a1', 'massMg': 21000, 'periodId': '2026-09'},
        ],
      });
      expect(r.disposalPresent, isFalse);
      expect(r.attributions, hasLength(1));
      expect(r.attributions.first.massMg, 21000);
    });

    test('a failed register write leaves a null id rather than a fake one', () {
      final r = DisclosureResult.fromJson(const {'found': true});
      expect(r.registerId, isNull);
    });
  });

  group('the register', () {
    test('an absent `complete` reads as INCOMPLETE', () {
      // The one place a missing row matters most, so the reassuring reading is
      // never the default.
      final r = DisclosureRegister.fromJson(const {'entries': []});
      expect(r.complete, isFalse);
    });

    test('an identity release is distinguishable from a resolution', () {
      final resolve = DisclosureRecord.fromJson(const {'id': 'r1', 'kind': 'resolve'});
      final identity = DisclosureRecord.fromJson(const {'id': 'r2', 'kind': 'identity'});
      expect(resolve.namedAPerson, isFalse);
      expect(identity.namedAPerson, isTrue);
    });

    test('an entry with no location still reports a status', () {
      final e = DisclosureRecord.fromJson(const {'id': 'r1', 'kind': 'resolve'});
      expect(e.location.status, 'unavailable');
      expect(e.location.label, 'Not available');
    });

    test('an unparseable timestamp is null rather than an epoch', () {
      // Rendering 1 January 1970 as the time of a privileged access would be
      // worse than saying the time was not recorded.
      final e = DisclosureRecord.fromJson(const {'id': 'r1', 'at': 'not a date'});
      expect(e.at, isNull);
    });

    test('the declaration survives round-tripping verbatim', () {
      const why = 'Answering the DoE audit of Padma Beverages, quarter three.';
      final e = DisclosureRecord.fromJson(const {'id': 'r1', 'declaration': why});
      expect(e.declaration, why);
    });
  });
}
