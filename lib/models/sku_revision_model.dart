/// Chokro — the immutable history of every declared and verified mass
/// (EPR-12, EPR-11, §5.1).
///
/// Plain Dart, no Firebase imports (§5.1).
library;

import '../core/mass_math.dart';

/// Why a revision opened.
class RevisionReason {
  const RevisionReason._();

  /// The first verified mass for this SKU.
  static const String initialVerification = 'initialVerification';

  /// A re-weighing found a different mass. Packaging is light-weighted
  /// constantly — a 2026 bottle weighs less than a 2024 one — so this is the
  /// ordinary case, not the exceptional one (EPR-13).
  static const String reweighed = 'reweighed';

  /// The producer changed the declaration, which invalidates the verification
  /// that was based on the old one.
  static const String declarationChanged = 'declarationChanged';

  /// An Admin set the figure directly, with a stated reason (EPR-11 case 3).
  static const String adminOverride = 'adminOverride';

  /// A manufacturer's technical data sheet or packaging specification, checked
  /// by an Admin, for an SKU Chokro cannot obtain (EPR-11 case 2).
  static const String documentary = 'documentary';

  static const List<String> all = <String>[
    initialVerification,
    reweighed,
    declarationChanged,
    adminOverride,
    documentary,
  ];

  static String label(String value) => switch (value) {
    initialVerification => 'First verification',
    reweighed => 'Re-weighed',
    declarationChanged => 'Declaration changed',
    adminOverride => 'Admin override',
    documentary => 'Verified from documentation',
    _ => value,
  };
}

/// One row of `skuRevisions/{skuId}_{revision}` — append-only.
///
/// ## Why this collection is a compliance requirement, not a nicety
///
/// A report issued last quarter must remain reproducible after a producer edits
/// a gram weight this quarter. Without a stored history of what the verified
/// mass *was*, and when, that is impossible: the only figure available would be
/// the current one, and re-running last quarter's report would silently produce
/// a different answer.
///
/// So a verified mass is never edited in place (EPR-12). A change closes the
/// standing revision with an `activeTo` and opens the next with an
/// `activeFrom`; every attribution stores the revision and the unit mass it
/// actually used. September's passport stays correct after November's
/// re-weighing because nothing rewrote September.
class SkuRevisionModel {
  const SkuRevisionModel({
    required this.id,
    required this.skuId,
    required this.orgId,
    required this.revision,
    required this.declaredUnitMassMg,
    this.verifiedUnitMassMg,
    this.reason = '',
    this.note,
    this.changedBy = '',
    this.auditId,
    this.activeFrom,
    this.activeTo,
    this.createdAt,
  });

  final String id;
  final String skuId;
  final String orgId;

  /// Monotonic, starting at 1.
  final int revision;

  /// What the producer declared at the time of this revision.
  final int declaredUnitMassMg;

  /// What Chokro established. Null on a revision that recorded a declaration
  /// change but not yet a verification.
  final int? verifiedUnitMassMg;

  /// One of [RevisionReason].
  final String reason;

  /// The Admin's own words. Mandatory for an override (EPR-11), because a
  /// figure set by hand with no stated basis is exactly what a DoE data
  /// verification would ask about.
  final String? note;

  final String changedBy;

  /// The `skuMassAudits` document behind this revision, where there is one.
  /// Null for a documentary verification or an override.
  final String? auditId;

  final DateTime? activeFrom;

  /// Null while this revision is the one in force.
  final DateTime? activeTo;

  final DateTime? createdAt;

  bool get isCurrent => activeTo == null && activeFrom != null;

  /// Whether this revision was in force at [moment].
  ///
  /// The same window test as [ProducerSkuModel.wasActiveAt], written once per
  /// type rather than shared, because the two are read in different places and
  /// a shared helper would hide which document answered the question.
  bool wasActiveAt(DateTime moment) {
    final from = activeFrom;
    if (from == null) return false;
    if (moment.isBefore(from)) return false;
    final to = activeTo;
    return to == null || moment.isBefore(to);
  }

  /// How far the verified mass departed from the declared one, as a fraction.
  ///
  /// Null when either figure is missing, or when the declared mass is zero —
  /// there is no meaningful proportion of nothing, and returning zero would
  /// read as "no discrepancy".
  double? get varianceFromDeclared {
    final verified = verifiedUnitMassMg;
    if (verified == null || declaredUnitMassMg <= 0) return null;
    return (verified - declaredUnitMassMg) / declaredUnitMassMg;
  }

  String get declaredLabel => formatGrams(declaredUnitMassMg);

  String? get verifiedLabel =>
      verifiedUnitMassMg == null ? null : formatGrams(verifiedUnitMassMg!);

  /// The composite document id. One function, so client, server and rules tests
  /// cannot drift into composing it differently.
  static String documentId(String skuId, int revision) => '${skuId}_$revision';

  factory SkuRevisionModel.fromJson(
    Map<String, dynamic> json, {
    required String id,
  }) {
    return SkuRevisionModel(
      id: id,
      skuId: _string(json['skuId']),
      orgId: _string(json['orgId']),
      revision: _int(json['revision']) ?? 0,
      declaredUnitMassMg: _int(json['declaredUnitMassMg']) ??
          milligramsFromGrams(json['declaredUnitMassG']) ??
          0,
      verifiedUnitMassMg: _int(json['verifiedUnitMassMg']) ??
          milligramsFromGrams(json['verifiedUnitMassG']),
      reason: RevisionReason.all.contains(_string(json['reason']))
          ? _string(json['reason'])
          : '',
      note: _nullableString(json['note']),
      changedBy: _string(json['changedBy']),
      auditId: _nullableString(json['auditId']),
      activeFrom: _date(json['activeFrom']),
      activeTo: _date(json['activeTo']),
      createdAt: _date(json['createdAt']),
    );
  }
}

/// Whether a physical re-weighing accepted or rejected the declared mass.
class MassAuditVerdict {
  const MassAuditVerdict._();

  static const String withinTolerance = 'withinTolerance';
  static const String outsideTolerance = 'outsideTolerance';

  static const List<String> all = <String>[withinTolerance, outsideTolerance];

  static String label(String value) => switch (value) {
    withinTolerance => 'Within tolerance',
    outsideTolerance => 'Outside tolerance',
    _ => value,
  };
}

/// A physical re-weighing (EPR-11 case 1, §5.1 `skuMassAudits`).
///
/// ## Why this record exists rather than just a number
///
/// The producer supplies the number that multiplies into every kilogram Chokro
/// will ever report on its behalf, and it has an incentive to overstate it:
/// a heavier declared unit inflates collected kilograms and any plastic credit.
/// Chokro's answer is to weigh the thing — and a weighing that leaves no record
/// of the sample size, the spread, the scale reading or who held the scale is
/// not evidence a DoE inspector can check. It is a claim that a weighing
/// happened.
///
/// So the audit is the artefact and the verified mass is its consequence, not
/// the other way round.
class SkuMassAuditModel {
  const SkuMassAuditModel({
    required this.id,
    required this.skuId,
    required this.orgId,
    required this.sampleSize,
    required this.measuredMeanMg,
    required this.declaredUnitMassMg,
    required this.verdict,
    this.measuredStdDevMg,
    this.weighingLocation = '',
    this.operatorUid = '',
    this.scalePhotoUrl,
    this.resultingAction = '',
    this.toleranceFraction,
    this.createdAt,
  });

  final String id;
  final String skuId;
  final String orgId;

  /// How many units were weighed. Policy default is five (EPR-11), held in
  /// `config/eprPolicy` rather than as a constant in code.
  final int sampleSize;

  final int measuredMeanMg;

  /// The spread. A mean with no spread beside it says nothing about whether the
  /// sample was consistent — five units at 9.8 g and five units averaging 9.8 g
  /// from a range of 6 to 14 support very different conclusions.
  final int? measuredStdDevMg;

  final int declaredUnitMassMg;

  final String verdict;

  final String weighingLocation;
  final String operatorUid;

  /// A photograph of the scale reading. The part that makes the figure
  /// checkable by somebody who was not in the room.
  final String? scalePhotoUrl;

  final String resultingAction;

  /// The tolerance in force when this audit was judged, stored on the record.
  ///
  /// Stored rather than read from current policy, for the same reason a
  /// disposal snapshots its points award: an Admin tightening the tolerance
  /// later must not retrospectively change whether a past audit passed.
  final double? toleranceFraction;

  final DateTime? createdAt;

  /// The measured departure from the declared figure, as a fraction.
  double? get varianceFromDeclared {
    if (declaredUnitMassMg <= 0) return null;
    return (measuredMeanMg - declaredUnitMassMg) / declaredUnitMassMg;
  }

  /// The mass this audit establishes: always the measurement.
  ///
  /// The tolerance judges the *declaration*, not which number is used.
  ///
  /// EPR-11's wording reads as though a declaration inside the tolerance is
  /// kept; Appendix A step 3 does the opposite, recording a measured 9.8 g as
  /// the verified mass against a declared 10.0 g that was "within the ± 10%
  /// tolerance", and stating in bold that reporting uses 9.8. Appendix A is
  /// right: keeping the declaration whenever it is close enough turns the
  /// tolerance into a licence to overstate by just under it, repeatably, across
  /// a whole catalogue. A five-unit mean has sampling error, but that error is
  /// unbiased.
  ///
  /// The verdict survives as a finding about the declaration, for the audit
  /// pack and the anomaly queue.
  int get establishedUnitMassMg => measuredMeanMg;

  String get measuredMeanLabel => formatGrams(measuredMeanMg);
  String get declaredLabel => formatGrams(declaredUnitMassMg);

  factory SkuMassAuditModel.fromJson(
    Map<String, dynamic> json, {
    required String id,
  }) {
    return SkuMassAuditModel(
      id: id,
      skuId: _string(json['skuId']),
      orgId: _string(json['orgId']),
      sampleSize: _int(json['sampleSize']) ?? 0,
      measuredMeanMg: _int(json['measuredMeanMg']) ??
          milligramsFromGrams(json['measuredMeanG']) ??
          0,
      measuredStdDevMg: _int(json['measuredStdDevMg']),
      declaredUnitMassMg: _int(json['declaredUnitMassMg']) ??
          milligramsFromGrams(json['declaredUnitMassG']) ??
          0,
      // Fail closed: an unrecognised verdict is treated as outside tolerance,
      // which adopts the measured mean rather than the producer's declaration.
      // The conservative direction is the one that does not take a producer's
      // figure on trust.
      verdict: MassAuditVerdict.all.contains(_string(json['verdict']))
          ? _string(json['verdict'])
          : MassAuditVerdict.outsideTolerance,
      weighingLocation: _string(json['weighingLocation']),
      operatorUid: _string(json['operatorUid']),
      scalePhotoUrl: _nullableString(json['scalePhotoUrl']),
      resultingAction: _string(json['resultingAction']),
      toleranceFraction: _double(json['toleranceFraction']),
      createdAt: _date(json['createdAt']),
    );
  }
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

double? _double(Object? value) {
  if (value is num && value.isFinite) return value.toDouble();
  return null;
}

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
