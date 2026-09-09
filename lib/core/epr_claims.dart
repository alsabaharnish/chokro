/// Chokro — what this system may and may not claim (EPR-26, §6.7, QA-4).
///
/// ## Why these sentences are constants and not copy
///
/// §6.7 is a list of hard prohibitions, and the specification is explicit that
/// it "is not a documentation convention — it is testable, so test it."
///
/// A sentence typed into a widget cannot be tested usefully. Scanning view
/// source for a forbidden phrase gives both false positives (a *disclaimer*
/// contains the phrase it disclaims — "no figure produced by Chokro is
/// DoE-approved" matches a search for "DoE-approved") and false negatives (Dart
/// concatenates adjacent string literals, so a sentence spanning two source
/// lines is invisible to a substring match).
///
/// So the boundary statements live here, once. Every surface that must carry
/// them renders [eprBoundaryStatements], and the test asserts the list rather
/// than the rendering. When the Plastic Passport arrives it prints the same
/// list — EPR-28 requires these statements on the document itself, "not in a
/// footnote in six-point type", and a second copy of the wording is a second
/// thing to keep in step.
///
/// Plain Dart, no Firebase and no Flutter imports.
library;

/// The §6.7 statements, in the words they appear in.
///
/// Ordered from the broadest to the most specific, because that is the order a
/// reader needs them: who is obligated, what Chokro does not do, and then what
/// the numbers are and are not.
const List<String> eprBoundaryStatements = <String>[
  'Chokro is an evidence and reporting provider. The obligated entity remains '
      'your company, and your company files with the Department of Environment.',
  'Nothing here discharges your legal obligation, and no figure produced by '
      'Chokro is DoE-approved, certified or accepted.',
  'Figures are operational records of activity, not official measurements of '
      'an environmental outcome.',
];

/// Why a figure is absent, in the words the interface uses.
///
/// Each of these is a *refusal to state a number*, and each names the input
/// that is missing. A screen that simply omitted the figure would read as a
/// zero; a screen that showed a zero would be stating a measurement it does not
/// have.
class EprAbsenceReasons {
  const EprAbsenceReasons._();

  /// EPR-24. Only the producer knows what it placed on the market, so until it
  /// files, the denominator does not exist.
  static const String noPercentageWithoutDeclaration =
      'A collection percentage needs what you placed on the market as its '
      'denominator, and only you know that figure. Until you file a '
      'put-on-market declaration for a period, Chokro shows kilograms and says '
      'plainly that the percentage cannot be computed.';

  /// §6.6 / EPR-25. Stated rather than omitted: silence would read as coverage.
  static const String recyclingNotCovered =
      'Recycling is a separate gazette target and is not covered by Chokro’s '
      'evidence. A photographed, geofenced disposal into a registered bin is a '
      'collection event; nothing in this system yet observes material arriving '
      'at a recycler.';

  /// EPR-11. A declared mass is never used for reporting.
  static const String noMassWithoutVerification =
      'Until a product has a Chokro-verified unit mass, there is no defensible '
      'kilogram to report, so this workspace reports none.';

  /// The gazette target is the law's number, printed beside a figure. Whether
  /// an obligation is met is the regulator's finding.
  static const String targetIsNotAnAssessment =
      'Chokro states the gazette target beside your figure; whether it is met '
      'is the Department of Environment’s finding, not ours.';

  /// A target cannot be named without an obligation year to name it for.
  static const String noTargetWithoutObligationYear =
      'Shown once your obligation year is known.';
}

/// Phrases that would assert a prohibited claim (EPR-26).
///
/// Used by the traceability test to scan generated documents and rendered
/// strings. Each entry is a pattern that, **asserted**, breaks a hard
/// prohibition.
///
/// The matching is deliberately done against text with [eprBoundaryStatements]
/// removed first — otherwise every disclaimer would flag itself, which is the
/// mistake that made the first version of this check useless.
const List<String> prohibitedClaimPhrases = <String>[
  'DoE-approved',
  'DoE approved',
  'approved by the Department',
  'officially certified',
  'officially accepted',
  'obligation is met',
  'obligation discharged',
  'you are compliant',
  'compliant with the gazette',
  'recycling rate',
  'recycling percentage',
  'you have recycled',
  '% recycled',
  'CO2e',
  'carbon avoided',
  'emissions avoided',
  'trees equivalent',
  'cars off the road',
];

/// Whether [text] asserts a prohibited claim.
///
/// Strips the known boundary statements before matching, so a document that
/// correctly *denies* a claim is not reported as making it. That is the whole
/// difficulty of checking this class of requirement mechanically, and doing the
/// subtraction in one named place is what keeps the check honest rather than
/// noisy.
///
/// Returns the phrases found, so a failure names them rather than saying only
/// that something matched.
List<String> findProhibitedClaims(String text) {
  var remaining = text;
  for (final statement in eprBoundaryStatements) {
    remaining = remaining.replaceAll(statement, '');
  }
  for (final reason in <String>[
    EprAbsenceReasons.noPercentageWithoutDeclaration,
    EprAbsenceReasons.recyclingNotCovered,
    EprAbsenceReasons.noMassWithoutVerification,
    EprAbsenceReasons.targetIsNotAnAssessment,
  ]) {
    remaining = remaining.replaceAll(reason, '');
  }

  final lowered = remaining.toLowerCase();
  return prohibitedClaimPhrases
      .where((phrase) => lowered.contains(phrase.toLowerCase()))
      .toList(growable: false);
}
