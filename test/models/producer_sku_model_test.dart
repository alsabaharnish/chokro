import 'package:chokro/core/epr_categories.dart';
import 'package:chokro/core/mass_math.dart';
import 'package:chokro/models/producer_sku_model.dart';
import 'package:flutter_test/flutter_test.dart';

ProducerSkuModel _parse(Map<String, dynamic> json) =>
    ProducerSkuModel.fromJson(json, id: 'sku-1');

/// Appendix A's bottle, as a stored document.
Map<String, dynamic> _bottle({
  String massStatus = MassStatus.verified,
  Object? verifiedMg = 9800,
}) => <String, dynamic>{
  'orgId': 'org_cola',
  'name': 'Coca-Cola 250 ml PET bottle',
  'brand': 'Coca-Cola',
  'gtin': '8901234567890',
  'volumeMl': 250,
  'gazetteCategory': GazetteCategory.rigid,
  'polymer': PolymerType.pet,
  'declaredUnitMassMg': 10000,
  'components': [
    {'part': 'body', 'polymer': 'pet', 'massMg': 8200},
    {'part': 'cap', 'polymer': 'pp', 'massMg': 1300},
    {'part': 'label', 'polymer': 'pet', 'massMg': 500},
  ],
  'sampleImageUrls': ['https://a/1.jpg', 'https://a/2.jpg'],
  'massStatus': massStatus,
  'verifiedUnitMassMg': verifiedMg,
  'revision': 1,
  'status': SkuStatus.active,
};

void main() {
  group('the mass a report may use (EPR-11)', () {
    test('is the verified mass, never the declared one', () {
      // Appendix A step 3: reporting uses 9.8, not the declared 10.0.
      final sku = _parse(_bottle());
      expect(sku.declaredUnitMassMg, 10000);
      expect(sku.reportableUnitMassMg, 9800);
      expect(sku.hasVerifiedMass, isTrue);
    });

    test('is null while the mass is only submitted', () {
      final sku = _parse(_bottle(massStatus: MassStatus.submitted));
      expect(sku.isAwaitingVerification, isTrue);
      expect(sku.reportableUnitMassMg, isNull);
      expect(sku.hasVerifiedMass, isFalse);
    });

    test('is null for every non-verified status, even with a mass stored', () {
      // The failure this prevents: a producer-supplied figure reaching a
      // regulatory report because a status field was something unexpected.
      for (final status in [
        MassStatus.draft,
        MassStatus.rejected,
        MassStatus.superseded,
      ]) {
        expect(
          _parse(_bottle(massStatus: status)).reportableUnitMassMg,
          isNull,
          reason: '$status must not be reportable',
        );
      }
    });

    test('an unrecognised mass status fails closed to draft', () {
      final sku = _parse(_bottle(massStatus: 'approvedish'));
      expect(sku.massStatus, MassStatus.draft);
      expect(sku.reportableUnitMassMg, isNull);
    });

    test('verified with no stored mass is still not reportable', () {
      expect(
        _parse(_bottle(verifiedMg: null)).reportableUnitMassMg,
        isNull,
      );
    });
  });

  group('effective dating (EPR-12)', () {
    ProducerSkuModel revision({DateTime? from, DateTime? to}) => _parse({
      ..._bottle(),
      'activeFrom': from,
      'activeTo': to,
    });

    test('an open revision is in force from its start date onward', () {
      final sku = revision(from: DateTime.utc(2026, 9, 1));
      expect(sku.wasActiveAt(DateTime.utc(2026, 9, 1)), isTrue);
      expect(sku.wasActiveAt(DateTime.utc(2027, 1, 1)), isTrue);
      expect(sku.wasActiveAt(DateTime.utc(2026, 8, 31)), isFalse);
    });

    test('a closed revision stops at its end date', () {
      // Appendix A step 11: revision 1 stays correct for September after a
      // November re-weighing opens revision 2.
      final sku = revision(
        from: DateTime.utc(2026, 9, 1),
        to: DateTime.utc(2026, 11, 1),
      );
      expect(sku.wasActiveAt(DateTime.utc(2026, 9, 15)), isTrue);
      expect(sku.wasActiveAt(DateTime.utc(2026, 10, 31, 23, 59)), isTrue);
      expect(sku.wasActiveAt(DateTime.utc(2026, 11, 1)), isFalse);
      expect(sku.wasActiveAt(DateTime.utc(2026, 12, 1)), isFalse);
    });

    test('a revision with no start date was never in force', () {
      // Fail closed. An undated revision must not silently apply to every
      // disposal ever recorded.
      final sku = revision();
      expect(sku.wasActiveAt(DateTime.utc(2026, 9, 15)), isFalse);
    });
  });

  group('the component breakdown (EPR-9)', () {
    test('splits one unit across two polymer lines', () {
      // The whole reason components exist: one recognised unit contributing
      // grams to more than one polymer while remaining one unit.
      expect(_parse(_bottle()).massByPolymerMg, {'pet': 8700, 'pp': 1300});
    });

    test('balances against the declared unit mass', () {
      expect(_parse(_bottle()).componentsBalance, isTrue);
    });

    test('one milligram out does not balance', () {
      final sku = _parse({
        ..._bottle(),
        'components': [
          {'part': 'body', 'polymer': 'pet', 'massMg': 8201},
          {'part': 'cap', 'polymer': 'pp', 'massMg': 1300},
          {'part': 'label', 'polymer': 'pet', 'massMg': 500},
        ],
      });
      expect(sku.componentsBalance, isFalse);
    });

    test('a component with an unknown polymer is dropped, not defaulted', () {
      // A defaulted polymer would put grams on the wrong gazette line.
      final sku = _parse({
        ..._bottle(),
        'components': [
          {'part': 'body', 'polymer': 'pet', 'massMg': 8200},
          {'part': 'cap', 'polymer': 'unobtainium', 'massMg': 1300},
        ],
      });
      expect(sku.components, hasLength(1));
      // And the drop is visible, because the breakdown no longer balances.
      expect(sku.componentsBalance, isFalse);
    });

    test('no components means no polymer breakdown, not a guess', () {
      // Attributing the whole unit mass to the dominant polymer is a guess, and
      // §6.7 forbids a figure whose provenance cannot be traced field by field.
      final sku = _parse({..._bottle(), 'components': <Object>[]});
      expect(sku.massByPolymerMg, isEmpty);
    });

    test('a component in grams is read, for a migrated document', () {
      final sku = _parse({
        ..._bottle(),
        'components': [
          {'part': 'body', 'polymer': 'pet', 'massGrams': 8.2},
        ],
      });
      expect(sku.components.single.massMg, 8200);
    });
  });

  group('submission requirements (EPR-9)', () {
    ProducerSkuModel draft(Map<String, dynamic> overrides) =>
        _parse({..._bottle(massStatus: MassStatus.draft), ...overrides});

    test('a complete draft may be submitted', () {
      expect(draft(const {}).canSubmit, isTrue);
      expect(draft(const {}).submissionProblems, isEmpty);
    });

    test('fewer than two sample photographs blocks submission', () {
      expect(
        draft({'sampleImageUrls': ['https://a/1.jpg']}).submissionProblems.join(' '),
        contains('two sample photographs'),
      );
    });

    test('more than six is refused too', () {
      expect(
        draft({
          'sampleImageUrls': [
            for (var i = 0; i < 7; i += 1) 'https://a/$i.jpg',
          ],
        }).canSubmit,
        isFalse,
      );
    });

    test('an unbalanced breakdown blocks submission and shows both figures', () {
      final problems = draft({
        'components': [
          {'part': 'body', 'polymer': 'pet', 'massMg': 8200},
        ],
      }).submissionProblems.join(' ');
      expect(problems, contains('8.2 g'));
      expect(problems, contains('10 g'));
    });

    test('no components at all blocks submission', () {
      expect(
        draft({'components': <Object>[]}).submissionProblems.join(' '),
        contains('parts'),
      );
    });

    test('every problem is reported at once, not the first', () {
      final problems = draft({
        'name': 'X',
        'brand': '',
        'gazetteCategory': 'nope',
        'polymer': 'nope',
        'sampleImageUrls': <Object>[],
        'components': <Object>[],
      }).submissionProblems;
      expect(problems.length, greaterThanOrEqualTo(5));
    });
  });

  group('the draft payload', () {
    test('carries no server-owned key', () {
      final json = _parse(_bottle()).toDraftJson();

      for (final serverOwned in [
        'massStatus',
        'verifiedUnitMassMg',
        'verifiedUnitMassG',
        'verifiedBy',
        'verifiedAt',
        'activeFrom',
        'activeTo',
        'revision',
        'createdAt',
        'rejectionReason',
      ]) {
        expect(
          json.containsKey(serverOwned),
          isFalse,
          reason: '$serverOwned is server-owned and must not be proposed',
        );
      }
    });

    test('carries the declared mass in both units, milligrams authoritative', () {
      final json = _parse(_bottle()).toDraftJson();
      expect(json['declaredUnitMassMg'], 10000);
      expect(json['declaredUnitMassG'], 10.0);
    });
  });

  group('copyWith cannot reach a server-owned field', () {
    test('the verified mass and revision survive an edit untouched', () {
      final original = _parse(_bottle());
      final edited = original.copyWith(name: 'Renamed', declaredUnitMassMg: 9000);

      expect(edited.name, 'Renamed');
      expect(edited.declaredUnitMassMg, 9000);
      // A client editing its declaration must not be able to move the figure
      // reporting uses.
      expect(edited.verifiedUnitMassMg, 9800);
      expect(edited.massStatus, MassStatus.verified);
      expect(edited.revision, 1);
    });
  });

  group('malformed documents', () {
    test('an unrecognised category or polymer parses to empty, not a guess', () {
      final sku = _parse({
        ..._bottle(),
        'gazetteCategory': 'compostable',
        'polymer': 'unobtainium',
      });
      expect(sku.gazetteCategory, '');
      expect(sku.polymer, '');
      expect(sku.canSubmit, isFalse);
    });

    test('an empty document does not throw and can do nothing', () {
      final sku = _parse(const {});
      expect(sku.declaredUnitMassMg, 0);
      expect(sku.reportableUnitMassMg, isNull);
      expect(sku.canSubmit, isFalse);
      expect(sku.massByPolymerMg, isEmpty);
    });

    test('a gram-valued declared mass is read, for a migrated document', () {
      final sku = _parse({
        ..._bottle(),
        'declaredUnitMassMg': null,
        'declaredUnitMassG': 10.0,
      });
      expect(sku.declaredUnitMassMg, 10000);
    });

    test('an out-of-bounds stored mass does not become a submittable one', () {
      final sku = _parse({
        ..._bottle(massStatus: MassStatus.draft),
        'declaredUnitMassMg': maxUnitMassMg + 1,
      });
      expect(sku.canSubmit, isFalse);
    });
  });
}
