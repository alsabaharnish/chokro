import 'package:chokro/core/carbon_math.dart';
import 'package:chokro/core/compliance_math.dart';
import 'package:chokro/models/epr_period_model.dart';
import 'package:chokro/models/producer_sdg_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// A producer's SDG alignment (EPR-36, EPR-37).
///
/// EPR-36 asks for "a pure, testable derivation with no arithmetic in the
/// view". This is the test that derivation exists to make possible — and most
/// of it is about what the cards refuse to claim.
void main() {
  EprPeriodModel period({
    Map<String, int> byCategory = const {'rigid': 4000000000, 'flexible': 1000000000},
    Map<String, int> byDistrict = const {'Dhaka': 3000000000, 'Chattogram': 2000000000},
    int attributionCount = 1200,
    int disposalCount = 900,
    int uncertainMassMg = 0,
    int reversedCount = 0,
    bool districtSuppressed = false,
    List<String> skuIds = const ['sku_a', 'sku_b'],
  }) => EprPeriodModel.fromJson({
    'orgId': 'org_cola',
    'periodId': '2026-09',
    'massMgByCategory': byCategory,
    'massMgByDistrict': byDistrict,
    'attributionCount': attributionCount,
    'disposalCount': disposalCount,
    'uncertainMassMg': uncertainMassMg,
    'reversedCount': reversedCount,
    'districtSuppressed': districtSuppressed,
    'skuIds': skuIds,
  });

  ProducerSdgSnapshot build({
    EprPeriodModel? from,
    CollectionRate? rate,
    CarbonEstimate? carbon,
  }) {
    final p = from ?? period();
    return ProducerSdgSnapshot.from(
      period: p,
      collectionRate: rate ??
          collectionRate(
            collectedMassMg: p.totalMassMg,
            declaredMassMg: 20000000000,
            hasDeclaration: true,
          ),
      carbon: carbon ??
          carbonAvoided(
            massMg: p.totalMassMg,
            factor: turnerMixedPlastics2015,
            estimatedShare: p.estimatedShare,
            uncertaintyCeiling: carbonUncertaintyCeiling,
          ),
    );
  }

  group('the alignments', () {
    test('are the five EPR-36 names, in its order', () {
      final goals = build().alignments.map((a) => a.goal).toList();
      expect(goals, [12, 11, 13, 8, 17]);
    });

    test('every one states a boundary', () {
      // An alignment without its stated limit is exactly the claim section 11
      // forbids. The model makes `boundary` required with no default so a sixth
      // cannot be added without one; this checks none is empty or perfunctory.
      for (final alignment in build().alignments) {
        expect(alignment.boundary.trim(), isNotEmpty, reason: 'goal ${alignment.goal}');
        expect(
          alignment.boundary.length,
          greaterThan(40),
          reason: 'goal ${alignment.goal} boundary is too short to be a limit',
        );
      }
    });

    test('never claim recycling, a credit, an offset, or jobs', () {
      // The specific overstatements section 6.6 and section 11 name. Checked
      // across the whole card set rather than card by card, because the reader
      // sees them together.
      final all = build()
          .alignments
          .map((a) => '${a.signal} ${a.boundary}')
          .join(' ')
          .toLowerCase();

      // Each of these words may appear ONLY inside a denial.
      for (final claim in ['recycled', 'carbon credit', 'offset', 'jobs created']) {
        if (!all.contains(claim)) continue;
        final sentences = all.split(RegExp(r'[.\n]'));
        for (final sentence in sentences.where((s) => s.contains(claim))) {
          expect(
            sentence,
            anyOf(contains('not'), contains('does not'), contains('no ')),
            reason: '"$claim" appears outside a denial: $sentence',
          );
        }
      }
    });

    test('say plainly that Goal 12 and Goal 11 are not additive', () {
      // They read the same collected mass through two lenses; summing them
      // double-counts every gram.
      final twelve = build().alignments.firstWhere((a) => a.goal == 12);
      final eleven = build().alignments.firstWhere((a) => a.goal == 11);

      expect(twelve.boundary.toLowerCase(), contains('not additive'));
      expect(eleven.boundary.toLowerCase(), contains('not additive'));
    });

    test('mark exactly the mass-derived cards as carrying mass', () {
      // Drives whether the estimated share is shown. A participation count is
      // not more or less certain because some mass was a medium-confidence
      // match, and an uncertainty figure on it would be noise.
      final carrying = build()
          .alignments
          .where((a) => a.carriesMass)
          .map((a) => a.goal)
          .toList();
      expect(carrying, [12, 11, 13]);
    });

    test('report a suppressed district breakdown rather than a count', () {
      // SEC-3's k-anonymity floor. A producer publishing "recovered across 12
      // districts" from a suppressed breakdown would be publishing a number
      // Chokro withheld.
      final suppressed = build(from: period(districtSuppressed: true));
      final eleven = suppressed.alignments.firstWhere((a) => a.goal == 11);

      expect(suppressed.districtSuppressed, isTrue);
      expect(eleven.signal.toLowerCase(), contains('withheld'));
      expect(eleven.signal, isNot(matches(RegExp(r'\d+ districts'))));
    });
  });

  group('uncertainty (EPR-37)', () {
    test('is carried through from the period', () {
      final snapshot = build(
        from: period(
          byCategory: {'rigid': 1000000000},
          uncertainMassMg: 250000000,
        ),
      );
      expect(snapshot.estimatedShare, closeTo(0.25, 1e-9));
      expect(snapshot.isSubstantiallyEstimated, isTrue);
    });

    test('is not flagged prominently when it is small', () {
      final snapshot = build(
        from: period(
          byCategory: {'rigid': 1000000000},
          uncertainMassMg: 10000000,
        ),
      );
      expect(snapshot.estimatedShare, closeTo(0.01, 1e-9));
      expect(snapshot.isSubstantiallyEstimated, isFalse);
    });
  });

  group('the carbon line (EPR-38, EPR-39)', () {
    test('is refused above the uncertainty ceiling', () {
      final snapshot = build(
        from: period(
          byCategory: {'rigid': 1000000000},
          uncertainMassMg: 400000000,
        ),
      );

      // No figure at all — not a wider range, not a qualified one.
      expect(snapshot.carbon.kgCo2eAvoided, isNull);
      expect(snapshot.carbon.absence, CarbonAbsence.tooUncertain);
    });

    test('is stated below the ceiling, with its factor pinned', () {
      final snapshot = build(from: period(byCategory: {'rigid': 1000000000}));

      expect(snapshot.carbon.kgCo2eAvoided, closeTo(1024, 1e-6));
      expect(snapshot.carbon.factor?.version, isNotEmpty);
      expect(snapshot.carbon.factor?.systemBoundary, isNotEmpty);
    });

    test('uses the same ceiling the server does', () {
      // Section 5.3: a deliberate duplicate is only safe if something proves
      // the two stay in step. `server/src/eprPolicy.js` holds the authority;
      // a client that showed a figure the certificate omits would have the
      // producer reading two answers about the same period.
      expect(carbonUncertaintyCeiling, 0.25);
    });

    test('is positive for an avoidance', () {
      // The factor is signed negative; the direction belongs in the wording,
      // not in a minus sign in front of a benefit.
      final snapshot = build(from: period(byCategory: {'rigid': 1000000000}));
      expect(snapshot.carbon.kgCo2eAvoided!, greaterThan(0));
    });
  });

  group('an empty period', () {
    test('reports no activity rather than five zeros', () {
      final snapshot = build(
        from: period(
          byCategory: const {},
          byDistrict: const {},
          attributionCount: 0,
          disposalCount: 0,
          skuIds: const [],
        ),
        rate: collectionRate(
          collectedMassMg: 0,
          declaredMassMg: null,
          hasDeclaration: false,
        ),
      );

      // Five cards of zeros would read as five measured outcomes of nothing.
      expect(snapshot.hasRecordedActivity, isFalse);
      expect(snapshot.totalMassMg, 0);
      expect(snapshot.carbon.kgCo2eAvoided, isNull);
      expect(snapshot.carbon.absence, CarbonAbsence.noMass);
    });
  });

  group('the collection percentage on the headline', () {
    test('is absent when no declaration was filed (EPR-24)', () {
      final snapshot = build(
        rate: collectionRate(
          collectedMassMg: 5000000000,
          declaredMassMg: null,
          hasDeclaration: false,
        ),
      );

      expect(snapshot.collectionRate.rate, isNull);
      expect(snapshot.collectionRate.percentLabel, isNull);
      expect(snapshot.collectionRate.absence, RateAbsence.noDeclaration);
    });

    test('is present when one was', () {
      expect(build().collectionRate.percentLabel, '25.0%');
    });
  });
}
