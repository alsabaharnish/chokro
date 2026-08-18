import 'package:chokro/core/points_policy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Provenance of the last policy change (F3.3).
///
/// The server has recorded `updatedAt` and `updatedBy` on every policy write
/// since the endpoint existed, and `policyModule.fromDoc` strips both because
/// `validate()` depends on an exact key set — so neither ever reached a person.
/// These cover the parsing that now carries them through, and in particular the
/// distinction the screen depends on: an absent document means untouched
/// defaults, which is different information from somebody having set the
/// defaults deliberately.

void main() {
  group('PolicyProvenance.fromJson', () {
    test('reads a recorded change', () {
      final provenance = PolicyProvenance.fromJson({
        'updatedAt': '2026-08-18T09:30:00.000Z',
        'updatedBy': 'admin-uid',
        'updatedByName': 'Nabil',
      });

      expect(provenance.updatedAt?.toUtc(), DateTime.utc(2026, 8, 18, 9, 30));
      expect(provenance.updatedBy, 'admin-uid');
      expect(provenance.updatedByName, 'Nabil');
      expect(provenance.isUntouched, isFalse);
      expect(provenance.editor, 'Nabil');
    });

    test('an absent document reads as untouched', () {
      // The policy numbers in this case are the §7.3 defaults. Saying "never
      // changed" is a stronger and more useful statement than showing a blank
      // date, and it is the only one an absent document actually supports.
      final provenance = PolicyProvenance.fromJson({
        'disposalAward': 50,
        'updatedAt': null,
        'updatedBy': null,
        'updatedByName': null,
      });

      expect(provenance.isUntouched, isTrue);
      expect(provenance.updatedAt, isNull);
    });

    test('missing keys do not throw', () {
      // An older server build, or a response from before this field existed.
      final provenance = PolicyProvenance.fromJson({'disposalAward': 50});
      expect(provenance.isUntouched, isTrue);
    });

    test('falls back to the uid when the name could not be resolved', () {
      // A deleted account, or a failed lookup the server logged and moved past.
      // A uid is poor but it is true, and it is better than an empty sentence.
      final provenance = PolicyProvenance.fromJson({
        'updatedAt': '2026-08-18T09:30:00.000Z',
        'updatedBy': 'admin-uid',
        'updatedByName': null,
      });

      expect(provenance.editor, 'admin-uid');
      expect(provenance.isUntouched, isFalse);
    });

    test('falls back again when even the uid is absent', () {
      final provenance = PolicyProvenance.fromJson({
        'updatedAt': '2026-08-18T09:30:00.000Z',
      });

      expect(provenance.editor, 'an administrator');
    });

    test('an unparseable date reads as untouched rather than throwing', () {
      final provenance = PolicyProvenance.fromJson({'updatedAt': 'not a date'});
      expect(provenance.updatedAt, isNull);
      expect(provenance.isUntouched, isTrue);
    });

    test('a non-string date does not throw', () {
      expect(
        PolicyProvenance.fromJson({'updatedAt': 1755511800000}).updatedAt,
        isNull,
      );
    });
  });

  group('PolicySnapshot.fromJson', () {
    test('reads the policy and the provenance from one object', () {
      // They share a flat JSON object so the editor gets both from a single
      // request — every award calculation reads the policy, and provenance is
      // not worth a second round trip.
      final snapshot = PolicySnapshot.fromJson({
        'disposalAward': 40,
        'claimAward': 15,
        'updatedAt': '2026-08-18T09:30:00.000Z',
        'updatedByName': 'Nabil',
      });

      expect(snapshot.policy.disposalAward, 40);
      expect(snapshot.policy.claimAward, 15);
      expect(snapshot.provenance.editor, 'Nabil');
    });

    test('provenance keys do not disturb the policy parse', () {
      // `PointsPolicy.fromJson` reads the keys it knows and ignores the rest,
      // which is what makes the extra fields additive.
      final snapshot = PolicySnapshot.fromJson({
        'disposalAward': 50,
        'updatedAt': '2026-08-18T09:30:00.000Z',
        'updatedBy': 'admin-uid',
        'updatedByName': 'Nabil',
      });

      expect(snapshot.policy.validate(), isEmpty);
      expect(snapshot.policy.disposalAward, 50);
    });

    test('an empty object yields defaults and untouched provenance', () {
      final snapshot = PolicySnapshot.fromJson({});

      expect(snapshot.policy.disposalAward, PointsPolicyDefaults.disposalAward);
      expect(snapshot.provenance.isUntouched, isTrue);
    });
  });
}
