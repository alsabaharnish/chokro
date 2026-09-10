/// Chokro — the denominator (EPR-24, §5.1, §6.5).
///
/// Plain Dart, no Firebase imports (§5.1).
library;

import '../core/epr_categories.dart';
import '../core/epr_period.dart';
import '../core/mass_math.dart';

/// Where a declaration is in its lifecycle.
///
/// Stored strings, never renamed (QA-6).
class DeclarationStatus {
  const DeclarationStatus._();

  /// Being written by the producer. Not yet a figure anything may use.
  static const String draft = 'draft';

  /// Attested and locked. **The only status whose figures may be a
  /// denominator.**
  static const String submitted = 'submitted';

  /// A correction has taken over. Kept, not deleted — a passport issued against
  /// it is marked superseded rather than becoming unexplainable (EPR-30).
  static const String superseded = 'superseded';

  static const List<String> all = <String>[draft, submitted, superseded];

  static String label(String value) => switch (value) {
    draft => 'Draft',
    submitted => 'Filed',
    superseded => 'Superseded by a correction',
    _ => value,
  };
}

/// One gazette category's put-on-market figures for a period.
class PutOnMarketLine {
  const PutOnMarketLine({
    required this.category,
    required this.units,
    required this.massMg,
  });

  final String category;

  /// How many units the producer placed on the market.
  final int units;

  /// Their total mass, in integer milligrams (EPR-20).
  ///
  /// The denominator of a percentage a regulator reads, so it is held to the
  /// same arithmetic discipline as the numerator — no floats anywhere in the
  /// chain.
  final int massMg;

  String get massLabel => formatKilograms(massMg);

  /// Null when the row is unusable: an unrecognised category, an unreadable
  /// figure, a negative one. Null rather than a partial row, because a category
  /// this build does not recognise cannot be a denominator for anything.
  static PutOnMarketLine? tryParse(Object? raw) {
    if (raw is! Map) return null;

    final category = raw['category'];
    if (category is! String || !GazetteCategory.isValid(category)) return null;

    final units = _int(raw['units']);
    final massMg = _int(raw['massMg']) ?? milligramsFromGrams(raw['massG']);

    if (units == null || units < 0) return null;
    if (massMg == null || massMg < 0) return null;

    // A category with mass and no units, or units and no mass, is a
    // half-entered row rather than a figure. Both zero is a legitimate "we
    // placed none of this on the market", which is why it is not refused.
    if ((units == 0) != (massMg == 0)) return null;

    return PutOnMarketLine(category: category, units: units, massMg: massMg);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'category': category,
    'units': units,
    'massMg': massMg,
    // The gram figure travels alongside for a human reading the document in
    // the console. The milligram value is authoritative.
    'massG': massMg / mgPerGram,
  };
}

/// A producer's attested statement of what it placed on the market in a period.
///
/// ## Why this collection exists at all
///
/// The gazette's targets are percentages of what a producer placed on the
/// market. Chokro can measure the numerator — it photographs, geofences and
/// screens the collection — and it cannot measure the denominator, because only
/// the producer knows how many bottles it shipped.
///
/// So the denominator is *declared*, and the whole design of this object is
/// about making a declared figure carry its own weight of evidence:
///
/// **It is attested.** A named person, a date, and explicit text stating that
/// false information is an offence under the guidelines. Chokro is not
/// vouching for the number; the producer is, on the record.
///
/// **It locks on submission.** A denominator that could be edited after a
/// percentage had been reported is not a denominator, it is a dial.
///
/// **A correction supersedes rather than overwrites.** Both versions are
/// retained, and any passport issued against the superseded one is marked
/// superseded (EPR-30). Understating put-on-market is one of the two attacks
/// §6.2 names — it shrinks the denominator and flatters the percentage — and a
/// retained version history is what makes the variance review in EPR-43
/// possible at all.
class PutOnMarketDeclaration {
  const PutOnMarketDeclaration({
    required this.id,
    required this.orgId,
    required this.periodId,
    required this.status,
    this.lines = const <PutOnMarketLine>[],
    this.version = 1,
    this.attestedByName = '',
    this.attestedByUid = '',
    this.attestedAt,
    this.attestationText = '',
    this.note,
    this.supersededBy,
    this.supersededAt,
    this.createdAt,
    this.updatedAt,
  });

  final String id;
  final String orgId;

  /// `YYYY-MM`, Asia/Dhaka. The same period vocabulary the rollups use, so a
  /// numerator and a denominator can only ever be compared within one month.
  final String periodId;

  final String status;

  /// One line per gazette category the producer placed anything in.
  ///
  /// A category absent from this list is not zero — it is *undeclared*, and the
  /// two are different. [massMgFor] returns null for an undeclared category
  /// rather than zero, so a percentage cannot be computed against a denominator
  /// nobody stated.
  final List<PutOnMarketLine> lines;

  /// Monotonic. Version 1 is the first filing; a correction opens version 2.
  final int version;

  /// The person who attested, by name and by uid.
  ///
  /// Both, because the name is what appears on a report a regulator reads and
  /// the uid is what the audit trail needs. A name alone could be typed by
  /// anyone; a uid alone means nothing on paper.
  final String attestedByName;
  final String attestedByUid;
  final DateTime? attestedAt;

  /// The exact words attested to, stored with the declaration.
  ///
  /// Stored rather than rendered from a constant at read time: if Chokro later
  /// revises its attestation wording, a filing made under the old wording must
  /// still show what its signatory actually agreed to.
  final String attestationText;

  /// The producer's own explanation, where it offers one.
  ///
  /// Worth its own field because EPR-43 makes a large period-over-period
  /// variance a review item — "a declaration that moves 60% against the
  /// previous period without a note is either a business change or a
  /// manipulation and either way an Admin should see it". A note is how a
  /// producer answers that before being asked.
  final String? note;

  final String? supersededBy;
  final DateTime? supersededAt;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  /// Whether this declaration's figures may be used as a denominator.
  ///
  /// The single accessor for that question, so no screen and no report can
  /// reach for a draft's figures by accident. A superseded declaration is not
  /// usable either: its successor is the current statement, and using the old
  /// one would report a percentage against a figure the producer has withdrawn.
  bool get isUsable => status == DeclarationStatus.submitted;

  bool get isDraft => status == DeclarationStatus.draft;

  bool get isSuperseded => status == DeclarationStatus.superseded;

  String get label => periodLabel(periodId);

  /// The declared mass for one category, or null if it was not declared.
  ///
  /// NULL IS NOT ZERO, and the difference decides whether a percentage exists.
  /// A producer that declared nothing for `flexible` has not said it placed no
  /// flexible plastic on the market; it has said nothing. Treating that as zero
  /// would produce a division by zero at best and an infinite collection rate
  /// at worst.
  int? massMgFor(String category) {
    if (!isUsable) return null;
    for (final line in lines) {
      if (line.category == category) return line.massMg;
    }
    return null;
  }

  int? unitsFor(String category) {
    if (!isUsable) return null;
    for (final line in lines) {
      if (line.category == category) return line.units;
    }
    return null;
  }

  /// Total declared mass across every declared category.
  ///
  /// Null when the declaration is not usable, so a caller cannot accidentally
  /// divide by a draft.
  int? get totalMassMg {
    if (!isUsable) return null;
    return sumMilligrams(lines.map((l) => l.massMg)).totalMg;
  }

  int? get totalUnits {
    if (!isUsable) return null;
    return lines.fold<int>(0, (sum, line) => sum + line.units);
  }

  /// Which gazette categories this declaration actually speaks to.
  List<String> get declaredCategories => [
    for (final category in GazetteCategory.all)
      if (lines.any((l) => l.category == category)) category,
  ];

  /// Lines in gazette order, so two periods' declarations are comparable.
  List<PutOnMarketLine> get orderedLines => [
    for (final category in GazetteCategory.all)
      ...lines.where((l) => l.category == category),
  ];

  /// Everything EPR-24 requires before this may be attested and locked.
  ///
  /// Every problem at once, not the first.
  List<String> get submissionProblems {
    final problems = <String>[];

    if (!isValidPeriodId(periodId)) {
      problems.add('Choose the period this declaration covers.');
    }
    if (lines.isEmpty) {
      problems.add(
        'Declare at least one gazette category, even if the figure is nil.',
      );
    }

    final seen = <String>{};
    for (final line in lines) {
      if (!seen.add(line.category)) {
        problems.add(
          'There are two lines for ${GazetteCategory.label(line.category)}. '
          'Combine them.',
        );
      }
    }

    if (attestedByName.trim().length < 2) {
      problems.add('The person attesting must be named.');
    }

    return problems;
  }

  bool get canSubmit => submissionProblems.isEmpty;

  /// The composite document id: `{orgId}_{periodId}`.
  ///
  /// One declaration per organisation per period, so a correction supersedes
  /// rather than sitting alongside — which is what stops two live denominators
  /// existing for one month.
  static String documentId(String orgId, String periodId) =>
      '${orgId}_$periodId';

  factory PutOnMarketDeclaration.fromJson(
    Map<String, dynamic> json, {
    String? id,
  }) {
    final storedPeriod = _string(json['periodId']);

    return PutOnMarketDeclaration(
      id: id ?? '',
      orgId: _string(json['orgId']),
      periodId: isValidPeriodId(storedPeriod) ? storedPeriod : '',
      // The critical fail-closed parse in this file. An unrecognised status
      // must not read as `submitted`, because `isUsable` gates on exactly that
      // value and a permissive fallback would make an unattested figure the
      // denominator of a regulatory percentage.
      status: DeclarationStatus.all.contains(_string(json['status']))
          ? _string(json['status'])
          : DeclarationStatus.draft,
      lines: _lines(json['lines']),
      version: _int(json['version']) ?? 1,
      attestedByName: _string(json['attestedByName']),
      attestedByUid: _string(json['attestedByUid']),
      attestedAt: _date(json['attestedAt']),
      attestationText: _string(json['attestationText']),
      note: _nullableString(json['note']),
      supersededBy: _nullableString(json['supersededBy']),
      supersededAt: _date(json['supersededAt']),
      createdAt: _date(json['createdAt']),
      updatedAt: _date(json['updatedAt']),
    );
  }

  /// The client-writable draft, and nothing else.
  ///
  /// Every field that makes a declaration *binding* is absent: `status`,
  /// `version`, `attestedAt`, `attestationText`, `supersededBy`,
  /// `supersededAt`, `createdAt`. Submission is a server operation, so the
  /// attestation is recorded by the party that witnessed it rather than
  /// asserted by the party making it.
  Map<String, dynamic> toDraftJson() => <String, dynamic>{
    'orgId': orgId,
    'periodId': periodId,
    'lines': orderedLines.map((l) => l.toJson()).toList(),
    'attestedByName': attestedByName.trim(),
    if (note != null) 'note': note,
  };

  PutOnMarketDeclaration copyWith({
    String? periodId,
    List<PutOnMarketLine>? lines,
    String? attestedByName,
    String? note,
    bool clearNote = false,
  }) => PutOnMarketDeclaration(
    id: id,
    orgId: orgId,
    periodId: periodId ?? this.periodId,
    // Server-owned, carried through unchanged. There is no parameter for any of
    // them, so a client cannot reach one through this method either.
    status: status,
    lines: lines ?? this.lines,
    version: version,
    attestedByName: attestedByName ?? this.attestedByName,
    attestedByUid: attestedByUid,
    attestedAt: attestedAt,
    attestationText: attestationText,
    note: clearNote ? null : (note ?? this.note),
    supersededBy: supersededBy,
    supersededAt: supersededAt,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}

/// The words a producer attests to (EPR-24).
///
/// Held here so one wording is used everywhere, and *copied onto* each
/// declaration at submission so a past filing keeps the wording its signatory
/// actually agreed to.
///
/// It names the offence rather than gesturing at it. An attestation that said
/// only "I confirm this is accurate" would not put the signatory on notice of
/// anything, and the gazette's enforcement clause — suspension, cancellation,
/// legal action — is the reason the declaration is worth having.
const String putOnMarketAttestation =
    'I confirm that the figures above are a true and complete statement of the '
    'plastic my company placed on the Bangladesh market in this period, to the '
    'best of my knowledge and from my company’s own records. I understand that '
    'providing false information under the Guidelines for Extended Producer '
    'Responsibility Implementation for Plastics may result in suspension or '
    'cancellation of my company’s registration and in legal action, and that '
    'the Department of Environment may audit and verify this data.';

List<PutOnMarketLine> _lines(Object? value) {
  if (value is! List) return const <PutOnMarketLine>[];
  return value
      .map(PutOnMarketLine.tryParse)
      .whereType<PutOnMarketLine>()
      // Five gazette categories, so a longer list is malformed rather than
      // detailed.
      .take(GazetteCategory.all.length)
      .toList(growable: false);
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

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
