/// The Admin oversight surfaces, as the client reads them (EPR-44 to EPR-48).
///
/// ## Why these are models rather than raw maps
///
/// Every figure on these screens is Chokro checking its own work, and several
/// of them are figures a regulator will eventually be shown. A screen reading
/// `json['precision']` directly would render `null` as blank, and blank on an
/// accuracy panel reads as zero — which would be Chokro publishing "our
/// recognition is never right" because a sample was too small.
///
/// So each model makes the ABSENCE explicit and carries the server's stated
/// reason for it. The server already refuses to invent these figures; this is
/// the client half of that discipline.
library;

import '../core/epr_categories.dart';

// ---------------------------------------------------------------------------
// The anomaly queue (EPR-45)
// ---------------------------------------------------------------------------

class AnomalySeverity {
  const AnomalySeverity._();

  static const String low = 'low';
  static const String medium = 'medium';
  static const String high = 'high';

  static const List<String> all = <String>[high, medium, low];

  /// Ordered worst-first, which is the order a queue is worked in.
  static int rank(String value) {
    final index = all.indexOf(value);
    // An unrecognised severity sorts to the TOP, not the bottom. A future
    // detector Chokro adds should surface loudly rather than settle quietly at
    // the end of a list nobody scrolls.
    return index < 0 ? -1 : index;
  }

  static String label(String value) => switch (value) {
    high => 'High',
    medium => 'Medium',
    low => 'Low',
    _ => 'Unrecognised',
  };
}

class AnomalyStatus {
  const AnomalyStatus._();

  static const String open = 'open';

  /// Looked at, and it had an innocent explanation.
  static const String dismissed = 'dismissed';

  /// Looked at, it was real, and something was done.
  static const String actioned = 'actioned';

  static const List<String> all = <String>[open, dismissed, actioned];

  static String label(String value) => switch (value) {
    open => 'Open',
    dismissed => 'Dismissed',
    actioned => 'Actioned',
    _ => 'Unknown',
  };
}

/// One finding in the anomaly queue.
class AnomalyFinding {
  const AnomalyFinding({
    required this.id,
    required this.orgId,
    required this.periodId,
    required this.type,
    required this.subjectType,
    required this.subjectId,
    required this.severity,
    required this.status,
    required this.summary,
    required this.figures,
    this.dismissedReason,
    this.dismissedBy,
    this.firstSeenAt,
    this.lastSeenAt,
  });

  final String id;
  final String orgId;
  final String periodId;

  /// Which detector raised it: `skuMassSpike`, `binConcentration`,
  /// `accountConcentration`, `confidenceDrift`, `unitMassOutlier`, `targetEdge`.
  final String type;

  /// `sku`, `bin`, `account` or `period`.
  final String subjectType;
  final String subjectId;

  final String severity;
  final String status;

  /// The server's sentence, which leads with the INNOCENT explanation.
  ///
  /// Rendered verbatim rather than re-worded on the client. An Admin who reads
  /// every finding as an accusation will either escalate everything or stop
  /// reading, and the server wrote these sentences to prevent that.
  final String summary;

  /// The numbers that triggered it, including the threshold in force at the
  /// time — so a finding read six months later is judged against the policy of
  /// its own moment rather than today's.
  final Map<String, Object?> figures;

  final String? dismissedReason;
  final String? dismissedBy;
  final DateTime? firstSeenAt;
  final DateTime? lastSeenAt;

  bool get isOpen => status == AnomalyStatus.open;

  /// Whether this finding names an individual person.
  ///
  /// `accountConcentration` carries a Champion's uid. Nothing about it may be
  /// shown to a producer, and even in the Admin console it is worth marking —
  /// an Admin sharing a screenshot of the queue should know which row carries
  /// somebody's identity (SEC-3).
  bool get namesAPerson => subjectType == 'account';

  factory AnomalyFinding.fromJson(Map<String, dynamic> json) {
    return AnomalyFinding(
      id: _string(json['id']),
      orgId: _string(json['orgId']),
      periodId: _string(json['periodId']),
      type: _string(json['type']),
      subjectType: _string(json['subjectType']),
      subjectId: _string(json['subjectId']),
      // An unrecognised severity is kept verbatim rather than coerced to
      // `low`: coercion would hide a future detector at the bottom of the
      // queue, and `AnomalySeverity.rank` deliberately sorts the unknown first.
      severity: _string(json['severity']),
      status: AnomalyStatus.all.contains(json['status'])
          ? json['status'] as String
          : 'unknown',
      summary: _string(json['summary']),
      figures: json['figures'] is Map
          ? Map<String, Object?>.from(json['figures'] as Map)
          : const <String, Object?>{},
      dismissedReason: _stringOrNull(json['dismissedReason']),
      dismissedBy: _stringOrNull(json['dismissedBy']),
      firstSeenAt: _date(json['firstSeenAt']),
      lastSeenAt: _date(json['lastSeenAt']),
    );
  }
}

// ---------------------------------------------------------------------------
// Reconciliation (EPR-48, QA-3)
// ---------------------------------------------------------------------------

/// One period's reconciliation state.
class ReconciliationRow {
  const ReconciliationRow({
    required this.orgId,
    required this.periodId,
    required this.incrementedMassMg,
    this.recomputedMassMg,
    this.variance,
    this.matched,
    this.recomputedAt,
    this.attributionCount = 0,
  });

  final String orgId;
  final String periodId;

  /// What the counters say, incremented as each attribution committed.
  final int incrementedMassMg;

  /// What a recompute from the raw rows says. NULL when nobody has checked.
  final int? recomputedMassMg;

  /// Null when unchecked — never zero.
  ///
  /// Zero means "checked and agreed". Conflating the two is how an entirely
  /// unverified year looks clean, which is the single most misleading thing
  /// this screen could do.
  final int? variance;

  final bool? matched;
  final DateTime? recomputedAt;
  final int attributionCount;

  bool get isChecked => recomputedAt != null;
  bool get isMismatched => matched == false;

  factory ReconciliationRow.fromJson(Map<String, dynamic> json) {
    return ReconciliationRow(
      orgId: _string(json['orgId']),
      periodId: _string(json['periodId']),
      incrementedMassMg: _int(json['incrementedMassMg']),
      recomputedMassMg: _intOrNull(json['recomputedMassMg']),
      variance: _intOrNull(json['variance']),
      matched: json['matched'] is bool ? json['matched'] as bool : null,
      recomputedAt: _date(json['recomputedAt']),
      attributionCount: _int(json['attributionCount']),
    );
  }
}

/// The reconciliation overview across every producer.
class ReconciliationOverview {
  const ReconciliationOverview({
    required this.periodsExamined,
    required this.reconciled,
    required this.mismatched,
    required this.uncheckedCount,
    required this.unchecked,
    required this.uncheckedMassMg,
  });

  final int periodsExamined;
  final int reconciled;
  final List<ReconciliationRow> mismatched;

  /// The TOTAL never-checked count, which may exceed [unchecked].
  ///
  /// "How much of this has anyone verified?" is the question an auditor asks,
  /// and it cannot be read off a bounded list. The server sends the count and
  /// the mass as totals for exactly that reason, and the screen shows them
  /// rather than `unchecked.length`.
  final int uncheckedCount;
  final List<ReconciliationRow> unchecked;
  final int uncheckedMassMg;

  bool get uncheckedListIsTruncated => uncheckedCount > unchecked.length;

  /// The share of examined periods nobody has verified.
  ///
  /// Null rather than zero when there is nothing to divide by — a platform
  /// with no periods has not achieved 100% coverage.
  double? get uncheckedShare =>
      periodsExamined > 0 ? uncheckedCount / periodsExamined : null;

  factory ReconciliationOverview.fromJson(Map<String, dynamic> json) {
    return ReconciliationOverview(
      periodsExamined: _int(json['periodsExamined']),
      reconciled: _int(json['reconciled']),
      mismatched: _rows(json['mismatched']),
      uncheckedCount: _int(json['uncheckedCount']),
      unchecked: _rows(json['unchecked']),
      uncheckedMassMg: _int(json['uncheckedMassMg']),
    );
  }

  static List<ReconciliationRow> _rows(Object? value) => value is List
      ? value
            .whereType<Map<String, dynamic>>()
            .map(ReconciliationRow.fromJson)
            .toList(growable: false)
      : const <ReconciliationRow>[];
}

// ---------------------------------------------------------------------------
// The accuracy audit (EPR-17)
// ---------------------------------------------------------------------------

class AccuracyVerdict {
  const AccuracyVerdict._();

  static const String correct = 'correct';
  static const String incorrect = 'incorrect';

  /// The photograph could not be judged. A real outcome, and kept out of the
  /// precision ratio so a reviewer's generosity does not bias the figure.
  static const String unclear = 'unclear';

  static const List<String> all = <String>[correct, incorrect, unclear];

  static String label(String value) => switch (value) {
    correct => 'Correct',
    incorrect => 'Incorrect',
    unclear => 'Cannot tell',
    _ => 'Unknown',
  };
}

/// One sampled match awaiting review.
class SampledMatch {
  const SampledMatch({
    required this.id,
    required this.orgId,
    required this.periodId,
    required this.skuId,
    required this.confidenceTier,
    required this.reason,
    this.disposalId,
    this.units,
    this.confidence,
    this.createdAt,
  });

  final String id;
  final String orgId;
  final String periodId;
  final String skuId;
  final String confidenceTier;

  /// `accuracyAudit` — attributed automatically and sampled anyway — or
  /// `lowConfidence`, which was never attributed at all.
  ///
  /// The distinction decides what a verdict MEANS, so it is never collapsed:
  /// confirming a low-confidence match describes a near-miss, not the precision
  /// of what Chokro reported.
  final String reason;

  final String? disposalId;
  final int? units;
  final double? confidence;
  final DateTime? createdAt;

  bool get isStandingAudit => reason == 'accuracyAudit';

  factory SampledMatch.fromJson(Map<String, dynamic> json) {
    return SampledMatch(
      id: _string(json['id']),
      orgId: _string(json['orgId']),
      periodId: _string(json['periodId']),
      skuId: _string(json['skuId']),
      confidenceTier: _string(json['confidenceTier']),
      reason: _string(json['reason']),
      disposalId: _stringOrNull(json['disposalId']),
      units: _intOrNull(json['units']),
      confidence: _doubleOrNull(json['confidence']),
      createdAt: _date(json['createdAt']),
    );
  }
}

/// The measured precision of recognition, or the stated reason there is none.
class AccuracySnapshot {
  const AccuracySnapshot({
    required this.reviewed,
    required this.judged,
    required this.correct,
    required this.incorrect,
    required this.unclear,
    required this.minSample,
    required this.windowPeriods,
    required this.trend,
    this.precision,
    this.precisionAbsenceReason,
    this.unclearShare,
    this.recallAbsenceReason,
  });

  final int reviewed;

  /// Reviewed with a clear verdict — the denominator of [precision].
  final int judged;

  final int correct;
  final int incorrect;
  final int unclear;
  final int minSample;
  final List<String> windowPeriods;
  final List<AccuracyTrendPoint> trend;

  /// Null below the sample floor, and the screen states [precisionAbsenceReason]
  /// instead.
  ///
  /// "100% over three reviewed matches" is not a measurement. This figure is
  /// published in report methodology, which is the section a reader turns to in
  /// order to decide how much to trust everything else.
  final double? precision;
  final String? precisionAbsenceReason;

  /// The share of the sample nobody could judge. A high figure says the
  /// PHOTOGRAPHS are the problem rather than the model, which is a different
  /// fix — so it is shown rather than folded away.
  final double? unclearShare;

  /// Recall is never stated. EPR-17 names it, and the sample is drawn from what
  /// the model claimed — so nothing here knows what the model missed.
  final String? recallAbsenceReason;

  bool get hasPrecision => precision != null;

  factory AccuracySnapshot.fromJson(Map<String, dynamic> json) {
    return AccuracySnapshot(
      reviewed: _int(json['reviewed']),
      judged: _int(json['judged']),
      correct: _int(json['correct']),
      incorrect: _int(json['incorrect']),
      unclear: _int(json['unclear']),
      minSample: _int(json['minSample']),
      windowPeriods: json['windowPeriods'] is List
          ? (json['windowPeriods'] as List).whereType<String>().toList()
          : const <String>[],
      trend: json['trend'] is List
          ? (json['trend'] as List)
                .whereType<Map<String, dynamic>>()
                .map(AccuracyTrendPoint.fromJson)
                .toList(growable: false)
          : const <AccuracyTrendPoint>[],
      precision: _doubleOrNull(json['precision']),
      precisionAbsenceReason: _stringOrNull(json['precisionAbsenceReason']),
      unclearShare: _doubleOrNull(json['unclearShare']),
      recallAbsenceReason: _stringOrNull(json['recallAbsenceReason']),
    );
  }
}

class AccuracyTrendPoint {
  const AccuracyTrendPoint({
    required this.periodId,
    required this.reviewed,
    required this.judged,
    this.precision,
  });

  final String periodId;
  final int reviewed;
  final int judged;

  /// Reported without the sample floor, because a trend is read as a shape —
  /// but [judged] sits beside it so a spike on two reviews is visible for what
  /// it is.
  final double? precision;

  factory AccuracyTrendPoint.fromJson(Map<String, dynamic> json) {
    return AccuracyTrendPoint(
      periodId: _string(json['periodId']),
      reviewed: _int(json['reviewed']),
      judged: _int(json['judged']),
      precision: _doubleOrNull(json['precision']),
    );
  }
}

// ---------------------------------------------------------------------------
// The issuance register (EPR-47)
// ---------------------------------------------------------------------------

/// One certificate in the register, across every producer.
class IssuedCertificate {
  const IssuedCertificate({
    required this.serial,
    required this.orgId,
    required this.tradeName,
    required this.periodId,
    required this.status,
    required this.contentHash,
    required this.collectedMassMg,
    this.collectionRate,
    this.issuedAt,
    this.issuedByName,
    this.supersededBy,
    this.supersededReason,
    this.revocationReason,
  });

  final String serial;
  final String orgId;

  /// The name the CERTIFICATE carries, off its frozen snapshot — not a live
  /// read. A producer that has since rebranded would make a live read disagree
  /// with the document a third party is holding.
  final String tradeName;

  final String periodId;
  final String status;
  final String contentHash;
  final int collectedMassMg;

  /// Null when no declaration was filed for the period (EPR-24). Never zero.
  final double? collectionRate;

  final DateTime? issuedAt;
  final String? issuedByName;
  final String? supersededBy;
  final String? supersededReason;
  final String? revocationReason;

  bool get isStanding => status == 'issued';

  String? get withdrawalReason => switch (status) {
    'revoked' => revocationReason,
    'superseded' => supersededReason,
    _ => null,
  };

  factory IssuedCertificate.fromJson(Map<String, dynamic> json) {
    return IssuedCertificate(
      serial: _string(json['serial']),
      orgId: _string(json['orgId']),
      tradeName: _string(json['tradeName']),
      periodId: _string(json['periodId']),
      status: _string(json['status']),
      contentHash: _string(json['contentHash']),
      collectedMassMg: _int(json['collectedMassMg']),
      collectionRate: _doubleOrNull(json['collectionRate']),
      issuedAt: _date(json['issuedAt']),
      issuedByName: _stringOrNull(json['issuedByName']),
      supersededBy: _stringOrNull(json['supersededBy']),
      supersededReason: _stringOrNull(json['supersededReason']),
      revocationReason: _stringOrNull(json['revocationReason']),
    );
  }
}

class IssuanceRegister {
  const IssuanceRegister({
    required this.certificates,
    required this.issued,
    required this.superseded,
    required this.revoked,
    required this.truncated,
  });

  final List<IssuedCertificate> certificates;
  final int issued;
  final int superseded;
  final int revoked;

  /// Whether the register stopped short of the whole set.
  ///
  /// Shown on the screen. A register that silently truncated would be the worst
  /// possible answer to "which certificates are affected by this fault".
  final bool truncated;

  factory IssuanceRegister.fromJson(Map<String, dynamic> json) {
    final counts = json['counts'] is Map
        ? Map<String, dynamic>.from(json['counts'] as Map)
        : const <String, dynamic>{};

    return IssuanceRegister(
      certificates: json['passports'] is List
          ? (json['passports'] as List)
                .whereType<Map<String, dynamic>>()
                .map(IssuedCertificate.fromJson)
                .toList(growable: false)
          : const <IssuedCertificate>[],
      issued: _int(counts['issued']),
      superseded: _int(counts['superseded']),
      revoked: _int(counts['revoked']),
      truncated: json['truncated'] == true,
    );
  }
}

// ---------------------------------------------------------------------------
// The activity timeline (EPR-44, SEC-12)
// ---------------------------------------------------------------------------

class TimelineEntry {
  const TimelineEntry({
    required this.sequence,
    required this.action,
    required this.actorUid,
    required this.actorName,
    required this.actorRole,
    required this.summary,
    this.timestamp,
    this.targetType,
    this.targetId,
  });

  /// The hashed monotonic counter, which is what the timeline is ordered by.
  ///
  /// `sequence` is inside the chain digest and the timestamp is not, so
  /// ordering by the clock would let an insider reorder the visible history
  /// without breaking the chain.
  final int sequence;

  final String action;
  final String actorUid;
  final String actorName;
  final String actorRole;
  final String summary;
  final DateTime? timestamp;
  final String? targetType;
  final String? targetId;

  /// Whether Chokro took this action rather than the producer.
  ///
  /// The distinction EPR-46 exists to preserve: an audit trail that cannot tell
  /// the two apart is not an audit trail.
  bool get byChokro => actorRole == 'admin';

  factory TimelineEntry.fromJson(Map<String, dynamic> json) {
    return TimelineEntry(
      sequence: _int(json['sequence']),
      action: _string(json['action']),
      actorUid: _string(json['actorUid']),
      actorName: _string(json['actorName']),
      actorRole: _string(json['actorRole']),
      summary: _string(json['summary']),
      timestamp: _date(json['timestamp']),
      targetType: _stringOrNull(json['targetType']),
      targetId: _stringOrNull(json['targetId']),
    );
  }
}

class ActivityTimeline {
  const ActivityTimeline({
    required this.orgId,
    required this.entries,
    this.verified,
    this.keyed = false,
    this.verificationCaveat,
  });

  final String orgId;
  final List<TimelineEntry> entries;

  /// Null when the chain was not checked — never false.
  ///
  /// "Not checked" and "checked and failed" are different statements, and a
  /// screen that conflated them would either alarm nobody or alarm everybody.
  final bool? verified;

  /// Whether the chain is an HMAC under an operator-held key, or a bare hash
  /// anyone with read access could recompute.
  ///
  /// Shown beside the verification result. An unkeyed chain is tamper-evident
  /// against anything WITHOUT write access and is not evidence against an
  /// insider holding the database credential — printing "intact" without
  /// saying which would overstate the control (SEC-12).
  final bool keyed;

  final String? verificationCaveat;

  factory ActivityTimeline.fromJson(Map<String, dynamic> json) {
    return ActivityTimeline(
      orgId: _string(json['orgId']),
      entries: json['entries'] is List
          ? (json['entries'] as List)
                .whereType<Map<String, dynamic>>()
                .map(TimelineEntry.fromJson)
                .toList(growable: false)
          : const <TimelineEntry>[],
      verified: json['verified'] is bool ? json['verified'] as bool : null,
      keyed: json['keyed'] == true,
      verificationCaveat: _stringOrNull(json['verificationCaveat']),
    );
  }
}

// ---------------------------------------------------------------------------
// The declaration review queue (EPR-43)
// ---------------------------------------------------------------------------

/// A filed declaration, with the variance that may have flagged it.
class DeclarationReviewRow {
  const DeclarationReviewRow({
    required this.orgId,
    required this.periodId,
    required this.version,
    required this.totalMassMg,
    required this.attestedByName,
    required this.flagged,
    required this.flagReasons,
    required this.hasNote,
    this.previousPeriod,
    this.previousMassMg,
    this.variance,
    this.priorVersionMassMg,
    this.correctionVariance,
    this.varianceThreshold,
    this.note,
  });

  final String orgId;
  final String periodId;
  final int version;
  final int totalMassMg;
  final String attestedByName;

  /// Whether the server decided this warrants an Admin's attention.
  ///
  /// Computed server-side against the policy threshold, not re-derived here —
  /// two consoles disagreeing about what counts as flagged would be worse than
  /// neither flagging anything.
  final bool flagged;
  final List<String> flagReasons;

  /// Whether the producer explained the move. A note suppresses the flag, not
  /// the figure (EPR-43's own "without a note").
  final bool hasNote;

  final String? previousPeriod;
  final int? previousMassMg;

  /// Period-over-period change. Null on a first filing — never zero, because
  /// "nothing to compare against" is not "no change".
  final double? variance;

  final int? priorVersionMassMg;

  /// Change against the version this one superseded: a denominator withdrawn
  /// and refiled lower.
  final double? correctionVariance;

  final double? varianceThreshold;
  final String? note;

  factory DeclarationReviewRow.fromJson(Map<String, dynamic> json) {
    return DeclarationReviewRow(
      orgId: _string(json['orgId']),
      periodId: _string(json['periodId']),
      version: _int(json['version']),
      totalMassMg: _int(json['totalMassMg']),
      attestedByName: _string(json['attestedByName']),
      flagged: json['flagged'] == true,
      flagReasons: json['flagReasons'] is List
          ? (json['flagReasons'] as List).whereType<String>().toList()
          : const <String>[],
      hasNote: json['hasNote'] == true,
      previousPeriod: _stringOrNull(json['previousPeriod']),
      previousMassMg: _intOrNull(json['previousMassMg']),
      variance: _doubleOrNull(json['variance']),
      priorVersionMassMg: _intOrNull(json['priorVersionMassMg']),
      correctionVariance: _doubleOrNull(json['correctionVariance']),
      varianceThreshold: _doubleOrNull(json['varianceThreshold']),
      note: _stringOrNull(json['note']),
    );
  }
}

// ---------------------------------------------------------------------------
// View as organisation (EPR-46)
// ---------------------------------------------------------------------------

/// What a producer sees, assembled for an Admin.
///
/// Carries the server's own read-only assertions rather than inferring them, so
/// a screen cannot render this as anything but read-only without ignoring
/// something explicit.
class OrganizationView {
  const OrganizationView({
    required this.orgId,
    required this.legalName,
    required this.tradeName,
    required this.status,
    required this.periodId,
    required this.readOnly,
    required this.impersonation,
    required this.canWrite,
    required this.capabilityNote,
    required this.memberCount,
    required this.certificates,
    this.doeRegistrationNo,
    this.sizeClass,
  });

  final String orgId;
  final String legalName;
  final String tradeName;
  final String status;
  final String periodId;

  /// The server says so. Asserted rather than assumed.
  final bool readOnly;

  /// Always false, and checked. EPR-46: "no Admin action is ever taken under a
  /// producer's identity".
  final bool impersonation;

  final bool canWrite;
  final String capabilityNote;
  final int memberCount;
  final List<IssuedCertificate> certificates;
  final String? doeRegistrationNo;
  final String? sizeClass;

  /// Whether this payload is safe to render as a producer view.
  ///
  /// A screen checks this before drawing anything. If a future server change
  /// ever sent a writable payload down this route, the view refuses rather than
  /// quietly offering an Admin a write affordance under a producer's identity.
  bool get isSafeReadOnlyView => readOnly && !impersonation && !canWrite;

  factory OrganizationView.fromJson(Map<String, dynamic> json) {
    final organization = json['organization'] is Map
        ? Map<String, dynamic>.from(json['organization'] as Map)
        : const <String, dynamic>{};
    final capabilities = json['capabilities'] is Map
        ? Map<String, dynamic>.from(json['capabilities'] as Map)
        : const <String, dynamic>{};

    return OrganizationView(
      orgId: _string(organization['orgId']),
      legalName: _string(organization['legalName']),
      tradeName: _string(organization['tradeName']),
      status: _string(organization['status']),
      periodId: _string(json['periodId']),
      readOnly: json['readOnly'] == true,
      impersonation: json['impersonation'] == true,
      canWrite: capabilities['canWrite'] == true,
      capabilityNote: _string(capabilities['note']),
      memberCount: json['members'] is List ? (json['members'] as List).length : 0,
      certificates: json['passports'] is List
          ? (json['passports'] as List)
                .whereType<Map<String, dynamic>>()
                .map(IssuedCertificate.fromJson)
                .toList(growable: false)
          : const <IssuedCertificate>[],
      doeRegistrationNo: _stringOrNull(organization['doeRegistrationNo']),
      sizeClass: _stringOrNull(organization['sizeClass']),
    );
  }
}

/// A human label for a detector, for the queue's filter chips.
String anomalyTypeLabel(String type) => switch (type) {
  'skuMassSpike' => 'Mass spike',
  'binConcentration' => 'Bin concentration',
  'accountConcentration' => 'Account concentration',
  'confidenceDrift' => 'Recognition drift',
  'unitMassOutlier' => 'Unit mass outlier',
  'targetEdge' => 'Target cleared narrowly',
  _ => type,
};

/// A human label for a finding's subject.
String anomalySubjectLabel(String subjectType) => switch (subjectType) {
  'sku' => 'Product',
  'bin' => 'Bin',
  'account' => 'Account',
  'period' => 'Period',
  _ => subjectType,
};

/// A gazette category label, so the console and the portal agree.
String categoryLabel(String category) => GazetteCategory.label(category);

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

String _string(Object? value) => value is String ? value : '';

String? _stringOrNull(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

int _int(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.round();
  return 0;
}

int? _intOrNull(Object? value) {
  if (value is int) return value;
  if (value is num && value.isFinite) return value.round();
  return null;
}

double? _doubleOrNull(Object? value) {
  if (value is num && value.isFinite) return value.toDouble();
  return null;
}

/// A timestamp from an ISO string or a Firestore-shaped map.
DateTime? _date(Object? value) {
  if (value is String) return DateTime.tryParse(value);
  if (value is Map && value['_seconds'] is num) {
    return DateTime.fromMillisecondsSinceEpoch(
      (value['_seconds'] as num).toInt() * 1000,
      isUtc: true,
    );
  }
  return null;
}
