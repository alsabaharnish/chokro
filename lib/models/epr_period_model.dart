/// Chokro — the period rollup that makes reporting possible (EPR-22, §5.1).
///
/// Plain Dart, no Firebase imports (§5.1).
library;

import '../core/epr_categories.dart';
import '../core/epr_period.dart';
import '../core/mass_math.dart';

/// One organisation's totals for one Asia/Dhaka month.
///
/// ## Why a stored rollup exists at all
///
/// A producer's annual report spans potentially hundreds of thousands of
/// disposals. There is no cursor paging in this codebase and no scheduler to
/// build a nightly summary (§3.3), so the totals are **incremented in the same
/// transaction that writes each attribution** and read back as one document.
///
/// That makes the rollup a derived figure that can drift from its source, which
/// is why [recomputedAt] and [recomputeMatched] exist: an Admin-triggered
/// recompute rebuilds the period from `attributions` and records whether the
/// rebuilt total matched the incremented one. Given the no-scheduler reality
/// that flag *is* the reconciliation control, and a mismatch is reportable
/// rather than silently corrected (EPR-22, QA-3).
class EprPeriodModel {
  const EprPeriodModel({
    required this.orgId,
    required this.periodId,
    this.massMgByCategory = const <String, int>{},
    this.unitsByCategory = const <String, int>{},
    this.massMgByPolymer = const <String, int>{},
    this.massMgByDistrict = const <String, int>{},
    this.attributionCount = 0,
    this.disposalCount = 0,
    this.skuIds = const <String>[],
    this.uncertainMassMg = 0,
    this.unattributedDisposalCount = 0,
    this.reversedCount = 0,
    this.reversedMassMg = 0,
    this.districtSuppressed = false,
    this.kAnonymityFloor,
    this.recomputedAt,
    this.recomputeMatched,
    this.recomputedMassMg,
  });

  final String orgId;
  final String periodId;

  /// Gazette category → integer milligrams.
  final Map<String, int> massMgByCategory;
  final Map<String, int> unitsByCategory;

  /// Polymer → integer milligrams, from the component breakdowns. One
  /// recognised bottle contributes to several of these (EPR-9).
  final Map<String, int> massMgByPolymer;

  final Map<String, int> massMgByDistrict;

  final int attributionCount;

  /// Distinct disposals that produced at least one attribution. Lower than
  /// [attributionCount] when one photograph contained two registered products.
  final int disposalCount;

  /// The distinct products attributed in this period.
  ///
  /// A SET, NOT A COUNTER, AND THE DIFFERENCE MATTERS.
  ///
  /// `uniqueSkuCount` used to be a stored integer. It was declared here,
  /// recomputed by the reconciliation, and incremented nowhere — so it read 0
  /// for every period, and a passport would have printed "0 distinct products"
  /// beside a real mass.
  ///
  /// A counter could not have fixed it: `FieldValue.increment(1)` on every
  /// attribution counts rows rather than products, and nothing inside an
  /// increment can ask whether this product has been seen before.
  /// `FieldValue.arrayUnion` adds only what is absent, so the stored value is
  /// exactly a set — and idempotent, which matters because attribution can be
  /// retried.
  ///
  /// The count is derived from the set's length rather than stored beside it,
  /// so the two cannot drift.
  final List<String> skuIds;

  /// Mass from medium-confidence matches (EPR-17, EPR-37).
  ///
  /// Stored as a mass rather than a ratio so [estimatedShare] can be derived
  /// exactly from two integers instead of a stored float that would drift from
  /// the totals it describes.
  final int uncertainMassMg;

  /// Approved disposals of this producer's declared item types that yielded no
  /// match (EPR-19).
  ///
  /// Counted, because the unattributed pool is reported as its own line and an
  /// absent count would read as an empty pool.
  final int unattributedDisposalCount;

  final int reversedCount;
  final int reversedMassMg;

  /// Whether the geographic breakdown was withheld for privacy (SEC-3).
  ///
  /// True when this period's disposal count is below the k-anonymity floor. A
  /// district row built from one or two disposals says where an identifiable
  /// person threw something away, which is the disclosure SEC-3's floor exists
  /// to prevent.
  ///
  /// SUPPRESSION IS STATED, NOT SILENT. An empty district map with this flag
  /// false means "no geography recorded"; with it true it means "withheld".
  /// Those are different facts and a screen must not render them the same way —
  /// the first would be a false claim about Chokro's evidence.
  ///
  /// The server never sends `lastAttributionAt` at all, so this model has no
  /// field for it. On a period with one disposal, a second-precision timestamp
  /// is the exact moment of one person's act.
  final bool districtSuppressed;

  /// The floor in force, so the screen can say how many disposals a period
  /// needs before its geography is shown.
  final int? kAnonymityFloor;

  /// When a recompute last rebuilt this period from `attributions`.
  final DateTime? recomputedAt;

  /// Whether the rebuilt total matched the incremented one.
  ///
  /// Null means never recomputed — which is not the same as "matched", and no
  /// surface may present it as such.
  final bool? recomputeMatched;

  final int? recomputedMassMg;

  /// Total attributed mass, summed from the category breakdown.
  ///
  /// Derived rather than stored, so it cannot disagree with the breakdown a
  /// report prints beside it. Two figures in one document that can drift apart
  /// is how a regulator finds an inconsistency Chokro cannot explain.
  int get totalMassMg => sumMilligrams(massMgByCategory.values).totalMg;

  int get totalUnits =>
      unitsByCategory.values.fold(0, (sum, units) => sum + units);

  /// How many distinct products contributed to this period.
  int get uniqueSkuCount => skuIds.length;

  String get totalMassLabel => formatKilograms(totalMassMg);

  String get label => periodLabel(periodId);

  bool get hasActivity => attributionCount > 0 || unattributedDisposalCount > 0;

  /// The share of attributed mass that came from medium-confidence matches.
  ///
  /// Zero when there is no mass — not null, because "no uncertain mass in no
  /// mass" is a true and useful statement, unlike a percentage of nothing.
  double get estimatedShare {
    final total = totalMassMg;
    if (total <= 0) return 0;
    return uncertainMassMg / total;
  }

  /// Whether a reconciliation has been run and disagreed (EPR-48).
  bool get hasRecomputeMismatch => recomputeMatched == false;

  /// Whether this period has ever been reconciled.
  bool get isReconciled => recomputedAt != null;

  /// Category totals in gazette order, skipping categories with no mass.
  ///
  /// Gazette order rather than stored order, so two periods' breakdowns are
  /// directly comparable on screen and in an export.
  List<({String category, int massMg, int units})> get categoryBreakdown => [
    for (final category in GazetteCategory.all)
      if ((massMgByCategory[category] ?? 0) > 0)
        (
          category: category,
          massMg: massMgByCategory[category] ?? 0,
          units: unitsByCategory[category] ?? 0,
        ),
  ];

  /// Polymer totals in resin-code order, skipping polymers with no mass.
  List<({String polymer, int massMg})> get polymerBreakdown => [
    for (final polymer in PolymerType.all)
      if ((massMgByPolymer[polymer] ?? 0) > 0)
        (polymer: polymer, massMg: massMgByPolymer[polymer] ?? 0),
  ];

  /// Districts by mass, heaviest first. Bounded by the caller.
  List<({String district, int massMg})> get districtBreakdown {
    final rows = [
      for (final entry in massMgByDistrict.entries)
        if (entry.value > 0) (district: entry.key, massMg: entry.value),
    ];
    rows.sort((a, b) => b.massMg.compareTo(a.massMg));
    return rows;
  }

  /// An empty period, for a month with nothing in it.
  ///
  /// A real object rather than null, so a screen renders "no activity recorded"
  /// from a period that knows its own id rather than from an absence it has to
  /// interpret.
  factory EprPeriodModel.empty({
    required String orgId,
    required String periodId,
  }) => EprPeriodModel(orgId: orgId, periodId: periodId);

  factory EprPeriodModel.fromJson(
    Map<String, dynamic> json, {
    String? id,
  }) {
    final storedOrgId = _string(json['orgId']);
    final storedPeriodId = _string(json['periodId']);

    return EprPeriodModel(
      orgId: storedOrgId,
      periodId: isValidPeriodId(storedPeriodId) ? storedPeriodId : '',
      massMgByCategory: _keyedMap(
        json['massMgByCategory'],
        GazetteCategory.isValid,
      ),
      unitsByCategory: _keyedMap(
        json['unitsByCategory'],
        GazetteCategory.isValid,
      ),
      massMgByPolymer: _keyedMap(json['massMgByPolymer'], PolymerType.isValid),
      // Districts are free text from the bin registry, so anything non-empty
      // is kept — there is no closed vocabulary to validate against.
      massMgByDistrict: _keyedMap(json['massMgByDistrict'], (k) => k.isNotEmpty),
      attributionCount: _counter(json['attributionCount']),
      disposalCount: _counter(json['disposalCount']),
      skuIds: _stringList(json['skuIds']),
      uncertainMassMg: _counter(json['uncertainMassMg']),
      unattributedDisposalCount: _counter(json['unattributedDisposalCount']),
      reversedCount: _counter(json['reversedCount']),
      reversedMassMg: _counter(json['reversedMassMg']),
      districtSuppressed: json['districtSuppressed'] == true,
      kAnonymityFloor: _int(json['kAnonymityFloor']),
      recomputedAt: _date(json['recomputedAt']),
      recomputeMatched: json['recomputeMatched'] is bool
          ? json['recomputeMatched'] as bool
          : null,
      recomputedMassMg: _int(json['recomputedMassMg']),
    );
  }
}

/// A map keyed by a validated vocabulary, dropping anything else.
///
/// An unrecognised key would put mass on a line the gazette does not have. It
/// is dropped rather than rendered, and the drop is visible because the
/// breakdown then stops summing to the total.
Map<String, int> _keyedMap(Object? value, bool Function(String) isValidKey) {
  if (value is! Map) return const <String, int>{};

  final totals = <String, int>{};
  for (final entry in value.entries) {
    final key = entry.key;
    if (key is! String || !isValidKey(key)) continue;
    final mg = _counter(entry.value);
    if (mg > 0) totals[key] = mg;
  }
  return totals;
}

/// A stored list of ids, dropping anything that is not a usable id.
///
/// Deduplicated on read as well as on write: `arrayUnion` guarantees
/// distinctness, but a document written by a migration or an earlier release
/// need not have used it, and a duplicated id would overstate the variety a
/// report claims.
List<String> _stringList(Object? value) {
  if (value is! List) return const <String>[];
  final seen = <String>{};
  for (final entry in value) {
    if (entry is String && entry.isNotEmpty) seen.add(entry);
  }
  return seen.toList(growable: false);
}

/// A stored counter, tolerating what a malformed document might hold.
///
/// Negative and non-numeric values read as zero, matching `stats_model.dart`'s
/// established behaviour — a counter that went negative is corrupt, and a
/// corrupt counter must not subtract from a compliance figure.
int _counter(Object? value) {
  if (value is int) return value > 0 ? value : 0;
  if (value is num && value.isFinite) {
    final rounded = value.toInt();
    return rounded > 0 ? rounded : 0;
  }
  return 0;
}

String _string(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  return null;
}

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
