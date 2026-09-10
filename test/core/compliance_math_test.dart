/// The percentage a regulator reads (EPR-24, EPR-26, QA-3, QA-4).
///
/// Every test here defends one sentence: "No percentage, no target status and
/// no compliance-sounding statement is displayed anywhere for a period with no
/// submitted declaration."
library;

import 'package:chokro/core/compliance_math.dart';
import 'package:chokro/core/epr_categories.dart';
import 'package:chokro/core/mass_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('a rate needs a declaration to exist at all', () {
    test('no declaration means no rate, and the reason says so', () {
      final rate = collectionRate(
        collectedMassMg: 3940 * mgPerKilogram,
        declaredMassMg: null,
        hasDeclaration: false,
      );

      expect(rate.exists, isFalse);
      expect(rate.rate, isNull);
      expect(rate.percentLabel, isNull);
      expect(rate.absence, RateAbsence.noDeclaration);
      // The numerator survives: kilograms collected are reportable on their
      // own, and EPR-24 says so explicitly.
      expect(rate.collectedMassMg, 3940 * mgPerKilogram);
    });

    test('a declaration silent on a category is not a nil declaration', () {
      // The distinction that decides whether a percentage exists. A producer
      // that declared nothing for `flexible` has not said it placed none on the
      // market; it has said nothing. Treating that as zero would produce a
      // division by zero at best and an infinite rate at worst.
      final undeclared = collectionRate(
        collectedMassMg: 100,
        declaredMassMg: null,
        hasDeclaration: true,
      );
      expect(undeclared.absence, RateAbsence.categoryNotDeclared);

      final nil = collectionRate(
        collectedMassMg: 100,
        declaredMassMg: 0,
        hasDeclaration: true,
      );
      expect(nil.absence, RateAbsence.declaredNil);

      expect(undeclared.absence, isNot(nil.absence));
    });

    test('a nil declaration yields no rate, however much was collected', () {
      // A percentage of zero is not a large number, it is not a number.
      final rate = collectionRate(
        collectedMassMg: 5000 * mgPerKilogram,
        declaredMassMg: 0,
        hasDeclaration: true,
      );
      expect(rate.exists, isFalse);
      expect(rate.rate, isNull);
      expect(rate.absence, RateAbsence.declaredNil);
    });

    test('a negative declared figure is treated as nil, not divided by', () {
      final rate = collectionRate(
        collectedMassMg: 100,
        declaredMassMg: -500,
        hasDeclaration: true,
      );
      expect(rate.exists, isFalse);
      expect(rate.absence, RateAbsence.declaredNil);
    });
  });

  group('the worked example', () {
    test('3,940 kg against 61,000 kg is 6.5%', () {
      // Appendix A step 8: "3,940 ÷ 61,000 = 6.5% collection".
      final rate = collectionRate(
        collectedMassMg: 3940 * mgPerKilogram,
        declaredMassMg: 61000 * mgPerKilogram,
        hasDeclaration: true,
      );

      expect(rate.exists, isTrue);
      expect(rate.percentLabel, '6.5%');
      expect(rate.absence, isNull);
    });

    test('it is below the applicable 15% target, and that is stated as such', () {
      final rate = collectionRate(
        collectedMassMg: 3940 * mgPerKilogram,
        declaredMassMg: 61000 * mgPerKilogram,
        hasDeclaration: true,
      );

      expect(
        compareToTarget(rate: rate, applicableTarget: 0.15),
        TargetComparison.belowTarget,
      );
    });
  });

  group('the target comparison is arithmetic, not a verdict', () {
    test('at the target counts as at-or-above', () {
      final exact = collectionRate(
        collectedMassMg: 150,
        declaredMassMg: 1000,
        hasDeclaration: true,
      );
      expect(
        compareToTarget(rate: exact, applicableTarget: 0.15),
        TargetComparison.atOrAboveTarget,
      );
    });

    test('one milligram short is below', () {
      final short = collectionRate(
        collectedMassMg: 149,
        declaredMassMg: 1000,
        hasDeclaration: true,
      );
      expect(
        compareToTarget(rate: short, applicableTarget: 0.15),
        TargetComparison.belowTarget,
      );
    });

    test('no rate means not comparable, never "below"', () {
      // Reporting a missing rate as below target would be a compliance-sounding
      // statement about a period with no declaration — exactly what EPR-24
      // forbids.
      final absent = collectionRate(
        collectedMassMg: 100,
        declaredMassMg: null,
        hasDeclaration: false,
      );
      expect(
        compareToTarget(rate: absent, applicableTarget: 0.15),
        TargetComparison.notComparable,
      );
    });

    test('no known target means not comparable', () {
      // The obligation year is not established, so the applicable rate is not
      // known and no target may be shown (EPR-26).
      final rate = collectionRate(
        collectedMassMg: 300,
        declaredMassMg: 1000,
        hasDeclaration: true,
      );
      expect(
        compareToTarget(rate: rate, applicableTarget: null),
        TargetComparison.notComparable,
      );
    });

    test('the enum does not contain a word a report could quote as a verdict', () {
      // EPR-26 forbids implying an obligation has been discharged. Whether it
      // has is the DoE's finding, on evidence Chokro does not hold.
      final names = TargetComparison.values.map((v) => v.name.toLowerCase());
      for (final forbidden in ['compliant', 'passed', 'met', 'approved']) {
        expect(
          names.any((n) => n.contains(forbidden)),
          isFalse,
          reason: 'TargetComparison must not contain "$forbidden"',
        );
      }
    });
  });

  group('surplus is a mass, never a credit', () {
    test('above target yields the excess over what the target required', () {
      // 1000 kg declared, 30% target = 300 kg required, 500 kg collected.
      final rate = collectionRate(
        collectedMassMg: 500 * mgPerKilogram,
        declaredMassMg: 1000 * mgPerKilogram,
        hasDeclaration: true,
      );
      expect(
        surplusMassMg(rate: rate, applicableTarget: 0.30),
        200 * mgPerKilogram,
      );
    });

    test('at or below target yields zero, not a negative', () {
      final atTarget = collectionRate(
        collectedMassMg: 300 * mgPerKilogram,
        declaredMassMg: 1000 * mgPerKilogram,
        hasDeclaration: true,
      );
      expect(surplusMassMg(rate: atTarget, applicableTarget: 0.30), 0);

      final below = collectionRate(
        collectedMassMg: 100 * mgPerKilogram,
        declaredMassMg: 1000 * mgPerKilogram,
        hasDeclaration: true,
      );
      expect(surplusMassMg(rate: below, applicableTarget: 0.30), 0);
    });

    test('the required mass rounds up, so a fraction short is not a surplus', () {
      // 3 mg declared at 15% is 0.45 mg required. Rounding down to 0 would
      // report every collected milligram as surplus.
      final rate = collectionRate(
        collectedMassMg: 1,
        declaredMassMg: 3,
        hasDeclaration: true,
      );
      expect(surplusMassMg(rate: rate, applicableTarget: 0.15), 0);
    });

    test('no rate or no target means no surplus', () {
      final absent = collectionRate(
        collectedMassMg: 100,
        declaredMassMg: null,
        hasDeclaration: false,
      );
      expect(surplusMassMg(rate: absent, applicableTarget: 0.15), isNull);

      final rate = collectionRate(
        collectedMassMg: 500,
        declaredMassMg: 1000,
        hasDeclaration: true,
      );
      expect(surplusMassMg(rate: rate, applicableTarget: null), isNull);
    });
  });

  group('declaration variance (EPR-43)', () {
    test('a 60% jump is reported as such', () {
      expect(
        declarationVariance(currentMassMg: 1600, previousMassMg: 1000),
        closeTo(0.6, 1e-9),
      );
      expect(
        declarationVariance(currentMassMg: 400, previousMassMg: 1000),
        closeTo(-0.6, 1e-9),
      );
    });

    test('a first filing has no variance, and that is not zero', () {
      // Reporting a first filing's variance as zero would hide the fact that
      // there is nothing to compare against.
      expect(
        declarationVariance(currentMassMg: 1000, previousMassMg: null),
        isNull,
      );
      expect(
        declarationVariance(currentMassMg: 1000, previousMassMg: 0),
        isNull,
      );
    });

    test('the threshold catches a move in either direction', () {
      // Understating put-on-market is one of the two attacks §6.2 names, so a
      // downward move matters as much as an upward one.
      expect(
        varianceWantsExplanation(variance: 0.61, threshold: 0.6),
        isTrue,
      );
      expect(
        varianceWantsExplanation(variance: -0.61, threshold: 0.6),
        isTrue,
      );
      expect(
        varianceWantsExplanation(variance: 0.59, threshold: 0.6),
        isFalse,
      );
      expect(
        varianceWantsExplanation(variance: null, threshold: 0.6),
        isFalse,
      );
    });
  });

  group('a whole period position', () {
    Map<String, int> collected() => {
      GazetteCategory.rigid: 3940 * mgPerKilogram,
      GazetteCategory.flexible: 60 * mgPerKilogram,
    };

    test('assembles a rate per category in gazette order', () {
      final position = CompliancePosition.from(
        periodId: '2026-09',
        collectedMassMgByCategory: collected(),
        declaredMassMgByCategory: {
          GazetteCategory.rigid: 61000 * mgPerKilogram,
          GazetteCategory.flexible: 2000 * mgPerKilogram,
        },
        applicableCollectionTarget: 0.15,
        obligationYear: 1,
      );

      expect(position.byCategory.keys.toList(), [
        GazetteCategory.rigid,
        GazetteCategory.flexible,
      ]);
      expect(position.byCategory[GazetteCategory.rigid]!.percentLabel, '6.5%');
      expect(position.hasDeclaration, isTrue);
    });

    test('with no declaration, every category and the overall lack a rate', () {
      final position = CompliancePosition.from(
        periodId: '2026-09',
        collectedMassMgByCategory: collected(),
        declaredMassMgByCategory: null,
      );

      expect(position.hasDeclaration, isFalse);
      expect(position.overall.exists, isFalse);
      expect(position.overall.absence, RateAbsence.noDeclaration);
      for (final rate in position.byCategory.values) {
        expect(rate.exists, isFalse);
        expect(rate.absence, RateAbsence.noDeclaration);
      }
      expect(position.overallComparison, TargetComparison.notComparable);
      expect(position.overallSurplusMassMg, isNull);
    });

    test('collected-but-undeclared categories are surfaced, not rated', () {
      // Either the declaration is incomplete or a product is registered under
      // the wrong category. Both are things a person should look at.
      final position = CompliancePosition.from(
        periodId: '2026-09',
        collectedMassMgByCategory: collected(),
        declaredMassMgByCategory: {
          GazetteCategory.rigid: 61000 * mgPerKilogram,
          // flexible collected but not declared.
        },
        applicableCollectionTarget: 0.15,
      );

      expect(position.collectedButNotDeclared, [GazetteCategory.flexible]);
      expect(
        position.byCategory[GazetteCategory.flexible]!.exists,
        isFalse,
      );
    });

    test('a nil-declared category with collection is also surfaced', () {
      final position = CompliancePosition.from(
        periodId: '2026-09',
        collectedMassMgByCategory: {GazetteCategory.eps: 500},
        declaredMassMgByCategory: {GazetteCategory.eps: 0},
        applicableCollectionTarget: 0.15,
      );
      expect(position.collectedButNotDeclared, [GazetteCategory.eps]);
    });

    test('the overall denominator sums only what was declared', () {
      // An undeclared category contributes to the numerator and not to the
      // denominator, which flatters the rate — the conservative direction, and
      // `collectedButNotDeclared` is what stops the flattered figure reading as
      // complete.
      final position = CompliancePosition.from(
        periodId: '2026-09',
        collectedMassMgByCategory: {
          GazetteCategory.rigid: 100,
          GazetteCategory.flexible: 900,
        },
        declaredMassMgByCategory: {GazetteCategory.rigid: 1000},
      );

      expect(position.overall.collectedMassMg, 1000);
      expect(position.overall.declaredMassMg, 1000);
      expect(position.overall.percentLabel, '100.0%');
      // And the gap is named, so nobody reads 100% as complete coverage.
      expect(position.collectedButNotDeclared, [GazetteCategory.flexible]);
    });

    test('a period with nothing at all is a valid position', () {
      final position = CompliancePosition.from(
        periodId: '2026-09',
        collectedMassMgByCategory: const {},
        declaredMassMgByCategory: null,
      );
      expect(position.byCategory, isEmpty);
      expect(position.overall.collectedMassMg, 0);
      expect(position.overall.exists, isFalse);
    });

    test('a declaration with no collection still produces a rate of zero', () {
      // Zero collected against a real denominator IS a number, and a true one.
      final position = CompliancePosition.from(
        periodId: '2026-09',
        collectedMassMgByCategory: const {},
        declaredMassMgByCategory: {
          GazetteCategory.rigid: 61000 * mgPerKilogram,
        },
      );
      expect(position.overall.exists, isTrue);
      expect(position.overall.percentLabel, '0.0%');
    });
  });
}
