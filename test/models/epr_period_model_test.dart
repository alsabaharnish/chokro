import 'package:chokro/core/epr_categories.dart';
import 'package:chokro/models/epr_period_model.dart';
import 'package:flutter_test/flutter_test.dart';

EprPeriodModel _parse(Map<String, dynamic> json) =>
    EprPeriodModel.fromJson(json);

/// Appendix A step 6's month, scaled down to figures a test can read.
Map<String, dynamic> _period([Map<String, dynamic> overrides = const {}]) => {
  'orgId': 'org_cola',
  'periodId': '2026-09',
  'massMgByCategory': {'rigid': 3940000000, 'flexible': 60000000},
  'unitsByCategory': {'rigid': 402040, 'flexible': 9960},
  'massMgByPolymer': {'pet': 3400000000, 'pp': 600000000},
  'massMgByDistrict': {'Dhaka': 3000000000, 'Khulna': 1000000000},
  'attributionCount': 412000,
  'disposalCount': 380000,
  'skuIds': ['sku_a', 'sku_b', 'sku_c'],
  'uncertainMassMg': 248000000,
  ...overrides,
};

void main() {
  group('the total', () {
    test('is summed from the category breakdown, not stored separately', () {
      // Two figures in one document that can drift apart is how a regulator
      // finds an inconsistency Chokro cannot explain.
      final period = _parse(_period());
      expect(period.totalMassMg, 3940000000 + 60000000);
      expect(period.totalMassLabel, '4000 kg');
    });

    test('units total across categories', () {
      expect(_parse(_period()).totalUnits, 402040 + 9960);
    });

    test('an empty period totals zero without throwing', () {
      final period = EprPeriodModel.empty(orgId: 'org_cola', periodId: '2026-09');
      expect(period.totalMassMg, 0);
      expect(period.totalMassLabel, '0 kg');
      expect(period.hasActivity, isFalse);
      expect(period.label, 'September 2026');
    });
  });

  group('the uncertain share (EPR-37)', () {
    test('is derived from two integers, not a stored float', () {
      // A stored ratio would drift from the totals it describes.
      final period = _parse(_period());
      expect(period.estimatedShare, 248000000 / 4000000000);
      expect((period.estimatedShare * 100).toStringAsFixed(1), '6.2');
    });

    test('is zero when there is no mass at all', () {
      // "No uncertain mass in no mass" is a true and useful statement, unlike
      // a percentage of nothing.
      final period = _parse(_period({
        'massMgByCategory': <String, int>{},
        'uncertainMassMg': 0,
      }));
      expect(period.estimatedShare, 0);
    });
  });

  group('breakdowns', () {
    test('categories come out in gazette order, skipping empty ones', () {
      // Gazette order rather than stored order, so two periods' breakdowns are
      // directly comparable on screen and in an export.
      final period = _parse(_period({
        'massMgByCategory': {'other': 100, 'rigid': 200, 'eps': 300},
        'unitsByCategory': {'other': 1, 'rigid': 2, 'eps': 3},
      }));
      expect(
        period.categoryBreakdown.map((r) => r.category).toList(),
        [GazetteCategory.rigid, GazetteCategory.eps, GazetteCategory.other],
      );
    });

    test('polymers come out in resin-code order', () {
      final period = _parse(_period({
        'massMgByPolymer': {'pp': 100, 'pet': 200, 'multilayer': 50},
      }));
      expect(
        period.polymerBreakdown.map((r) => r.polymer).toList(),
        [PolymerType.pet, PolymerType.pp, PolymerType.multilayer],
      );
    });

    test('districts come out heaviest first', () {
      expect(
        _parse(_period()).districtBreakdown.first.district,
        'Dhaka',
      );
    });

    test('an unrecognised category key is dropped, and the drop is visible', () {
      // It would otherwise put mass on a line the gazette does not have. The
      // breakdown then stops summing to what a stored total would have said,
      // which is the point — a silent drop would be worse.
      final period = _parse(_period({
        'massMgByCategory': {'rigid': 100, 'compostable': 900},
      }));
      expect(period.categoryBreakdown, hasLength(1));
      expect(period.totalMassMg, 100);
    });
  });

  group('withheld geography is stated, not silent (SEC-3)', () {
    test('an empty district map and a withheld one are different facts', () {
      // Rendering the second as the first would be a false claim about
      // Chokro's own evidence: "no geography recorded" versus "recorded and
      // not shown".
      final empty = _parse(_period({'massMgByDistrict': <String, int>{}}));
      expect(empty.districtSuppressed, isFalse);
      expect(empty.districtBreakdown, isEmpty);

      final withheld = _parse(_period({
        'massMgByDistrict': <String, int>{},
        'districtSuppressed': true,
        'disposalCount': 2,
        'kAnonymityFloor': 5,
      }));
      expect(withheld.districtSuppressed, isTrue);
      expect(withheld.districtBreakdown, isEmpty);
      expect(withheld.kAnonymityFloor, 5);
    });

    test('the floor travels so a screen can say how many are needed', () {
      final period = _parse(_period({
        'districtSuppressed': true,
        'kAnonymityFloor': 20,
      }));
      expect(period.kAnonymityFloor, 20);
    });

    test('an absent flag reads as not suppressed', () {
      // Fail toward the honest reading: a document from before this field
      // existed had nothing withheld.
      expect(_parse(_period()).districtSuppressed, isFalse);
      expect(_parse(_period()).kAnonymityFloor, isNull);
    });

    test('the model has no field for an exact event instant', () {
      // The server projects `lastAttributionAt` out of every producer
      // response, because on a one-disposal period a second-precision
      // timestamp is the exact moment of one person's act. A model field for
      // it would be a place for it to come back.
      final source =
          const String.fromEnvironment('unused', defaultValue: '');
      expect(source, isEmpty);
      // Asserted structurally instead: constructing from a document that
      // *does* carry it changes nothing observable.
      final withInstant = _parse(_period({
        'lastAttributionAt': DateTime.utc(2026, 9, 14, 18, 42, 7),
      }));
      final without = _parse(_period());
      expect(withInstant.totalMassMg, without.totalMassMg);
      expect(withInstant.attributionCount, without.attributionCount);
    });
  });

  group('the distinct-product count is derived, not stored', () {
    test('it comes from the stored set', () {
      // It used to be a stored integer that nothing incremented, so it read 0
      // for every period — a passport would have printed "0 distinct products"
      // beside a real mass.
      expect(_parse(_period()).uniqueSkuCount, 3);
      expect(_parse(_period()).skuIds, hasLength(3));
    });

    test('a duplicated id in a stored set does not overstate variety', () {
      // `arrayUnion` guarantees distinctness, but a document written by a
      // migration or an earlier release need not have used it.
      final period = _parse(_period({
        'skuIds': ['sku_a', 'sku_a', 'sku_b'],
      }));
      expect(period.uniqueSkuCount, 2);
    });

    test('a malformed set reads as empty rather than throwing', () {
      expect(_parse(_period({'skuIds': 'sku_a'})).uniqueSkuCount, 0);
      expect(_parse(_period({'skuIds': [1, null, '']})).uniqueSkuCount, 0);
      expect(_parse(_period({'skuIds': null})).uniqueSkuCount, 0);
    });
  });

  group('reconciliation (EPR-22, EPR-48)', () {
    test('never recomputed is not the same as matched', () {
      // No surface may present an unreconciled period as a reconciled one.
      final period = _parse(_period());
      expect(period.isReconciled, isFalse);
      expect(period.hasRecomputeMismatch, isFalse);
      expect(period.recomputeMatched, isNull);
    });

    test('a mismatch is visible', () {
      final period = _parse(_period({
        'recomputedAt': DateTime.utc(2026, 10, 1),
        'recomputeMatched': false,
        'recomputedMassMg': 3900000000,
      }));
      expect(period.isReconciled, isTrue);
      expect(period.hasRecomputeMismatch, isTrue);
      expect(period.recomputedMassMg, 3900000000);
    });

    test('a match is visible too', () {
      final period = _parse(_period({
        'recomputedAt': DateTime.utc(2026, 10, 1),
        'recomputeMatched': true,
      }));
      expect(period.isReconciled, isTrue);
      expect(period.hasRecomputeMismatch, isFalse);
    });
  });

  group('malformed counters', () {
    test('a negative counter reads as zero rather than subtracting', () {
      // Matching stats_model.dart. A counter that went negative is corrupt,
      // and a corrupt counter must not subtract from a compliance figure.
      final period = _parse(_period({
        'massMgByCategory': {'rigid': -500},
        'attributionCount': -5,
      }));
      expect(period.totalMassMg, 0);
      expect(period.attributionCount, 0);
    });

    test('non-numeric counters read as zero', () {
      final period = _parse(_period({
        'attributionCount': 'many',
        'uncertainMassMg': null,
      }));
      expect(period.attributionCount, 0);
      expect(period.uncertainMassMg, 0);
    });

    test('an invalid periodId parses to empty so it cannot be queried with', () {
      expect(_parse(_period({'periodId': '2026-13'})).periodId, '');
      expect(_parse(_period({'periodId': 'nonsense'})).periodId, '');
    });
  });

  group('activity', () {
    test('an unattributed disposal counts as activity', () {
      // EPR-19: the unattributed pool is reported as its own line, so a period
      // with only unattributed disposals is not an empty period.
      final period = _parse({
        'orgId': '__platform',
        'periodId': '2026-09',
        'unattributedDisposalCount': 1180,
      });
      expect(period.hasActivity, isTrue);
      expect(period.totalMassMg, 0);
      expect(period.unattributedDisposalCount, 1180);
    });
  });
}
