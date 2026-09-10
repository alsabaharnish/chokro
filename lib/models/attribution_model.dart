/// Chokro — the atomic evidence record (EPR-20, EPR-21, §5.1).
///
/// Plain Dart, no Firebase imports (§5.1).
library;

import '../core/epr_categories.dart';
import '../core/mass_math.dart';

/// How a match was made.
///
/// Stored strings, never renamed (QA-6). The value matters beyond provenance:
/// EPR-19 requires that if a category-average estimate is ever introduced it
/// must be a **distinct method value**, excluded from the headline figure and
/// labelled as an estimate on every surface. Keeping this a closed set is what
/// makes that separation enforceable later rather than a convention.
class AttributionMethod {
  const AttributionMethod._();

  /// The recognition model matched a registered product in the photograph.
  static const String aiSku = 'aiSku';

  /// A Champion scanned the product's GTIN (EPR-18).
  ///
  /// Preferred wherever available. Visual brand recognition of a crushed bottle
  /// in a dim bin at dusk is a hard computer-vision problem; reading a barcode
  /// is a solved one, so where a Champion scans, accuracy stops being
  /// probabilistic.
  static const String barcode = 'barcode';

  /// A person confirmed a low-confidence or disputed match.
  static const String humanReview = 'humanReview';

  /// An Admin attributed by hand, always with a reason.
  static const String manualAdmin = 'manualAdmin';

  static const List<String> all = <String>[
    aiSku,
    barcode,
    humanReview,
    manualAdmin,
  ];

  /// The methods whose mass belongs in a reported figure.
  ///
  /// All four, today. The list exists so that adding an estimating method
  /// later is a change to *this* list — visible in review — rather than an
  /// estimate silently joining a headline total (EPR-19).
  static const List<String> reportable = <String>[
    aiSku,
    barcode,
    humanReview,
    manualAdmin,
  ];

  static bool isValid(String value) => all.contains(value);

  static bool isReportable(String value) => reportable.contains(value);

  static String label(String value) => switch (value) {
    aiSku => 'Recognised in the photograph',
    barcode => 'Barcode scanned',
    humanReview => 'Confirmed by a person',
    manualAdmin => 'Attributed by a 3ZERO Admin',
    _ => value,
  };
}

/// The confidence band a match fell into (EPR-17).
class ConfidenceTier {
  const ConfidenceTier._();

  /// Attributed automatically.
  static const String high = 'high';

  /// Attributed, flagged, added to the sampling audit queue, and counted in
  /// `estimatedShare` — so a producer can see how much of its figure is
  /// uncertain. "A producer that cannot see how much of its number is uncertain
  /// will publish the number as if it were certain."
  static const String medium = 'medium';

  /// **Not** attributed. Queued for human confirmation.
  static const String low = 'low';

  static const List<String> all = <String>[high, medium, low];

  static bool isValid(String value) => all.contains(value);

  static String label(String value) => switch (value) {
    high => 'High confidence',
    medium => 'Medium confidence',
    low => 'Low confidence',
    _ => value,
  };
}

/// Where a disposal stands in the attribution pipeline (EPR-6).
///
/// Server-owned on `disposals`. The client create allowlist in
/// `firestore.rules` must not grow by a single key — if a client can write a
/// mass, the mass is worthless.
class AttributionStatus {
  const AttributionStatus._();

  /// No attribution has been attempted. The ordinary state of every disposal
  /// decided before this feature existed, and of every rejected one.
  static const String none = 'none';

  /// Approved and waiting for attribution, or attribution failed and will be
  /// retried. **Not** an error state: a screening outage must degrade
  /// attribution, not disposal (EPR-16).
  static const String pending = 'pending';

  static const String attributed = 'attributed';

  /// Recognition ran and matched nothing usable. Contributes to the visible
  /// unattributed pool (EPR-19). Never silently attributed as generic.
  static const String unattributable = 'unattributable';

  static const List<String> all = <String>[
    none,
    pending,
    attributed,
    unattributable,
  ];

  static String label(String value) => switch (value) {
    none => 'Not attributed',
    pending => 'Awaiting attribution',
    attributed => 'Attributed',
    unattributable => 'No product recognised',
    _ => value,
  };
}

/// One (disposal, SKU) pair — the atomic evidence record.
///
/// ## Why every one of these fields is stored rather than derived
///
/// A report must remain reproducible from retained inputs for the DoE's audit
/// horizon (NFR-E-8), and "reproducible" means the figure can be rebuilt
/// without consulting anything that may since have changed.
///
/// So the attribution stores the `skuRevision` **and** the `unitMassGUsed` it
/// actually multiplied by, not a reference to the product. When a bottle is
/// re-weighed in November, September's figure is still 9.8 g per unit because
/// September's rows say so. Reading the current product would silently rewrite
/// history (EPR-12).
///
/// The same reasoning covers `gazetteCategory`, `polymer`, `district` and
/// `city`: each is a property of the product or the bin at the moment of
/// disposal, and each can be edited afterwards.
class AttributionModel {
  const AttributionModel({
    required this.id,
    required this.disposalId,
    required this.orgId,
    required this.skuId,
    required this.skuRevision,
    required this.units,
    required this.unitMassMgUsed,
    required this.massMg,
    required this.method,
    required this.confidenceTier,
    required this.periodId,
    this.binId = '',
    this.district = '',
    this.city = '',
    this.gazetteCategory = '',
    this.polymer = '',
    this.massMgByPolymer = const <String, int>{},
    this.confidence,
    this.disposalDecidedAt,
    this.createdAt,
    this.reversedBy,
    this.reversedAt,
    this.reversedReason,
  });

  final String id;

  /// The disposal this evidence came from.
  ///
  /// Never shown to a producer. SEC-3 requires a per-organisation pseudonymous
  /// reference in any row-level export, so two organisations cannot correlate
  /// the same event — or the same person — across their exports.
  final String disposalId;

  final String orgId;
  final String skuId;

  /// The revision in force when the disposal was decided (EPR-12).
  final int skuRevision;

  /// How many units of this product were recognised.
  final int units;

  /// The verified unit mass that revision carried, in integer milligrams.
  final int unitMassMgUsed;

  /// `units × unitMassMgUsed`, exact (EPR-20).
  final int massMg;

  final String method;
  final String confidenceTier;

  /// `YYYY-MM`, Asia/Dhaka, derived on the server from the decision timestamp.
  final String periodId;

  final String binId;
  final String district;
  final String city;

  final String gazetteCategory;
  final String polymer;

  /// The component breakdown applied to this many units.
  ///
  /// Stored rather than recomputed, because it depends on the product's
  /// components *as declared at that revision*. This is what lets one
  /// recognised bottle contribute to a PET line and a PP line in the same
  /// report while remaining one unit (EPR-9).
  final Map<String, int> massMgByPolymer;

  /// The model's own confidence. Null for a barcode or a human confirmation,
  /// honestly — neither is probabilistic.
  final double? confidence;

  final DateTime? disposalDecidedAt;
  final DateTime? createdAt;

  /// Reversed, never deleted (EPR-21).
  ///
  /// An attribution that must be undone is marked, with a reason, so the
  /// evidence that it once existed survives. A deleted row makes a period's
  /// arithmetic unreproducible and a recompute mismatch unexplainable.
  final String? reversedBy;
  final DateTime? reversedAt;
  final String? reversedReason;

  bool get isReversed => reversedAt != null;

  /// Whether this row's mass belongs in a reported figure.
  ///
  /// Three conditions, and all three matter: a reversed row is out, an
  /// unreportable method is out (EPR-19's future estimate case), and a
  /// low-confidence row should never have been written at all.
  bool get isReportable =>
      !isReversed &&
      AttributionMethod.isReportable(method) &&
      confidenceTier != ConfidenceTier.low;

  /// Whether this row counts toward `estimatedShare` (EPR-17, EPR-37).
  bool get isUncertain => confidenceTier == ConfidenceTier.medium;

  String get massLabel => formatGrams(massMg);

  factory AttributionModel.fromJson(
    Map<String, dynamic> json, {
    required String id,
  }) {
    return AttributionModel(
      id: id,
      disposalId: _string(json['disposalId']),
      orgId: _string(json['orgId']),
      skuId: _string(json['skuId']),
      skuRevision: _int(json['skuRevision']) ?? 0,
      units: _int(json['units']) ?? 0,
      unitMassMgUsed: _int(json['unitMassMgUsed']) ?? 0,
      massMg: _int(json['massMg']) ?? 0,
      // Fail closed on both. An unrecognised method must not be treated as
      // reportable, and an unrecognised tier must not be treated as high —
      // `low` is the tier that contributes nothing.
      method: AttributionMethod.isValid(_string(json['method']))
          ? _string(json['method'])
          : '',
      confidenceTier: ConfidenceTier.isValid(_string(json['confidenceTier']))
          ? _string(json['confidenceTier'])
          : ConfidenceTier.low,
      periodId: _string(json['periodId']),
      binId: _string(json['binId']),
      district: _string(json['district']),
      city: _string(json['city']),
      gazetteCategory: GazetteCategory.isValid(_string(json['gazetteCategory']))
          ? _string(json['gazetteCategory'])
          : '',
      polymer: PolymerType.isValid(_string(json['polymer']))
          ? _string(json['polymer'])
          : '',
      massMgByPolymer: _polymerMap(json['massMgByPolymer']),
      confidence: _double(json['confidence']),
      disposalDecidedAt: _date(json['disposalDecidedAt']),
      createdAt: _date(json['createdAt']),
      reversedBy: _nullableString(json['reversedBy']),
      reversedAt: _date(json['reversedAt']),
      reversedReason: _nullableString(json['reversedReason']),
    );
  }
}

/// A polymer → milligrams map, dropping anything unrecognised.
///
/// An unknown polymer key would put grams on a line the gazette does not have,
/// so it is dropped rather than displayed — and the drop is visible, because
/// the polymer totals will then not sum to `massMg`.
Map<String, int> _polymerMap(Object? value) {
  if (value is! Map) return const <String, int>{};

  final totals = <String, int>{};
  for (final entry in value.entries) {
    final key = entry.key;
    final mg = _int(entry.value);
    if (key is String && PolymerType.isValid(key) && mg != null && mg >= 0) {
      totals[key] = mg;
    }
  }
  return totals;
}

String _string(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;

String? _nullableString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.toInt();
  return null;
}

double? _double(Object? value) =>
    value is num && value.isFinite ? value.toDouble() : null;

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
