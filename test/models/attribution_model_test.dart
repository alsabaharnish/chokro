import 'package:chokro/core/epr_categories.dart';
import 'package:chokro/models/attribution_model.dart';
import 'package:flutter_test/flutter_test.dart';

AttributionModel _parse(Map<String, dynamic> json) =>
    AttributionModel.fromJson(json, id: 'attr-1');

/// Appendix A step 5, as a stored row.
Map<String, dynamic> _row([Map<String, dynamic> overrides = const {}]) => {
  'disposalId': 'disposal_anik',
  'orgId': 'org_cola',
  'skuId': 'sku_cola',
  'skuRevision': 1,
  'units': 2,
  'unitMassMgUsed': 9800,
  'massMg': 19600,
  'massMgByPolymer': {'pet': 17052, 'pp': 2548},
  'method': AttributionMethod.aiSku,
  'confidence': 0.91,
  'confidenceTier': ConfidenceTier.high,
  'periodId': '2026-09',
  'binId': 'MHP-014',
  'district': 'Dhaka',
  'gazetteCategory': GazetteCategory.rigid,
  'polymer': PolymerType.pet,
  ...overrides,
};

void main() {
  group('the worked example', () {
    test('parses every field a report would need', () {
      final row = _parse(_row());
      expect(row.units, 2);
      expect(row.unitMassMgUsed, 9800);
      expect(row.massMg, 19600);
      expect(row.skuRevision, 1);
      expect(row.periodId, '2026-09');
      expect(row.method, AttributionMethod.aiSku);
      expect(row.confidenceTier, ConfidenceTier.high);
      expect(row.massLabel, '19.6 g');
      expect(row.isReportable, isTrue);
    });

    test('the polymer split is kept and adds up to the mass', () {
      final row = _parse(_row());
      expect(row.massMgByPolymer, {'pet': 17052, 'pp': 2548});
      expect(
        row.massMgByPolymer.values.reduce((a, b) => a + b),
        row.massMg,
      );
    });
  });

  group('reportability', () {
    test('a reversed row is never reportable', () {
      // Reversed, never deleted (EPR-21) — so a reader must check.
      final row = _parse(_row({'reversedAt': DateTime.utc(2026, 10), 'reversedBy': 'admin_1'}));
      expect(row.isReversed, isTrue);
      expect(row.isReportable, isFalse);
    });

    test('a low-confidence row is never reportable', () {
      // EPR-17: a low match is not attributed at all, so a stored one is a
      // data problem and must not reach a figure.
      expect(
        _parse(_row({'confidenceTier': ConfidenceTier.low})).isReportable,
        isFalse,
      );
    });

    test('an unrecognised method is not reportable', () {
      // EPR-19: if a category-average estimate is ever introduced it must be a
      // distinct method value excluded from the headline figure. Failing closed
      // on an unknown method is what makes that enforceable rather than
      // conventional.
      final row = _parse(_row({'method': 'categoryAverage'}));
      expect(row.method, '');
      expect(row.isReportable, isFalse);
    });

    test('every known method is reportable today', () {
      for (final method in AttributionMethod.all) {
        expect(
          _parse(_row({'method': method})).isReportable,
          isTrue,
          reason: '$method should be reportable',
        );
      }
    });

    test('a medium row is reportable and flagged as uncertain', () {
      final row = _parse(_row({'confidenceTier': ConfidenceTier.medium}));
      expect(row.isReportable, isTrue);
      expect(row.isUncertain, isTrue);
      expect(_parse(_row()).isUncertain, isFalse);
    });
  });

  group('malformed rows fail closed', () {
    test('an unrecognised tier reads as low, not high', () {
      // Defaulting to high would let an unrated row into a reported figure.
      final row = _parse(_row({'confidenceTier': 'certain'}));
      expect(row.confidenceTier, ConfidenceTier.low);
      expect(row.isReportable, isFalse);
    });

    test('an unrecognised category or polymer parses to empty', () {
      final row = _parse(_row({
        'gazetteCategory': 'compostable',
        'polymer': 'unobtainium',
      }));
      expect(row.gazetteCategory, '');
      expect(row.polymer, '');
    });

    test('an unrecognised polymer key is dropped from the split', () {
      // It would otherwise put grams on a line the gazette does not have — and
      // the drop is visible, because the split then stops summing to the mass.
      final row = _parse(_row({
        'massMgByPolymer': {'pet': 17052, 'unobtainium': 2548},
      }));
      expect(row.massMgByPolymer, {'pet': 17052});
      expect(
        row.massMgByPolymer.values.fold(0, (a, b) => a + b),
        isNot(row.massMg),
      );
    });

    test('a negative mass in the split is dropped', () {
      final row = _parse(_row({'massMgByPolymer': {'pet': -100}}));
      expect(row.massMgByPolymer, isEmpty);
    });

    test('an empty document does not throw and reports nothing', () {
      final row = _parse(const {});
      expect(row.massMg, 0);
      expect(row.units, 0);
      expect(row.isReportable, isFalse);
      expect(row.massMgByPolymer, isEmpty);
    });
  });

  group('the barcode method', () {
    test('carries no confidence, honestly', () {
      // A read barcode is not a probabilistic judgement, and storing 1.0 would
      // put a fabricated certainty into the published accuracy statistics.
      final row = _parse(_row({
        'method': AttributionMethod.barcode,
        'confidence': null,
      }));
      expect(row.confidence, isNull);
      expect(row.confidenceTier, ConfidenceTier.high);
      expect(row.isReportable, isTrue);
    });
  });

  group('the wire vocabulary', () {
    test('keeps its stored values (QA-6)', () {
      expect(AttributionMethod.all, [
        'aiSku',
        'barcode',
        'humanReview',
        'manualAdmin',
      ]);
      expect(ConfidenceTier.all, ['high', 'medium', 'low']);
      expect(AttributionStatus.all, [
        'none',
        'pending',
        'attributed',
        'unattributable',
      ]);
    });
  });
}
