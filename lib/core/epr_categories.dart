/// Chokro — the gazette's own vocabulary (§1, EPR-6, QA-6).
///
/// Bangladesh's *Guidelines for Extended Producer Responsibility (EPR)
/// Implementation for Plastics*, gazetted 13 August 2026, divide obligated
/// plastic products into five categories. A report is filed in those words, not
/// in Chokro's.
///
/// ## Why this is a separate vocabulary from `DisposalItemType`
///
/// The existing seven-value disposal vocabulary (`plasticBottle`,
/// `plasticOther`, `paper`, `glass`, `metal`, `eWaste`, `organic`) describes
/// what a Champion says they are throwing away. It was designed for a points
/// decision, and it does not map onto the gazette: `plasticBottle` spans rigid
/// and single-use depending on the product, `plasticOther` spans four of the
/// five categories, and three of the seven values are not plastic at all.
///
/// Translating between them would mean guessing, and a guess is exactly what a
/// Department of Environment data verification is designed to find. So the
/// gazette category is not derived from the declared item type — it is a
/// property of the *registered product*, declared by the producer who makes it
/// and checked by Chokro when the mass is verified. The declared item type only
/// narrows the recognition shortlist (EPR-15).
///
/// Plain Dart, no Firebase imports (§5.1). Every value here is a stored string
/// and is never renamed once written.
library;

/// The five plastic categories of the 2026 gazette.
class GazetteCategory {
  const GazetteCategory._();

  /// Bottles, jars, crates, drums — anything holding its own shape.
  static const String rigid = 'rigid';

  /// Films, wrappers, sachets, carrier bags, multilayer pouches.
  static const String flexible = 'flexible';

  /// Expanded polystyrene: foam food boxes, protective packaging.
  static const String eps = 'eps';

  /// Single-use items that are not on the prohibited list.
  static const String singleUse = 'singleUse';

  /// The gazette's own residual class: sanitary napkins, diapers, cigarette
  /// filters. Named "other" in the guidelines, so named "other" here — this is
  /// a real category with real obligations and not an unknown bucket.
  static const String other = 'other';

  /// Gazette order, which is the order every report and every category
  /// breakdown presents them in. Two documents that list categories in
  /// different orders invite the reader to think they disagree.
  static const List<String> all = <String>[
    rigid,
    flexible,
    eps,
    singleUse,
    other,
  ];

  static bool isValid(String value) => all.contains(value);

  static String label(String value) => switch (value) {
    rigid => 'Rigid plastic',
    flexible => 'Flexible plastic',
    eps => 'Styrofoam / EPS',
    singleUse => 'Non-prohibited single-use plastic',
    other => 'Other products',
    _ => value,
  };

  /// The short form, for table headers and chart axes where the full gazette
  /// wording does not fit.
  static String shortLabel(String value) => switch (value) {
    rigid => 'Rigid',
    flexible => 'Flexible',
    eps => 'EPS',
    singleUse => 'Single-use',
    other => 'Other',
    _ => value,
  };

  static String description(String value) => switch (value) {
    rigid => 'Bottles, jars, crates and other shape-retaining plastic.',
    flexible => 'Films, wrappers, sachets, pouches and carrier bags.',
    eps => 'Expanded polystyrene foam packaging and food containers.',
    singleUse =>
      'Single-use plastic products that are not on the prohibited list.',
    other =>
      'The gazette’s named residual class: sanitary napkins, diapers and '
          'cigarette filters.',
    _ => 'Unrecognised category.',
  };
}

/// Polymer types, declared per component of a registered product (EPR-9).
///
/// Kept separate from [GazetteCategory] because they answer different
/// questions. The category decides which gazette obligation a mass counts
/// toward; the polymer decides what the material actually is, which is what a
/// recycler, an emission factor and a packaging engineer each need.
///
/// One object usually has several. A 250 ml PET bottle is a PET body, a PP cap
/// and often a PET or PVC label sleeve — three polymers in a thing the
/// recognition model sees as one bottle.
class PolymerType {
  const PolymerType._();

  static const String pet = 'pet';
  static const String hdpe = 'hdpe';
  static const String pvc = 'pvc';
  static const String ldpe = 'ldpe';
  static const String pp = 'pp';
  static const String ps = 'ps';

  /// A laminate of two or more polymers that cannot be separated — the
  /// snack-packet case. Deliberately its own value rather than `other`, because
  /// it is the single hardest fraction to recycle and a report that hides it
  /// inside a residual bucket is hiding the part a regulator most wants to see.
  static const String multilayer = 'multilayer';

  static const String other = 'other';

  /// Resin-identification-code order for the six coded polymers, then the two
  /// that have no code. The order is stable so exports do not reshuffle.
  static const List<String> all = <String>[
    pet,
    hdpe,
    pvc,
    ldpe,
    pp,
    ps,
    multilayer,
    other,
  ];

  static bool isValid(String value) => all.contains(value);

  static String label(String value) => switch (value) {
    pet => 'PET',
    hdpe => 'HDPE',
    pvc => 'PVC',
    ldpe => 'LDPE',
    pp => 'PP',
    ps => 'PS',
    multilayer => 'Multilayer laminate',
    other => 'Other polymer',
    _ => value,
  };

  /// The resin identification code stamped on the product, where one exists.
  ///
  /// Null for [multilayer] and [other] — honestly so. Inventing a code for a
  /// laminate is how a producer ends up printing a recycling triangle on
  /// something no facility in the country can process.
  static int? resinCode(String value) => switch (value) {
    pet => 1,
    hdpe => 2,
    pvc => 3,
    ldpe => 4,
    pp => 5,
    ps => 6,
    _ => null,
  };
}

/// The gazette's collection and recycling targets, by obligation year (§1).
///
/// ## Why these are here and not in `config`
///
/// Every other threshold in this feature — verification tolerance, confidence
/// tiers, shortlist caps — lives in `config/eprPolicy` because Chokro chose it
/// and may revise it. These are not Chokro's numbers. They are the gazette's,
/// and Chokro changing them unilaterally would be changing what the law says.
///
/// They are stated as a comparison line beside a producer's own figure and
/// never as a verdict: Chokro reports what its evidence shows and prints the
/// applicable target next to it. Whether an obligation has been met is the
/// Department of Environment's finding, not this system's (EPR-26).
///
/// The guidelines make the targets themselves reviewable after three years, so
/// this class carries an explicit [reviewDueAfterYears] rather than presenting
/// the second tier as permanent.
class GazetteTargets {
  const GazetteTargets._();

  /// Years 1–2 of an entity's obligation.
  static const double earlyCollectionRate = 0.15;
  static const double earlyRecyclingRate = 0.075;

  /// Year 3 onward.
  static const double laterCollectionRate = 0.30;
  static const double laterRecyclingRate = 0.15;

  /// The guidelines make the targets subject to review after three years.
  static const int reviewDueAfterYears = 3;

  /// Which collection target applies in [obligationYear], counting the first
  /// year of obligation as 1.
  ///
  /// A year at or below zero is not a real obligation year; it returns the
  /// early rate rather than throwing, because a screen that renders a target
  /// beside a figure should degrade to the stricter-to-meet reading rather
  /// than crash on a malformed obligation start date.
  static double collectionRateForYear(int obligationYear) =>
      obligationYear >= 3 ? laterCollectionRate : earlyCollectionRate;

  static double recyclingRateForYear(int obligationYear) =>
      obligationYear >= 3 ? laterRecyclingRate : earlyRecyclingRate;
}
