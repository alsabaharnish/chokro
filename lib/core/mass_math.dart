/// Chokro — the arithmetic that turns a gram into a compliance figure
/// (EPR-20, QA-1, QA-3).
///
/// ## Why integers, and why milligrams
///
/// A producer's annual figure is a sum over potentially hundreds of thousands
/// of attribution rows. Accumulating that in floating point is how two reports
/// of the same period end up disagreeing in the third decimal — and a regulator
/// who spots that disagreement is entitled to distrust every other number in
/// the document.
///
/// So mass is an **integer count of milligrams** everywhere inside the system,
/// from the moment a declared gram weight is parsed to the moment a report is
/// composed. `units × unitMassMg` is exact integer multiplication; a sum of
/// such products is an exact integer sum. There is no rounding to accumulate.
///
/// Milligrams rather than grams because packaging components are declared to a
/// tenth of a gram and a label sleeve can weigh 0.5 g; storing tenths as
/// integers would leave no headroom, and storing them as doubles would put a
/// float back in the chain. Milligrams give three decimal places of gram
/// precision with integers, which is finer than any scale Chokro will weigh on.
///
/// ## Where rounding is allowed to happen
///
/// **Once**, at display or export, to three significant figures for kilograms
/// (EPR-20). Never in between. [formatKilograms] is the only function here that
/// produces a rounded value, and everything that feeds it takes and returns
/// integers.
///
/// Plain Dart, no Firebase and no Flutter imports. Pure and injectable, so
/// every branch is unit-testable — the existing `checkout_math.dart` is the
/// precedent (QA-1).
library;

import 'dart:math' as math;

/// Bounds on a declared unit mass, from EPR-9's `producerSkus` schema:
/// 0.1 g to 5000 g.
///
/// The floor exists because a mass below a tenth of a gram is below what a
/// calibrated bench scale distinguishes on a single unit, so it could not be
/// verified by the physical sampling EPR-11 requires. The ceiling exists
/// because a single unit of consumer packaging heavier than five kilograms is
/// a data-entry error, and an unbounded number multiplied by a recognised unit
/// count is an unbounded compliance figure.
const int minUnitMassMg = 100;
const int maxUnitMassMg = 5000000;

/// The floor for a single *component*, as opposed to a whole unit.
///
/// One milligram, not the unit floor of 0.1 g. A tamper ring, a foil seal or a
/// printed label can legitimately weigh 0.05 g, and applying the unit floor to
/// each part made such a product unregisterable: the producer's only options
/// were to drop the part — losing grams from the polymer breakdown a DoE audit
/// reads — or to fold its mass into another part, which puts those grams on the
/// wrong polymer line.
///
/// The unit floor exists because a whole unit below 0.1 g could not be verified
/// by the physical sampling EPR-11 requires. That reasoning does not transfer
/// to a part: parts are not weighed individually, they are *declared*, and the
/// figure the scale checks is their sum.
const int minComponentMassMg = 1;

/// Milligrams in a gram, and in a kilogram. Named rather than inline, because a
/// stray factor of a thousand in a compliance figure is a very expensive typo.
const int mgPerGram = 1000;
const int mgPerKilogram = 1000000;
const int mgPerTonne = 1000000000;

/// Parses a declared gram figure into integer milligrams.
///
/// Returns null for anything that is not a usable mass: not a number, not
/// finite, negative, zero, or outside [minUnitMassMg]–[maxUnitMassMg]. Null and
/// not a fallback — a declared mass that cannot be read must stop a submission,
/// because the alternative is a default multiplying into every kilogram Chokro
/// reports on that producer's behalf.
///
/// Accepts a `num` or a `String`, because this is the boundary where a CSV cell
/// and a form field both arrive (EPR-10).
int? milligramsFromGrams(Object? grams) {
  final double? value = switch (grams) {
    final num n => n.toDouble(),
    final String s => double.tryParse(s.trim()),
    _ => null,
  };

  if (value == null || !value.isFinite || value <= 0) return null;

  // Rounded to the nearest milligram, which is the storage precision. A
  // declared 8.2004 g is 8200 mg; the fourth decimal place of a gram is below
  // what any scale in this process can measure and carrying it would imply a
  // precision the evidence does not have.
  final mg = (value * mgPerGram).round();

  if (mg < minUnitMassMg || mg > maxUnitMassMg) return null;
  return mg;
}

/// The exact mass of [units] items each weighing [unitMassMg].
///
/// Integer multiplication, so it is exact by construction. Returns null for a
/// non-positive unit count or a unit mass outside the declared bounds —
/// refusing rather than clamping, because a clamped compliance figure is a
/// wrong figure that looks like a right one.
int? massMilligrams({required int units, required int unitMassMg}) {
  if (units <= 0) return null;
  if (unitMassMg < minUnitMassMg || unitMassMg > maxUnitMassMg) return null;

  // A recognised unit count at a bin is a handful of items; this guard exists
  // for a corrupted or hostile value, not a plausible one. Above it the product
  // would still be exact but would no longer describe anything real.
  if (units > 100000) return null;

  return units * unitMassMg;
}

/// Sums milligram values exactly.
///
/// Trivial, and named anyway: it is the one place a `fold` over compliance
/// masses lives, so there is exactly one line to read when asking whether the
/// accumulation is integer. Non-integer or negative entries are skipped rather
/// than coerced, and [MassSum.skipped] carries how many — a total that quietly
/// dropped rows is the failure QA-3 asks to be surfaced rather than corrected.
MassSum sumMilligrams(Iterable<Object?> values) {
  var total = 0;
  var counted = 0;
  var skipped = 0;

  for (final value in values) {
    if (value is int && value >= 0) {
      total += value;
      counted += 1;
    } else {
      skipped += 1;
    }
  }

  return MassSum(totalMg: total, counted: counted, skipped: skipped);
}

/// The result of summing masses, including what could not be summed.
class MassSum {
  const MassSum({
    required this.totalMg,
    required this.counted,
    required this.skipped,
  });

  final int totalMg;
  final int counted;

  /// Rows that were not a non-negative integer number of milligrams.
  ///
  /// Non-zero means the total is over fewer rows than were offered. A caller
  /// rendering a compliance figure must say so rather than presenting the total
  /// as complete.
  final int skipped;

  bool get isComplete => skipped == 0;
}

/// Whether a component breakdown sums to the declared unit mass (EPR-9).
///
/// Exact equality, on integers. No tolerance, because both sides are figures
/// the producer typed: a breakdown that does not add up is an arithmetic error
/// in the declaration, not a measurement disagreement. The measurement
/// disagreement — declared against weighed — is EPR-11's tolerance, and it is a
/// different question asked at a different time.
bool componentsSumToDeclared({
  required Iterable<int> componentMassesMg,
  required int declaredUnitMassMg,
}) {
  final sum = sumMilligrams(componentMassesMg);
  return sum.isComplete && sum.totalMg == declaredUnitMassMg;
}

/// Rounds [value] to [figures] significant figures.
///
/// The single rounding step EPR-20 permits, extracted so it can be tested
/// directly rather than only through a formatter. Zero returns zero; a
/// non-finite input returns itself rather than throwing, because a formatter is
/// not the right place to discover a corrupted figure.
double roundToSignificantFigures(double value, int figures) {
  if (value == 0 || !value.isFinite || figures < 1) return value;

  final magnitude = value.abs();
  // The power of ten of the leading digit.
  final exponent = (_log10(magnitude)).floor();
  final scale = _pow10(figures - 1 - exponent);

  return (value * scale).round() / scale;
}

/// Formats a milligram total as kilograms, to three significant figures.
///
/// The only place a compliance mass becomes a string, and therefore the only
/// place rounding happens (EPR-20).
///
/// Exact zero is rendered as `0 kg` rather than `0.00 kg`: a figure padded with
/// decimals implies a measurement precise to that place, and an absence of
/// attributed mass is not a measurement of zero.
String formatKilograms(int milligrams, {int figures = 3}) {
  if (milligrams == 0) return '0 kg';

  final kilograms = milligrams / mgPerKilogram;
  final rounded = roundToSignificantFigures(kilograms, figures);

  return '${_trim(rounded, figures)} kg';
}

/// Formats a milligram value as grams, to three significant figures.
///
/// For a single unit's mass and for a per-SKU line, where kilograms would read
/// as `0.00980 kg` and mean less to a packaging engineer than `9.8 g`.
String formatGrams(int milligrams, {int figures = 3}) {
  if (milligrams == 0) return '0 g';

  final grams = milligrams / mgPerGram;
  final rounded = roundToSignificantFigures(grams, figures);

  return '${_trim(rounded, figures)} g';
}

/// Formats a milligram value as grams at full precision.
///
/// FOR DISCREPANCIES, NOT FOR REPORTING.
///
/// [formatGrams] and [formatKilograms] round to three significant figures,
/// which is right for a compliance figure at scale and actively wrong for
/// telling somebody which milligram is missing. Rounding both sides of a
/// mismatch produced messages like "The parts add up to 10 g, but the unit mass
/// is 10 g" — a producer blocked from submitting by an error stating that two
/// numbers are equal, with nothing to act on.
///
/// So a *difference* is rendered here instead: every digit the stored integer
/// has, with trailing zeros trimmed so 8.2 g does not print as 8.200 g. No
/// rounding happens, which is why this must never be used for a reported
/// figure — EPR-20 allows exactly one rounding step, at display or export.
String formatGramsExact(int milligrams) {
  if (milligrams == 0) return '0 g';

  final sign = milligrams < 0 ? '-' : '';
  final abs = milligrams.abs();
  final whole = abs ~/ mgPerGram;
  final fraction = abs % mgPerGram;

  if (fraction == 0) return '$sign$whole g';

  final decimals = fraction
      .toString()
      .padLeft(3, '0')
      .replaceFirst(RegExp(r'0+$'), '');
  return '$sign$whole.$decimals g';
}

/// Renders [value] with only the decimal places its significant figures earn.
///
/// `3.94` and not `3.940`; `394` and not `394.0`. A trailing zero after the
/// third significant figure claims a fourth.
String _trim(double value, int figures) {
  if (value == 0) return '0';

  final magnitude = value.abs();
  final exponent = (_log10(magnitude)).floor();
  final decimals = figures - 1 - exponent;

  if (decimals <= 0) return value.round().toString();

  // `toStringAsFixed` then strip the zeros the rounding did not need. A value
  // that genuinely lands on 3.9 should not be shown as 3.90.
  var text = value.toStringAsFixed(decimals);
  if (text.contains('.')) {
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
  }
  return text;
}

/// Base-ten logarithm.
///
/// `dart:math`'s `log` is natural, so this is the conversion every caller here
/// would otherwise write inline — writing it once keeps the `ln(10)` constant in
/// one place.
double _log10(double value) => math.log(value) / math.ln10;

/// Rounds ten to an integer power, exactly for the range that matters.
///
/// `pow(10, n)` returns a `num` and, for a negative `n`, a double whose last
/// bits are not what a decimal reader expects — 1e-3 is not exactly 0.001. For
/// the range this file uses (a kilogram figure has an exponent between about
/// -9 and 9) an integer power built by repeated multiplication and then
/// inverted keeps the error to one operation instead of accumulating it.
double _pow10(int exponent) {
  if (exponent == 0) return 1;

  var factor = 1.0;
  final steps = exponent.abs();
  for (var i = 0; i < steps; i += 1) {
    factor *= 10;
  }
  return exponent > 0 ? factor : 1 / factor;
}
