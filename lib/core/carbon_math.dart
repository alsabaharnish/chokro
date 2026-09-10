/// Chokro — carbon, and the reasons it is allowed to be shown (EPR-38, EPR-39).
///
/// ## Why this file is mostly refusals
///
/// EPR-39 is the shortest list of prohibitions in the specification and the
/// easiest to break by accident:
///
///   an unsourced factor; a "trees equivalent" or "cars off the road"
///   conversion; any wording that presents the estimate as verified,
///   offset-grade or tradable; and any carbon figure at all for a period whose
///   `estimatedShare` exceeds a policy ceiling.
///
/// The first and last are structural, so they are enforced here rather than
/// trusted to a caller. [carbonAvoided] cannot be called without a resolved
/// [EmissionFactor] — there is no overload that takes a bare number — and it
/// returns a refusal, with the reason, when the period's uncertain share is
/// over the ceiling.
///
/// The middle two are wording, and are enforced by the claim-boundary test
/// over the rendered strings.
///
/// Plain Dart, no Firebase and no Flutter imports. Pure and testable (QA-1).
library;

import 'mass_math.dart';

/// A versioned, sourced emission factor (EPR-38).
///
/// ## Every field here exists because a figure without it cannot be published
///
/// "A carbon number that cannot name its factor and its source does not ship."
/// So the factor is not a coefficient; it is a citation with a number attached,
/// and a report pins the version it used so the figure stays reproducible when
/// the registry is updated.
class EmissionFactor {
  const EmissionFactor({
    required this.id,
    required this.material,
    required this.kgCo2ePerTonne,
    required this.source,
    required this.publicationYear,
    required this.version,
    required this.systemBoundary,
    required this.geography,
    this.uncertainty,
    this.doi,
    this.caveats = const <String>[],
    this.activeFrom,
    this.activeTo,
  });

  final String id;

  /// What the factor is for — `mixedPlastics`, `pet`, and so on.
  ///
  /// Keyed by material rather than by gazette category, because the literature
  /// is written that way and because polymer-specific factors should be able to
  /// replace a mixed one as they are sourced (EPR-38's second caveat).
  final String material;

  /// The factor itself. **Negative for an avoided emission.**
  ///
  /// Signed rather than an absolute value with a separate direction flag,
  /// because a sign is impossible to drop silently and a flag is not. A
  /// positive factor here would be an emission *caused*, which this system has
  /// no use for yet but which the sign leaves room for honestly.
  final double kgCo2ePerTonne;

  /// The citation, in the words a report prints.
  final String source;

  final int publicationYear;

  /// The registry version a report pins.
  final String version;

  /// What the factor counts — "avoided virgin production", say.
  ///
  /// Required, because two factors for the same material on different
  /// boundaries are not comparable and summing them is meaningless.
  final String systemBoundary;

  /// Where the factor was derived. The first caveat on Chokro's own default.
  final String geography;

  /// The uncertainty the source itself reports, where it reports one.
  ///
  /// Null when the source gives none — honestly null rather than a guessed
  /// range, because inventing an uncertainty is as much a fabrication as
  /// inventing the factor.
  final String? uncertainty;

  final String? doi;

  /// The caveats that must travel with this factor in the interface and in
  /// every report.
  final List<String> caveats;

  final DateTime? activeFrom;
  final DateTime? activeTo;

  /// Whether this factor may be used at all.
  ///
  /// A factor with no source cannot be written (EPR-38) — but a document read
  /// from a database can be anything, so the check is here too. Fails closed:
  /// an unsourced factor is unusable, not usable-with-a-warning.
  bool get isUsable =>
      source.trim().length >= 10 &&
      material.isNotEmpty &&
      version.isNotEmpty &&
      systemBoundary.isNotEmpty &&
      kgCo2ePerTonne.isFinite &&
      kgCo2ePerTonne != 0;

  bool wasActiveAt(DateTime moment) {
    final from = activeFrom;
    if (from == null) return false;
    if (moment.isBefore(from)) return false;
    final to = activeTo;
    return to == null || moment.isBefore(to);
  }

  /// The citation as a report prints it.
  String get citation => [
    source,
    if (doi != null) 'doi:$doi',
    '$systemBoundary boundary',
    geography,
    'factor version $version',
  ].join(' · ');
}

/// Why a carbon figure is not being shown.
enum CarbonAbsence {
  /// No factor is registered for the material, or the registered one is
  /// unusable (EPR-38: a factor without a citation cannot be written).
  noFactor,

  /// The period's medium-confidence share is above the policy ceiling
  /// (EPR-39). A carbon estimate built on a mass that is itself substantially
  /// uncertain compounds two uncertainties into one number that reads as
  /// precise.
  tooUncertain,

  /// There is no collected mass to convert.
  noMass,
}

/// A carbon estimate, or the stated reason there is not one.
class CarbonEstimate {
  const CarbonEstimate.computed({
    required double this.kgCo2eAvoided,
    required EmissionFactor this.factor,
    required this.massMg,
  }) : absence = null,
       estimatedShare = null;

  const CarbonEstimate.absent(
    CarbonAbsence this.absence, {
    required this.massMg,
    this.factor,
    this.estimatedShare,
  }) : kgCo2eAvoided = null;

  /// Kilograms of CO2e avoided. **Positive** for an avoidance, so a report does
  /// not print a minus sign in front of a benefit — the direction is in the
  /// wording, and [factor] carries the signed coefficient it came from.
  final double? kgCo2eAvoided;

  final CarbonAbsence? absence;

  /// The factor used. Present even on some refusals, so a screen can say which
  /// factor *would* have applied.
  final EmissionFactor? factor;

  final int massMg;

  /// The uncertain share that triggered a refusal, when that is the reason.
  final double? estimatedShare;

  bool get exists => kgCo2eAvoided != null;

  /// The figure, to three significant figures.
  ///
  /// The same precision the mass figures use, and for the same reason: the
  /// factor is an estimate derived from a different country's electricity mix,
  /// so a fourth digit would claim a precision nothing in the chain supports.
  /// The figure as a reader should see it, or null when there is not one.
  ///
  /// Three significant figures and no trailing zeros, via the same helper
  /// `mass_math.dart` uses — so a carbon figure and a mass figure on the same
  /// card are rounded the same way.
  ///
  /// This is the ONLY place a carbon figure should be formatted. A caller doing
  /// its own `.round()` understates every estimate below half a kilogram as
  /// "0 kg", which on an SDG card reads as a measured zero rather than as a
  /// small number.
  String? get label {
    final value = kgCo2eAvoided;
    if (value == null) return null;
    return '${formatSignificantFigures(value)} kg CO₂e';
  }
}

/// Carbon avoided from a collected mass, or the reason there is none.
///
/// ```
/// kgCO2e avoided = tonnes collected × factor(material, version)
/// ```
///
/// ## The signature is the control
///
/// There is no variant of this function that takes a bare coefficient. A caller
/// must have resolved an [EmissionFactor] — which cannot be constructed without
/// a source, a boundary, a geography and a version — so "an unsourced factor"
/// is not a mistake this function can be asked to make.
///
/// [estimatedShare] and [uncertaintyCeiling] are required rather than optional
/// for the same reason. EPR-39 forbids "any carbon figure at all for a period
/// whose `estimatedShare` exceeds a policy ceiling", and a defaulted parameter
/// is a ceiling somebody forgets to pass.
CarbonEstimate carbonAvoided({
  required int massMg,
  required EmissionFactor? factor,
  required double estimatedShare,
  required double uncertaintyCeiling,
}) {
  if (massMg <= 0) {
    return CarbonEstimate.absent(CarbonAbsence.noMass, massMg: massMg);
  }

  if (factor == null || !factor.isUsable) {
    return CarbonEstimate.absent(
      CarbonAbsence.noFactor,
      massMg: massMg,
      factor: factor,
    );
  }

  if (estimatedShare > uncertaintyCeiling) {
    // Two uncertainties compounded into one number that reads as precise. The
    // refusal is the honest output.
    return CarbonEstimate.absent(
      CarbonAbsence.tooUncertain,
      massMg: massMg,
      factor: factor,
      estimatedShare: estimatedShare,
    );
  }

  final tonnes = massMg / mgPerTonne;
  // The factor is negative for an avoided emission; the reported figure is
  // positive, and the direction lives in the wording.
  final avoided = tonnes * factor.kgCo2ePerTonne.abs();

  return CarbonEstimate.computed(
    kgCo2eAvoided: avoided,
    factor: factor,
    massMg: massMg,
  );
}

/// Chokro's default factor, with the citation the specification supplies.
///
/// ## Why a UK-derived mixed-plastics factor is the v1 default
///
/// §9.2 names it and sources it, and §15's sixth open decision recommends
/// shipping it "fully cited and caveated" while pursuing a national factor as a
/// research output. The three caveats travel with it, in the interface and in
/// every report, because each one materially limits what the figure means:
///
/// It is UK-derived, so Bangladesh's electricity mix, transport distances and
/// reprocessing routes all differ.
///
/// It is mixed plastics rather than polymer-specific, which is why the registry
/// is keyed by material — polymer-specific factors should replace it as they
/// are sourced.
///
/// The benefit is realised only if the material is actually reprocessed, which
/// loops back to §6.6: until recycler receipts exist, the figure is explicitly
/// conditional on downstream recycling.
/// EPR-39's ceiling on uncertainty before a carbon figure is refused.
///
/// A deliberate duplicate of `carbonUncertaintyCeiling` in
/// `server/src/eprPolicy.js`, which is the authority: the server refuses the
/// carbon line on a Plastic Passport above this share, and the client must
/// refuse it on the SDG card at the same point. A client that showed a figure
/// the certificate omits would have the producer reading two different answers
/// about the same period (§5.3).
///
/// ## This is the FALLBACK, not the authority
///
/// An earlier version of this comment claimed the divergence was safe because
/// "the client errs toward showing less". That reasoning is wrong, and it is
/// wrong in the direction that matters: if an Admin LOWERS the stored ceiling,
/// the certificate stops printing a carbon figure for periods above the new
/// value while a client using this constant keeps printing one. The producer
/// then has a figure on its dashboard that is absent from its own certificate,
/// with nothing to say which is right.
///
/// So `ComplianceService.loadPolicy` reads the server's value and the SDG
/// provider uses it. This constant is what applies when that read fails, which
/// is a degraded state rather than a safe one — and it is the same number as
/// the server's default, so the two agree unless an Admin has changed it.
const double carbonUncertaintyCeiling = 0.25;

const EmissionFactor turnerMixedPlastics2015 = EmissionFactor(
  id: 'mixedPlastics-2015-uk-v1',
  material: 'mixedPlastics',
  // −1,024 kg CO₂e per tonne collected for recycling.
  kgCo2ePerTonne: -1024,
  source:
      'Turner, D. A., Williams, I. D., & Kemp, S. (2015). Greenhouse gas '
      'emission factors for recycling of source-segregated waste materials. '
      'Resources, Conservation and Recycling, 105, 186–197.',
  doi: '10.1016/j.resconrec.2015.10.026',
  publicationYear: 2015,
  version: 'mixedPlastics-2015-uk-v1',
  systemBoundary: 'avoided virgin production',
  geography: 'United Kingdom',
  uncertainty: 'The source reports no uncertainty range for this figure.',
  caveats: <String>[
    'UK-derived. Bangladesh’s electricity mix, transport distances and '
        'reprocessing routes differ, so this figure is indicative rather than '
        'national.',
    'Mixed plastics, not polymer-specific. Polymer-specific factors will '
        'replace it as they are sourced.',
    'Conditional on downstream recycling. The avoided emission is realised '
        'only if the material is actually reprocessed, and Chokro’s evidence '
        'does not yet observe material arriving at a recycler.',
  ],
);
