/// The mass arithmetic, at its boundaries (EPR-20, QA-3).
///
/// The failure this whole file guards against: two reports of the same period
/// disagreeing in the third decimal, and a regulator who notices being entitled
/// to distrust every other figure in the document.
library;

import 'package:chokro/core/mass_math.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parsing a declared gram figure', () {
    test('reads the worked example’s component masses exactly', () {
      // Appendix A: PET body 8.2 g, PP cap 1.3 g, PET label 0.5 g, total 10.0 g.
      expect(milligramsFromGrams(8.2), 8200);
      expect(milligramsFromGrams(1.3), 1300);
      expect(milligramsFromGrams(0.5), 500);
      expect(milligramsFromGrams(10.0), 10000);
      expect(milligramsFromGrams(9.8), 9800);
    });

    test('accepts a string, because a CSV cell is one', () {
      expect(milligramsFromGrams('8.2'), 8200);
      expect(milligramsFromGrams('  10 '), 10000);
      expect(milligramsFromGrams('0.1'), 100);
    });

    test('refuses a partially-numeric string instead of prefix-parsing it', () {
      // Dart's `double.tryParse` already behaves this way; the assertion is
      // here so the *pair* is pinned. The server's copy used
      // `Number.parseFloat`, which prefix-parses — '1,250' became 1 g against a
      // 1250 g declaration. The same values are asserted in
      // server/test/producerSkus.test.js under the same name.
      expect(milligramsFromGrams('1,250'), isNull);
      expect(milligramsFromGrams('8.2g'), isNull);
      expect(milligramsFromGrams('8.2.5'), isNull);
      expect(milligramsFromGrams('12 grams'), isNull);
      expect(milligramsFromGrams('1 250'), isNull);
      expect(milligramsFromGrams('0x10'), isNull);
    });

    test('accepts every numeric form the server accepts, and no others', () {
      expect(milligramsFromGrams('10'), 10000);
      expect(milligramsFromGrams('  10 '), 10000);
      expect(milligramsFromGrams('8.2'), 8200);
      expect(milligramsFromGrams('.5'), 500);
      expect(milligramsFromGrams('+8.2'), 8200);
      expect(milligramsFromGrams('1e3'), 1000000);
    });

    test('refuses anything unusable rather than defaulting', () {
      // A default here would multiply into every kilogram Chokro reports on
      // that producer's behalf.
      for (final bad in <Object?>[
        null,
        '',
        'abc',
        '8.2g',
        0,
        -1,
        double.nan,
        double.infinity,
        <int>[],
      ]) {
        expect(
          milligramsFromGrams(bad),
          isNull,
          reason: '$bad must not parse to a mass',
        );
      }
    });

    test('enforces the 0.1 g to 5000 g bounds', () {
      expect(milligramsFromGrams(0.1), minUnitMassMg);
      expect(milligramsFromGrams(0.09), isNull);
      expect(milligramsFromGrams(5000), maxUnitMassMg);
      expect(milligramsFromGrams(5000.1), isNull);
    });

    test('rounds to the milligram rather than carrying false precision', () {
      // The fourth decimal place of a gram is below what any scale in this
      // process measures.
      expect(milligramsFromGrams(8.2004), 8200);
      expect(milligramsFromGrams(8.2006), 8201);
    });
  });

  group('units x unit mass', () {
    test('is exact integer multiplication', () {
      // Appendix A step 5: 2 x 9.8 g = 19.6 g.
      expect(massMilligrams(units: 2, unitMassMg: 9800), 19600);
      expect(massMilligrams(units: 1, unitMassMg: 100), 100);
      expect(massMilligrams(units: 3, unitMassMg: 8200), 24600);
    });

    test('refuses a non-positive unit count', () {
      expect(massMilligrams(units: 0, unitMassMg: 9800), isNull);
      expect(massMilligrams(units: -2, unitMassMg: 9800), isNull);
    });

    test('refuses a unit mass outside the declared bounds', () {
      // Refusing rather than clamping: a clamped compliance figure is a wrong
      // figure that looks like a right one.
      expect(massMilligrams(units: 2, unitMassMg: 0), isNull);
      expect(massMilligrams(units: 2, unitMassMg: 99), isNull);
      expect(massMilligrams(units: 2, unitMassMg: maxUnitMassMg + 1), isNull);
    });

    test('refuses an implausible unit count', () {
      expect(massMilligrams(units: 100001, unitMassMg: 9800), isNull);
    });
  });

  group('accumulation over many rows', () {
    test('412,000 units at 9.8 g is exact — no drift', () {
      // Appendix A step 6's scale. The same figure computed as a double sum
      // one row at a time is what this test exists to rule out.
      const units = 412000;
      const unitMassMg = 9800;

      final rows = <int>[
        for (var i = 0; i < units; i += 1) unitMassMg,
      ];
      final sum = sumMilligrams(rows);

      expect(sum.totalMg, units * unitMassMg);
      expect(sum.totalMg, 4037600000);
      expect(sum.isComplete, isTrue);
      // 4,037.6 kg, and the same integer every time it is computed.
      expect(sum.totalMg % 1, 0);
    });

    test('a hundred thousand tenth-gram rows do not drift', () {
      // 0.1 g accumulated 100,000 times is exactly 10 kg. As doubles, 0.1 is
      // not representable and the error compounds.
      final rows = <int>[for (var i = 0; i < 100000; i += 1) 100];
      expect(sumMilligrams(rows).totalMg, 10 * mgPerKilogram);
    });

    test('malformed rows are skipped and counted, never coerced', () {
      // A total that quietly dropped rows is the failure QA-3 asks to be
      // surfaced rather than corrected.
      final sum = sumMilligrams(<Object?>[100, null, 'x', -5, 200, 1.5]);
      expect(sum.totalMg, 300);
      expect(sum.counted, 2);
      expect(sum.skipped, 4);
      expect(sum.isComplete, isFalse);
    });

    test('an empty sum is complete and zero', () {
      final sum = sumMilligrams(const <int>[]);
      expect(sum.totalMg, 0);
      expect(sum.isComplete, isTrue);
    });
  });

  group('component breakdown (EPR-9)', () {
    test('the worked example adds up', () {
      expect(
        componentsSumToDeclared(
          componentMassesMg: const [8200, 1300, 500],
          declaredUnitMassMg: 10000,
        ),
        isTrue,
      );
    });

    test('one milligram out is out', () {
      // Exact equality, because both sides are figures the producer typed. A
      // breakdown that does not add up is an arithmetic error in the
      // declaration, not a measurement disagreement.
      expect(
        componentsSumToDeclared(
          componentMassesMg: const [8200, 1300, 501],
          declaredUnitMassMg: 10000,
        ),
        isFalse,
      );
    });

    test('a malformed component makes the check fail, not pass', () {
      expect(
        componentsSumToDeclared(
          componentMassesMg: const [8200, 1300, -500],
          declaredUnitMassMg: 9000,
        ),
        isFalse,
      );
    });

    test('no components never satisfies a declared mass', () {
      expect(
        componentsSumToDeclared(
          componentMassesMg: const [],
          declaredUnitMassMg: 10000,
        ),
        isFalse,
      );
    });
  });

  group('rounding, once, to three significant figures', () {
    test('rounds to three figures across magnitudes', () {
      expect(roundToSignificantFigures(3.9401, 3), 3.94);
      expect(roundToSignificantFigures(39.401, 3), 39.4);
      expect(roundToSignificantFigures(394.01, 3), 394);
      expect(roundToSignificantFigures(3941.0, 3), 3940);
      expect(roundToSignificantFigures(0.019601, 3), 0.0196);
    });

    test('zero and non-finite values pass through rather than throwing', () {
      // A formatter is the wrong place to discover a corrupted figure.
      expect(roundToSignificantFigures(0, 3), 0);
      expect(roundToSignificantFigures(double.nan, 3).isNaN, isTrue);
      expect(roundToSignificantFigures(double.infinity, 3), double.infinity);
    });

    test('negative values keep their sign', () {
      expect(roundToSignificantFigures(-3.9401, 3), -3.94);
    });
  });

  group('formatting kilograms', () {
    test('the worked example’s month', () {
      // Appendix A step 6: 3,940 kg.
      expect(formatKilograms(3940 * mgPerKilogram), '3940 kg');
      expect(formatKilograms(4037600000), '4040 kg');
    });

    test('shows only the decimals three significant figures earn', () {
      // A trailing zero after the third significant figure claims a fourth.
      expect(formatKilograms(3940000), '3.94 kg');
      expect(formatKilograms(3900000), '3.9 kg');
      expect(formatKilograms(3000000), '3 kg');
      expect(formatKilograms(39400000), '39.4 kg');
    });

    test('a small mass is still expressed in kilograms, honestly', () {
      // 19.6 g.
      expect(formatKilograms(19600), '0.0196 kg');
    });

    test('exact zero is not padded with decimals', () {
      // A figure padded with decimals implies a measurement precise to that
      // place, and an absence of attributed mass is not a measurement of zero.
      expect(formatKilograms(0), '0 kg');
    });

    test('a tonne-scale figure keeps three figures', () {
      expect(formatKilograms(1234 * mgPerKilogram), '1230 kg');
      expect(formatKilograms(mgPerTonne), '1000 kg');
    });
  });

  group('formatting a discrepancy exactly', () {
    test('a one-milligram mismatch does not read as two equal numbers', () {
      // The bug: `formatGrams` rounds to three significant figures, so a
      // mismatch message rendered both sides as "10 g" and told the producer
      // that two numbers which differ are equal.
      expect(formatGrams(10001), formatGrams(10000));
      expect(formatGramsExact(10001), '10.001 g');
      expect(formatGramsExact(10000), '10 g');
      expect(formatGramsExact(10001), isNot(formatGramsExact(10000)));
    });

    test('every digit the integer has survives', () {
      expect(formatGramsExact(8201), '8.201 g');
      expect(formatGramsExact(1234500), '1234.5 g');
      expect(formatGramsExact(1), '0.001 g');
      expect(formatGramsExact(50), '0.05 g');
      expect(formatGramsExact(500), '0.5 g');
    });

    test('trailing zeros are trimmed, so 8.2 g is not 8.200 g', () {
      expect(formatGramsExact(8200), '8.2 g');
      expect(formatGramsExact(9800), '9.8 g');
      expect(formatGramsExact(10000), '10 g');
    });

    test('zero and negatives render honestly', () {
      expect(formatGramsExact(0), '0 g');
      expect(formatGramsExact(-1), '-0.001 g');
      expect(formatGramsExact(-8200), '-8.2 g');
    });
  });

  group('the component floor is finer than the unit floor', () {
    test('a part may weigh less than a whole unit may', () {
      // A tamper ring, foil seal or printed label legitimately weighs 0.05 g.
      // Applying the unit floor to each part made such a product
      // unregisterable: the producer had to drop the part — losing grams from
      // the polymer breakdown a DoE audit reads — or fold its mass onto another
      // part, putting those grams on the wrong polymer line.
      expect(minComponentMassMg, lessThan(minUnitMassMg));
      expect(minComponentMassMg, 1);
      expect(minUnitMassMg, 100);
    });

    test('a four-part bottle including a 0.05 g ring balances', () {
      expect(
        componentsSumToDeclared(
          componentMassesMg: const [8150, 1300, 500, 50],
          declaredUnitMassMg: 10000,
        ),
        isTrue,
      );
    });
  });

  group('the rounding claims no precision it does not have', () {
    /// How many significant figures a rendered figure actually shows.
    int significantFigures(String rendered) {
      var digits = rendered.replaceAll(RegExp(r'[^0-9.]'), '');
      digits = digits.replaceFirst(RegExp(r'^0+'), '');
      if (digits.startsWith('.')) {
        digits = digits.substring(1).replaceFirst(RegExp(r'^0+'), '');
      }
      digits = digits.replaceAll('.', '').replaceFirst(RegExp(r'0+$'), '');
      return digits.isEmpty ? 0 : digits.length;
    }

    test('never shows a fourth significant figure, over the whole range', () {
      // A property test rather than a handful of examples, because the failure
      // this guards is a *rendering* that overstates precision — and it would
      // appear at some magnitude nobody thought to write an example for.
      // A regulator reading "3941 kg" is being told a fourth digit Chokro's
      // evidence does not support.
      //
      // Deterministic pseudo-random, so a failure is reproducible: a seeded
      // generator rather than `Random()` means the same 20,000 values every
      // run, and a counterexample stays a counterexample.
      var seed = 7;
      int next(int bound) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return seed % bound;
      }

      final values = <int>[];

      // Every power of ten in milligrams, and its immediate neighbours — where
      // a floor/ceiling error in the exponent arithmetic would show.
      var power = 1;
      for (var exponent = 0; exponent <= 12; exponent += 1) {
        for (final delta in [-2, -1, 0, 1, 2, 5]) {
          if (power + delta > 0) values.add(power + delta);
        }
        values.add(power * 5);
        power *= 10;
      }

      for (var i = 0; i < 20000; i += 1) {
        values.add(1 + next(2000000000));
      }

      final overstated = <String>[];
      for (final mg in values) {
        final rendered = formatKilograms(mg);
        if (significantFigures(rendered) > 3) {
          overstated.add('$mg mg -> "$rendered"');
        }
      }

      expect(
        overstated,
        isEmpty,
        reason: 'these render a fourth significant figure',
      );
    });

    test('grams are held to the same standard', () {
      var seed = 11;
      int next(int bound) {
        seed = (seed * 1103515245 + 12345) & 0x7fffffff;
        return seed % bound;
      }

      final overstated = <String>[];
      for (var i = 0; i < 20000; i += 1) {
        final mg = 1 + next(5000000);
        final rendered = formatGrams(mg);
        if (significantFigures(rendered) > 3) {
          overstated.add('$mg mg -> "$rendered"');
        }
      }
      expect(overstated, isEmpty);
    });

    test('an exact power of ten survives rounding unchanged', () {
      // The case where an exponent computed through a logarithm lands just
      // below an integer and shifts the whole figure by a decimal place.
      for (final value in [
        1000.0,
        100.0,
        10.0,
        1.0,
        0.1,
        0.01,
        0.001,
        1e6,
        1e9,
      ]) {
        expect(
          roundToSignificantFigures(value, 3),
          value,
          reason: '$value must not move',
        );
      }
    });

    test('the exact-formatter is exempt, and deliberately so', () {
      // `formatGramsExact` exists to show a discrepancy and must NOT round —
      // three significant figures turned a one-milligram mismatch into two
      // equal numbers. It is never used for a reported figure.
      expect(significantFigures(formatGramsExact(10001)), greaterThan(3));
      expect(formatGramsExact(10001), '10.001 g');
    });
  });

  group('formatting grams', () {
    test('reads naturally for a single unit', () {
      expect(formatGrams(9800), '9.8 g');
      expect(formatGrams(10000), '10 g');
      expect(formatGrams(500), '0.5 g');
      expect(formatGrams(19600), '19.6 g');
      expect(formatGrams(0), '0 g');
    });
  });

  group('unit constants', () {
    test('the factors of a thousand are what they say', () {
      // A stray factor of a thousand in a compliance figure is a very
      // expensive typo.
      expect(mgPerGram, 1000);
      expect(mgPerKilogram, 1000 * mgPerGram);
      expect(mgPerTonne, 1000 * mgPerKilogram);
      expect(minUnitMassMg, 100);
      expect(maxUnitMassMg, 5000 * mgPerGram);
    });
  });
}
