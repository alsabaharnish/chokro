/// Chokro — the percentage a regulator reads (EPR-24, EPR-26, QA-1, QA-4).
///
/// ## The one function in this codebase that computes a compliance figure
///
/// Everything about it is shaped by a single requirement: **no percentage, no
/// target status and no compliance-sounding statement is displayed anywhere for
/// a period with no submitted declaration** (EPR-24).
///
/// The straightforward way to implement that is a `double?` returned from a
/// division, and it is wrong. A nullable number tells a caller that a figure is
/// absent and nothing about why, so every screen ends up re-deriving the
/// reason — and one of them gets it wrong and prints a dash where it should
/// print a sentence, or a zero where it should print a dash.
///
/// So this returns a [CollectionRate] that carries its own reason for
/// existing or not, and there is no way to obtain the number without also
/// having the reason in hand.
///
/// Plain Dart, no Firebase and no Flutter imports. Pure and testable (QA-1).
library;

import 'epr_categories.dart';

/// Why a collection percentage does not exist.
enum RateAbsence {
  /// No put-on-market declaration has been filed for the period. The producer
  /// is the only party that can fix this.
  noDeclaration,

  /// A declaration exists but says nothing about this category. **Not the same
  /// as declaring nil**: an undeclared category has no denominator, and a nil
  /// one has a denominator of zero.
  categoryNotDeclared,

  /// The producer declared it placed nothing on the market in this category.
  ///
  /// A percentage of zero is not a large number, it is not a number. Anything
  /// collected against a nil declaration is a discrepancy for a person to look
  /// at (EPR-43, EPR-45), not a rate to publish.
  declaredNil,
}

/// A collection percentage, or the stated reason there is not one.
///
/// Immutable and self-describing. A caller either has [rate] and may show it,
/// or has [absence] and must say why — and cannot have neither.
class CollectionRate {
  /// A real rate, from a real denominator.
  const CollectionRate.computed({
    required double this.rate,
    required this.collectedMassMg,
    required int this.declaredMassMg,
  }) : absence = null;

  /// No rate, and the reason.
  const CollectionRate.absent(
    RateAbsence this.absence, {
    required this.collectedMassMg,
    this.declaredMassMg,
  }) : rate = null;

  /// Collected mass divided by declared mass, as a fraction. Null when
  /// [absence] is set.
  final double? rate;

  /// Why there is no rate. Null when [rate] is set.
  final RateAbsence? absence;

  /// The numerator, which Chokro measured. Always present — kilograms
  /// collected are reportable on their own, and EPR-24 says so explicitly:
  /// "the workspace shows kilograms collected and says plainly that the
  /// percentage cannot be computed until the declaration is filed".
  final int collectedMassMg;

  /// The denominator, when one was declared.
  final int? declaredMassMg;

  bool get exists => rate != null;

  /// The percentage, to one decimal place. Null when there is no rate.
  ///
  /// One decimal because that is what the figure supports: the numerator is an
  /// exact integer of milligrams and the denominator is a producer's own
  /// estimate of its shipments, so a second decimal place would claim a
  /// precision the denominator does not have.
  String? get percentLabel =>
      rate == null ? null : '${(rate! * 100).toStringAsFixed(1)}%';
}

/// The collection rate for one gazette category in one period.
///
/// Takes the two figures rather than the two documents, so it can be tested
/// without constructing either and so there is no way for it to reach for a
/// draft declaration by accident — the caller has already had to decide that
/// the declaration is usable.
///
/// [declaredMassMg] null means the category was not declared. Zero means the
/// producer declared nil. The two are different and produce different
/// [RateAbsence] values.
CollectionRate collectionRate({
  required int collectedMassMg,
  required int? declaredMassMg,
  required bool hasDeclaration,
}) {
  if (!hasDeclaration) {
    return CollectionRate.absent(
      RateAbsence.noDeclaration,
      collectedMassMg: collectedMassMg,
    );
  }

  if (declaredMassMg == null) {
    return CollectionRate.absent(
      RateAbsence.categoryNotDeclared,
      collectedMassMg: collectedMassMg,
    );
  }

  if (declaredMassMg <= 0) {
    // Not a division by zero guard — a statement about what the figure would
    // mean. A producer that placed nothing on the market has no obligation to
    // measure a percentage of.
    return CollectionRate.absent(
      RateAbsence.declaredNil,
      collectedMassMg: collectedMassMg,
      declaredMassMg: declaredMassMg,
    );
  }

  return CollectionRate.computed(
    // The single division in this feature, on two integers, at the point of
    // display. Everything upstream of here is integer milligrams (EPR-20).
    rate: collectedMassMg / declaredMassMg,
    collectedMassMg: collectedMassMg,
    declaredMassMg: declaredMassMg,
  );
}

/// How a rate stands against the gazette target that applies.
///
/// ## Why this is not called `isCompliant`
///
/// EPR-26 forbids any screen or document stating or implying that a figure is
/// DoE-approved, certified or accepted, or that an obligation has been
/// discharged. Whether a producer has met its obligation is the Department of
/// Environment's finding, made on evidence Chokro does not hold — Chokro's
/// evidence covers collection, not recycling (§6.6), and the DoE may audit and
/// reject any of it.
///
/// So this compares two numbers and says which is larger. That is a true
/// statement about arithmetic and not a verdict about compliance, and the
/// naming is deliberate: a field called `isCompliant` would be quoted as one.
enum TargetComparison {
  /// The measured rate is at or above the gazette target for the period.
  atOrAboveTarget,

  /// Below it.
  belowTarget,

  /// No comparison is possible — either there is no rate, or the applicable
  /// target is not known because the obligation year is not established.
  notComparable,
}

/// Compares a rate against a target, or declines to.
TargetComparison compareToTarget({
  required CollectionRate rate,
  required double? applicableTarget,
}) {
  if (!rate.exists || applicableTarget == null) {
    return TargetComparison.notComparable;
  }
  return rate.rate! >= applicableTarget
      ? TargetComparison.atOrAboveTarget
      : TargetComparison.belowTarget;
}

/// Surplus mass above the applicable target, in integer milligrams.
///
/// ## Why this is "surplus" and never "credits"
///
/// The gazette permits plastic credits for waste handled in excess of targets,
/// and §15's seventh open decision is explicit that the operational framework —
/// who issues, who verifies, how they transfer — needs research before Chokro
/// reports a credit-eligible surplus. Its recommendation: "report surplus mass,
/// call it surplus, do not call it credits until the framework is understood".
///
/// So this returns a mass. Naming it a credit would assert a tradable
/// instrument exists, which is a claim about a market rather than about a
/// measurement.
///
/// Null when there is no rate or no target — a surplus above an unknown
/// threshold is not a surplus.
int? surplusMassMg({
  required CollectionRate rate,
  required double? applicableTarget,
}) {
  if (!rate.exists || applicableTarget == null) return null;

  final declared = rate.declaredMassMg;
  if (declared == null || declared <= 0) return null;

  // The mass the target itself requires, rounded up: a target met to the
  // milligram is met, and rounding down would report a surplus for a producer
  // that fell a fraction short.
  final required = (declared * applicableTarget).ceil();
  final surplus = rate.collectedMassMg - required;

  return surplus > 0 ? surplus : 0;
}

/// Period-over-period variance in a declared figure (EPR-43).
///
/// "A declaration that moves 60% against the previous period without a note is
/// either a business change or a manipulation and either way an Admin should
/// see it."
///
/// Null when there is nothing to compare against — a first filing has no
/// variance, and reporting one as zero would hide that fact behind a number.
double? declarationVariance({
  required int? currentMassMg,
  required int? previousMassMg,
}) {
  if (currentMassMg == null || previousMassMg == null) return null;
  if (previousMassMg <= 0) return null;
  return (currentMassMg - previousMassMg) / previousMassMg;
}

/// Whether a variance is large enough to want an explanation.
///
/// The threshold is a policy value in practice; this takes it as a parameter so
/// the function stays pure and the policy stays in `config/eprPolicy`.
bool varianceWantsExplanation({
  required double? variance,
  required double threshold,
}) => variance != null && variance.abs() >= threshold;

/// A whole period's compliance position, assembled once.
///
/// ## Why the assembly is here and not in a widget
///
/// QA-1: "a widget that performs arithmetic on a compliance figure is a defect
/// regardless of whether the output is currently correct". A screen that built
/// this itself would be one `if` away from showing a percentage for a category
/// nobody declared.
class CompliancePosition {
  const CompliancePosition({
    required this.periodId,
    required this.hasDeclaration,
    required this.byCategory,
    required this.overall,
    this.applicableCollectionTarget,
    this.obligationYear,
  });

  final String periodId;
  final bool hasDeclaration;

  /// One entry per gazette category with either collected mass or a declared
  /// figure. Categories with neither are absent, because there is nothing to
  /// say about them.
  final Map<String, CollectionRate> byCategory;

  /// The position across every category, from the totals.
  final CollectionRate overall;

  /// The gazette rate that applies in this obligation year, or null when the
  /// year is not established (EPR-26 forbids showing a target on a guess).
  final double? applicableCollectionTarget;

  final int? obligationYear;

  TargetComparison get overallComparison => compareToTarget(
    rate: overall,
    applicableTarget: applicableCollectionTarget,
  );

  int? get overallSurplusMassMg => surplusMassMg(
    rate: overall,
    applicableTarget: applicableCollectionTarget,
  );

  /// Categories where Chokro collected mass the producer did not declare.
  ///
  /// A discrepancy worth surfacing rather than a rate to publish: it means
  /// either the declaration is incomplete or a product is registered under the
  /// wrong category, and both are things a person should look at (EPR-43).
  List<String> get collectedButNotDeclared => [
    for (final entry in byCategory.entries)
      if (entry.value.collectedMassMg > 0 &&
          (entry.value.absence == RateAbsence.categoryNotDeclared ||
              entry.value.absence == RateAbsence.declaredNil))
        entry.key,
  ];

  /// Builds a position from a period's collected masses and a declaration's
  /// declared masses.
  ///
  /// Both are passed as plain maps of category to integer milligrams, so this
  /// depends on neither model and can be tested without either.
  factory CompliancePosition.from({
    required String periodId,
    required Map<String, int> collectedMassMgByCategory,
    required Map<String, int>? declaredMassMgByCategory,
    double? applicableCollectionTarget,
    int? obligationYear,
  }) {
    final hasDeclaration = declaredMassMgByCategory != null;

    final categories = <String>{
      ...collectedMassMgByCategory.keys,
      ...?declaredMassMgByCategory?.keys,
    };

    final byCategory = <String, CollectionRate>{};
    // Gazette order, so a breakdown always reads the same way.
    for (final category in GazetteCategory.all) {
      if (!categories.contains(category)) continue;
      byCategory[category] = collectionRate(
        collectedMassMg: collectedMassMgByCategory[category] ?? 0,
        declaredMassMg: declaredMassMgByCategory?[category],
        hasDeclaration: hasDeclaration,
      );
    }

    final collectedTotal = collectedMassMgByCategory.values.fold<int>(
      0,
      (sum, mg) => sum + mg,
    );

    // The overall denominator sums only what was DECLARED. A category the
    // producer did not mention contributes nothing to the denominator while its
    // collected mass still contributes to the numerator — which is the
    // conservative direction: it can only make the reported rate look better
    // than the truth, never worse, and `collectedButNotDeclared` surfaces the
    // gap so nobody reads the flattered figure as complete.
    final declaredTotal = declaredMassMgByCategory?.values.fold<int>(
      0,
      (sum, mg) => sum + mg,
    );

    return CompliancePosition(
      periodId: periodId,
      hasDeclaration: hasDeclaration,
      byCategory: byCategory,
      overall: collectionRate(
        collectedMassMg: collectedTotal,
        declaredMassMg: declaredTotal,
        hasDeclaration: hasDeclaration,
      ),
      applicableCollectionTarget: applicableCollectionTarget,
      obligationYear: obligationYear,
    );
  }
}
