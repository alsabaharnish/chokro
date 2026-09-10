import '../core/carbon_math.dart';
import '../core/compliance_math.dart';
import 'epr_period_model.dart';

/// One producer's SDG alignment for one reporting period (EPR-36, EPR-37).
///
/// ## Why this is a model and not view code
///
/// EPR-36 asks for "a pure, testable derivation with **no arithmetic in the
/// view**", in the same shape as the existing [SdgImpactSnapshot]. The reason
/// is the same one that put `SdgImpactSnapshot` in a model: an impact figure
/// computed inline in a widget is a figure nobody can write a test against, and
/// these are figures a company will put in an annual report.
///
/// ## What every card here is careful NOT to say
///
/// The spec's table gives each alignment a "required interpretation", and each
/// one is a limit rather than a caveat:
///
///   Goal 12 — collected and attributed, **not recycled**. Chokro records
///     collection; what happened downstream is not its evidence (§6.6).
///   Goal 11 — recovery from **registered bins**, not municipal
///     waste-diversion measurement. Chokro sees its own network, not a city.
///   Goal 13 — a **factor-based estimate** with a stated boundary and
///     uncertainty, not a measured or verified reduction, and never a credit.
///   Goal 8 — **participation records**; not employment, income, or jobs
///     created. Chokro knows how many accounts acted, not what they earned.
///   Goal 17 — descriptive. Participation in shared reporting infrastructure
///     is a fact about taking part, not an outcome.
///
/// ## Why the cards are not additive
///
/// Goal 12 and Goal 11 read the same collected mass through two different
/// lenses. Summing them would double-count every gram. The existing Admin SDG
/// dashboard makes the same point and this inherits it: [totalMassMg] is stated
/// once, and each card is a view onto it.
class ProducerSdgSnapshot {
  const ProducerSdgSnapshot({
    required this.periodId,
    required this.totalMassMg,
    required this.categoryMassMg,
    required this.districtMassMg,
    required this.districtCount,
    required this.districtSuppressed,
    required this.attributionCount,
    required this.disposalCount,
    required this.uniqueSkuCount,
    required this.estimatedShare,
    required this.reversedCount,
    required this.collectionRate,
    required this.carbon,
  });

  /// Builds a snapshot from stored evidence.
  ///
  /// Both inputs are already-derived objects: [EprPeriodModel] is a pure
  /// derivation over stored integers, and [CollectionRate] cannot exist without
  /// either a rate or a stated reason for its absence. Nothing here invents a
  /// figure; it selects and labels.
  factory ProducerSdgSnapshot.from({
    required EprPeriodModel period,
    required CollectionRate collectionRate,
    required CarbonEstimate carbon,
  }) {
    return ProducerSdgSnapshot(
      periodId: period.periodId,
      totalMassMg: period.totalMassMg,
      categoryMassMg: Map.unmodifiable(period.massMgByCategory),
      districtMassMg: Map.unmodifiable(period.massMgByDistrict),
      districtCount: period.massMgByDistrict.length,
      // The k-anonymity floor applied to the district breakdown (SEC-3). When
      // it fired, the geographic card is reporting on a partial view and says
      // so — a producer publishing "recovered across 12 districts" from a
      // suppressed breakdown would be publishing a number Chokro withheld.
      districtSuppressed: period.districtSuppressed,
      attributionCount: period.attributionCount,
      disposalCount: period.disposalCount,
      uniqueSkuCount: period.uniqueSkuCount,
      estimatedShare: period.estimatedShare,
      reversedCount: period.reversedCount,
      collectionRate: collectionRate,
      carbon: carbon,
    );
  }

  final String periodId;

  /// Stated once, because Goal 12 and Goal 11 are two lenses on it and adding
  /// them would double-count every gram.
  final int totalMassMg;

  final Map<String, int> categoryMassMg;
  final Map<String, int> districtMassMg;
  final int districtCount;

  /// Whether the district breakdown was suppressed by the k-anonymity floor.
  final bool districtSuppressed;

  final int attributionCount;
  final int disposalCount;
  final int uniqueSkuCount;

  /// The share of [totalMassMg] resting on medium-confidence matches.
  ///
  /// EPR-37 puts this on every card that carries mass, not behind a tooltip:
  /// "A producer that cannot see how much of its number is uncertain will
  /// publish the number as if it were certain."
  final double estimatedShare;

  final int reversedCount;

  /// The collection percentage, or the stated reason there is none (EPR-24).
  final CollectionRate collectionRate;

  /// The carbon estimate, or the stated reason there is none (EPR-38, EPR-39).
  final CarbonEstimate carbon;

  /// Whether anything at all was recorded for this period.
  ///
  /// A period with no activity gets one honest sentence rather than five cards
  /// of zeros, which would read as five measured outcomes of nothing.
  bool get hasRecordedActivity => attributionCount > 0 || totalMassMg > 0;

  /// Whether enough of this period rests on estimates to warrant saying so
  /// prominently rather than in a footnote.
  bool get isSubstantiallyEstimated => estimatedShare >= 0.10;

  /// The alignments, in the order EPR-36's table gives them.
  ///
  /// Built here rather than in the view so the set of claims Chokro makes is
  /// one testable list, and adding a sixth is a change to a model with a test
  /// rather than a change to a widget tree.
  List<ProducerSdgAlignment> get alignments => <ProducerSdgAlignment>[
    ProducerSdgAlignment(
      goal: 12,
      target: '12.5',
      title: 'Substantially reduce waste generation',
      signal: 'Mass collected by gazette category, and the collection '
          'percentage where a declaration exists.',
      // Not a summary of the limit — the limit itself, in the words a reader
      // would otherwise supply wrongly.
      boundary: 'Collected and attributed through Chokro, not recycled. '
          'Chokro holds no evidence of what happened downstream. Overlaps '
          'Goal 11 below; the two are not additive.',
      carriesMass: true,
    ),
    ProducerSdgAlignment(
      goal: 11,
      target: '11.6',
      title: 'Reduce the environmental impact of cities',
      signal: districtSuppressed
          ? 'Geographic recovery across registered bins. The district '
                'breakdown is withheld for this period because too few '
                'records fall in some districts to report them without '
                'identifying individual disposals.'
          : 'Geographic recovery across $districtCount '
                '${districtCount == 1 ? 'district' : 'districts'} and the '
                'registered bin network.',
      boundary: 'Recovery from registered bins, not municipal waste-diversion '
          'measurement. Chokro sees its own network, not a city. Overlaps '
          'Goal 12 above; the two are not additive.',
      carriesMass: true,
    ),
    ProducerSdgAlignment(
      goal: 13,
      target: '13.3',
      title: 'Improve capacity on climate change mitigation',
      signal: carbon.kgCo2eAvoided == null
          ? 'No avoided-emissions estimate is stated for this period.'
          : 'An indicative avoided-emissions estimate from a published '
                'external factor, with $attributionCount attributed '
                'collection ${attributionCount == 1 ? 'event' : 'events'}.',
      boundary: 'A factor-based estimate with a stated boundary and '
          'uncertainty — not a measured reduction, not a verified carbon '
          'credit, and not an offset.',
      carriesMass: true,
    ),
    ProducerSdgAlignment(
      goal: 8,
      target: '8.3',
      title: 'Support productive activities and decent job creation',
      signal: '$disposalCount disposal '
          '${disposalCount == 1 ? 'event' : 'events'} from Champions and '
          'collectors involved your material this period.',
      boundary: 'Participation records only. Chokro does not measure '
          'employment, income or jobs created, and this is not evidence of '
          'any of them.',
      carriesMass: false,
    ),
    const ProducerSdgAlignment(
      goal: 17,
      target: '17.16',
      title: 'Partnerships for the goals',
      signal: 'Participation in a shared producer-responsibility reporting '
          'infrastructure alongside other obligated companies.',
      boundary: 'Descriptive. Taking part is a fact about participation, not '
          'an outcome, and Chokro claims nothing further from it.',
      carriesMass: false,
    ),
  ];
}

/// One SDG alignment card (EPR-36, EPR-37).
///
/// [boundary] is required and has no default. An alignment without its stated
/// limit is exactly the thing §11's prohibited-claims list forbids, and making
/// it optional would let one be added without one.
class ProducerSdgAlignment {
  const ProducerSdgAlignment({
    required this.goal,
    required this.target,
    required this.title,
    required this.signal,
    required this.boundary,
    required this.carriesMass,
  });

  final int goal;
  final String target;
  final String title;

  /// What Chokro's records actually show.
  final String signal;

  /// What this alignment does NOT state. Required, never defaulted.
  final String boundary;

  /// Whether this card's figure derives from collected mass.
  ///
  /// Drives whether the estimated share is shown on it (EPR-37): a
  /// participation count is not more or less certain because some of the mass
  /// was a medium-confidence match, so putting an uncertainty figure on it
  /// would be noise that teaches the reader to ignore the ones that matter.
  final bool carriesMass;
}
