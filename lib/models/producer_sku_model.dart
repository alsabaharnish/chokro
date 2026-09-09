/// Chokro — the product registry (EPR-9, EPR-11, EPR-12, §5.1).
///
/// Plain Dart, no Firebase imports (§5.1).
library;

import '../core/epr_categories.dart';
import '../core/mass_math.dart';

/// Where a declared mass is in the verification chain (EPR-11).
///
/// Stored strings, never renamed (QA-6).
class MassStatus {
  const MassStatus._();

  /// Being written. Not yet offered to Chokro.
  static const String draft = 'draft';

  /// Offered for verification, waiting in the Admin queue (EPR-42).
  static const String submitted = 'submitted';

  /// Chokro has established a `verifiedUnitMassG`. **This is the only status
  /// whose mass may be used for reporting.**
  static const String verified = 'verified';

  static const String rejected = 'rejected';

  /// A later revision has taken over. The document is kept: a report issued
  /// last quarter must remain reproducible after this quarter's re-weighing
  /// (EPR-12).
  static const String superseded = 'superseded';

  static const List<String> all = <String>[
    draft,
    submitted,
    verified,
    rejected,
    superseded,
  ];

  static String label(String value) => switch (value) {
    draft => 'Draft',
    submitted => 'Awaiting Chokro verification',
    verified => 'Verified by Chokro',
    rejected => 'Rejected',
    superseded => 'Superseded',
    _ => value,
  };
}

/// The SKU's own lifecycle, distinct from its mass status.
///
/// Two axes because they move independently: a product can be `active` in a
/// producer's catalogue while its *mass* is `submitted` and therefore unusable
/// for reporting. Collapsing them into one field is how an unverified mass ends
/// up in a figure.
class SkuStatus {
  const SkuStatus._();

  static const String draft = 'draft';
  static const String submitted = 'submitted';
  static const String active = 'active';

  /// No longer placed on the market. Never deleted — past attributions
  /// reference it, and a dangling reference breaks a period's reproducibility.
  static const String retired = 'retired';

  static const List<String> all = <String>[draft, submitted, active, retired];

  static String label(String value) => switch (value) {
    draft => 'Draft',
    submitted => 'Submitted',
    active => 'Active',
    retired => 'Retired',
    _ => value,
  };
}

/// One part of a product, with its own polymer and mass (EPR-9).
///
/// ## Why components exist at all
///
/// A 250 ml PET bottle is a PET body, an HDPE or PP cap and often a PVC or PET
/// label sleeve — three polymers and three gazette-relevant masses in one object
/// the recognition model will see as a single bottle. Reporting category totals
/// from one blended figure is wrong in a way a DoE audit would find. Declaring
/// components lets one recognised unit contribute grams to more than one polymer
/// line while remaining one unit.
class SkuComponent {
  const SkuComponent({
    required this.part,
    required this.polymer,
    required this.massMg,
  });

  /// What the part is: `body`, `cap`, `label`, `sleeve`, `liner`.
  final String part;

  /// One of [PolymerType].
  final String polymer;

  /// Integer milligrams (EPR-20). Never a double, anywhere.
  final int massMg;

  String get massLabel => formatGrams(massMg);

  /// Null when the row is unusable — an unrecognised polymer, an unreadable
  /// mass, a missing part name. Null and not a partial object, because a
  /// component with a defaulted polymer would put grams on the wrong gazette
  /// line.
  static SkuComponent? tryParse(Object? raw) {
    if (raw is! Map) return null;

    final part = raw['part'];
    final polymer = raw['polymer'];
    if (part is! String || part.trim().isEmpty || part.length > 60) return null;
    if (polymer is! String || !PolymerType.isValid(polymer)) return null;

    // Stored in milligrams; tolerant of a document that stored grams, because
    // `massGrams` is the field name §5.1 uses and a migration may have written
    // either.
    final mg = raw['massMg'] is int
        ? raw['massMg'] as int
        : milligramsFromGrams(raw['massGrams']);
    // The *component* floor, not the unit floor: a tamper ring or a foil seal
    // legitimately weighs less than 0.1 g, and rejecting it would force the
    // producer to fold those grams onto the wrong polymer line.
    if (mg == null || mg < minComponentMassMg || mg > maxUnitMassMg) return null;

    return SkuComponent(part: part.trim(), polymer: polymer, massMg: mg);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'part': part,
    'polymer': polymer,
    'massMg': massMg,
  };
}

/// A registered product.
///
/// ## The one collection with a real client write path
///
/// On the same test the codebase already applies to `products`: the governing
/// constraint is expressible where it is enforced. "The owning org's reporter,
/// in good standing, within these bounds" is something `firestore.rules` can
/// state, so the draft stays there.
///
/// What the client may **never** write is the mass that reporting uses.
/// `declaredUnitMassG` is the producer's figure — the one number in the chain it
/// has both the best knowledge of and an incentive to distort. `verifiedUnitMassG`
/// is Chokro's, set by physical sampling, documentary verification or a logged
/// Admin override (EPR-11), and it is the only one any report reads.
class ProducerSkuModel {
  const ProducerSkuModel({
    required this.id,
    required this.orgId,
    required this.name,
    required this.brand,
    required this.gazetteCategory,
    required this.polymer,
    required this.declaredUnitMassMg,
    this.gtin,
    this.volumeMl,
    this.components = const <SkuComponent>[],
    this.sampleImageUrls = const <String>[],
    this.sampleImagePublicIds = const <String>[],
    this.recognitionHints = const <String>[],
    this.massStatus = MassStatus.draft,
    this.verifiedUnitMassMg,
    this.verifiedBy,
    this.verifiedAt,
    this.activeFrom,
    this.activeTo,
    this.revision = 0,
    this.status = SkuStatus.draft,
    this.rejectionReason,
    this.createdAt,
  });

  final String id;

  /// Set on create, immutable thereafter. The tenancy key for every read.
  final String orgId;

  /// "Coca-Cola 250 ml PET bottle".
  final String name;

  /// The brand on the packaging. Compared across organisations for the
  /// collision flag EPR-14 makes blocking.
  final String brand;

  final String gazetteCategory;

  /// The product's dominant polymer. The per-part polymers are in [components],
  /// and it is those the category breakdown uses.
  final String polymer;

  /// The barcode, where one exists.
  ///
  /// Worth more than it looks: a scanned GTIN that resolves to a registered SKU
  /// is a `barcode`-method attribution at high confidence with no model
  /// involvement (EPR-18). Visual brand recognition of a crushed bottle in a
  /// dim bin at dusk is a hard problem; reading a barcode is a solved one.
  final String? gtin;

  final int? volumeMl;

  final List<SkuComponent> components;

  /// Two to six photographs against a plain background (EPR-9).
  final List<String> sampleImageUrls;

  /// The Cloudinary public ids, which prove the images live in this
  /// organisation's own folder rather than being an arbitrary remote URL — the
  /// same test `validProductImage` already applies to a seller's listing.
  final List<String> sampleImagePublicIds;

  /// Label colours, wordmark, shape. Fed to the recognition shortlist (EPR-15).
  final List<String> recognitionHints;

  /// The producer's own figure, in integer milligrams. **Never used for
  /// reporting** (EPR-11).
  final int declaredUnitMassMg;

  final String massStatus;

  /// Chokro's figure. The one reporting uses, and null until it exists.
  final int? verifiedUnitMassMg;

  final String? verifiedBy;
  final DateTime? verifiedAt;

  /// Effective dating (EPR-12). A verified mass is never edited in place: a
  /// change closes this revision with an `activeTo` and opens the next with an
  /// `activeFrom`, so last quarter's passport stays true after this quarter's
  /// re-weighing.
  final DateTime? activeFrom;
  final DateTime? activeTo;

  /// Monotonic. Every attribution stores the revision it used.
  final int revision;

  final String status;

  final String? rejectionReason;
  final DateTime? createdAt;

  /// The mass a report may use, or null.
  ///
  /// The single accessor for this question, so no screen and no report can
  /// reach for `declaredUnitMassMg` by accident. Both conditions are required:
  /// a mass is only reportable when Chokro has verified it *and* the SKU is not
  /// a superseded revision.
  int? get reportableUnitMassMg =>
      massStatus == MassStatus.verified ? verifiedUnitMassMg : null;

  bool get hasVerifiedMass => reportableUnitMassMg != null;

  bool get isAwaitingVerification => massStatus == MassStatus.submitted;

  /// Whether this revision was in force at [moment] (EPR-12).
  ///
  /// The question every attribution asks: which mass was the verified mass on
  /// the day this disposal was decided? An open-ended revision — `activeTo` null
  /// — is in force from `activeFrom` onward.
  bool wasActiveAt(DateTime moment) {
    final from = activeFrom;
    if (from == null) return false;
    if (moment.isBefore(from)) return false;

    final to = activeTo;
    return to == null || moment.isBefore(to);
  }

  /// Whether the declared component masses add up to the declared unit mass.
  ///
  /// A submission requirement (EPR-9), checked here so a form can refuse before
  /// a round trip and the server can refuse regardless.
  bool get componentsBalance => componentsSumToDeclared(
    componentMassesMg: components.map((c) => c.massMg),
    declaredUnitMassMg: declaredUnitMassMg,
  );

  /// Everything EPR-9 requires before a producer may submit this for
  /// verification, as a list of what is still missing.
  ///
  /// All of them at once rather than the first: a form that reveals one rule at
  /// a time makes somebody guess their way through the requirements.
  List<String> get submissionProblems {
    final problems = <String>[];

    if (name.trim().length < 3) problems.add('Give the product a name.');
    if (brand.trim().length < 2) problems.add('Name the brand.');
    if (!GazetteCategory.isValid(gazetteCategory)) {
      problems.add('Choose a gazette category.');
    }
    if (!PolymerType.isValid(polymer)) {
      problems.add('Choose the main polymer.');
    }
    if (sampleImageUrls.length < 2) {
      problems.add(
        'Add at least two sample photographs against a plain background.',
      );
    }
    if (sampleImageUrls.length > 6) {
      problems.add('Six sample photographs is the maximum.');
    }
    if (components.isEmpty) {
      problems.add(
        'Break the product down into its parts, each with its own polymer '
        'and mass.',
      );
    } else if (!componentsBalance) {
      final sum = sumMilligrams(components.map((c) => c.massMg));
      final difference = sum.totalMg - declaredUnitMassMg;
      // Exact, not rounded to three significant figures. Rounding both sides
      // produced "The parts add up to 10 g, but the unit mass is 10 g" for a
      // one-milligram discrepancy — an error stating that two numbers are
      // equal, with nothing for the producer to act on.
      problems.add(
        'The parts add up to ${formatGramsExact(sum.totalMg)}, '
        '${difference > 0 ? 'over' : 'under'} the '
        '${formatGramsExact(declaredUnitMassMg)} unit mass by '
        '${formatGramsExact(difference.abs())}.',
      );
    }
    if (declaredUnitMassMg < minUnitMassMg ||
        declaredUnitMassMg > maxUnitMassMg) {
      problems.add(
        'The unit mass must be between '
        '${formatGrams(minUnitMassMg)} and ${formatGrams(maxUnitMassMg)}.',
      );
    }

    return problems;
  }

  bool get canSubmit => submissionProblems.isEmpty;

  /// Mass per polymer, in integer milligrams, from the component breakdown.
  ///
  /// This is what makes one recognised unit contribute to more than one polymer
  /// line. Empty when no components are declared — deliberately empty rather
  /// than falling back to the dominant polymer, because attributing the whole
  /// unit mass to one polymer is a guess and §6.7 forbids a figure whose
  /// provenance cannot be traced field by field.
  Map<String, int> get massByPolymerMg {
    final totals = <String, int>{};
    for (final component in components) {
      totals[component.polymer] =
          (totals[component.polymer] ?? 0) + component.massMg;
    }
    return totals;
  }

  factory ProducerSkuModel.fromJson(
    Map<String, dynamic> json, {
    required String id,
  }) {
    final declaredMg = json['declaredUnitMassMg'] is int
        ? json['declaredUnitMassMg'] as int
        : milligramsFromGrams(json['declaredUnitMassG']);

    final verifiedMg = json['verifiedUnitMassMg'] is int
        ? json['verifiedUnitMassMg'] as int
        : milligramsFromGrams(json['verifiedUnitMassG']);

    return ProducerSkuModel(
      id: id,
      orgId: _string(json['orgId']),
      name: _string(json['name']),
      brand: _string(json['brand']),
      gtin: _nullableString(json['gtin']),
      volumeMl: _int(json['volumeMl']),
      // Fail closed on both enums. An unrecognised gazette category would put
      // this product's mass on a line the gazette does not have.
      gazetteCategory: GazetteCategory.isValid(_string(json['gazetteCategory']))
          ? _string(json['gazetteCategory'])
          : '',
      polymer: PolymerType.isValid(_string(json['polymer']))
          ? _string(json['polymer'])
          : '',
      declaredUnitMassMg: declaredMg ?? 0,
      components: _components(json['components']),
      // Parsed up to twelve, not six.
      //
      // Six is the *submission* limit (EPR-9), and a parser that truncated to
      // six would make the limit unenforceable: `submissionProblems` would
      // never see a seventh image, so a producer with too many photographs
      // would be told nothing and would wonder where they went. The read stays
      // bounded (QA-10) — twice the limit is still a ceiling — and the rule is
      // stated where it can be reported.
      sampleImageUrls: _strings(json['sampleImageUrls'], max: 12),
      sampleImagePublicIds: _strings(json['sampleImagePublicIds'], max: 12),
      recognitionHints: _strings(json['recognitionHints'], max: 12),
      // The critical fail-closed parse in this file. An unrecognised mass
      // status must not read as `verified`, because `reportableUnitMassMg`
      // gates on exactly that value and a permissive fallback would put an
      // unverified producer-supplied figure into a regulatory report.
      massStatus: MassStatus.all.contains(_string(json['massStatus']))
          ? _string(json['massStatus'])
          : MassStatus.draft,
      verifiedUnitMassMg: verifiedMg,
      verifiedBy: _nullableString(json['verifiedBy']),
      verifiedAt: _date(json['verifiedAt']),
      activeFrom: _date(json['activeFrom']),
      activeTo: _date(json['activeTo']),
      revision: _int(json['revision']) ?? 0,
      status: SkuStatus.all.contains(_string(json['status']))
          ? _string(json['status'])
          : SkuStatus.draft,
      rejectionReason: _nullableString(json['rejectionReason']),
      createdAt: _date(json['createdAt']),
    );
  }

  /// The client-writable draft, and nothing else.
  ///
  /// Every server-owned field is absent by construction: `massStatus`,
  /// `verifiedUnitMassMg`, `verifiedBy`, `verifiedAt`, `activeFrom`,
  /// `activeTo`, `revision`, `createdAt`. The rules reject any key beyond this
  /// allowlist, and the point is that the client never proposes one.
  ///
  /// `declaredUnitMassG` travels alongside the milligram figure because §5.1
  /// names it and a human reading the document in the Firestore console should
  /// see the number the producer typed. The milligram value is authoritative.
  Map<String, dynamic> toDraftJson() => <String, dynamic>{
    'orgId': orgId,
    'name': name.trim(),
    'brand': brand.trim(),
    if (gtin != null) 'gtin': gtin,
    if (volumeMl != null) 'volumeMl': volumeMl,
    'gazetteCategory': gazetteCategory,
    'polymer': polymer,
    'components': components.map((c) => c.toJson()).toList(),
    'declaredUnitMassMg': declaredUnitMassMg,
    'declaredUnitMassG': declaredUnitMassMg / mgPerGram,
    'sampleImageUrls': sampleImageUrls,
    'sampleImagePublicIds': sampleImagePublicIds,
    'recognitionHints': recognitionHints,
    'status': status,
  };

  ProducerSkuModel copyWith({
    String? name,
    String? brand,
    String? gtin,
    bool clearGtin = false,
    int? volumeMl,
    String? gazetteCategory,
    String? polymer,
    int? declaredUnitMassMg,
    List<SkuComponent>? components,
    List<String>? sampleImageUrls,
    List<String>? sampleImagePublicIds,
    List<String>? recognitionHints,
    String? status,
  }) => ProducerSkuModel(
    id: id,
    orgId: orgId,
    name: name ?? this.name,
    brand: brand ?? this.brand,
    gtin: clearGtin ? null : (gtin ?? this.gtin),
    volumeMl: volumeMl ?? this.volumeMl,
    gazetteCategory: gazetteCategory ?? this.gazetteCategory,
    polymer: polymer ?? this.polymer,
    declaredUnitMassMg: declaredUnitMassMg ?? this.declaredUnitMassMg,
    components: components ?? this.components,
    sampleImageUrls: sampleImageUrls ?? this.sampleImageUrls,
    sampleImagePublicIds: sampleImagePublicIds ?? this.sampleImagePublicIds,
    recognitionHints: recognitionHints ?? this.recognitionHints,
    // Server-owned fields are carried through unchanged. There is no parameter
    // for any of them, so a client cannot reach one through this method either.
    massStatus: massStatus,
    verifiedUnitMassMg: verifiedUnitMassMg,
    verifiedBy: verifiedBy,
    verifiedAt: verifiedAt,
    activeFrom: activeFrom,
    activeTo: activeTo,
    revision: revision,
    status: status ?? this.status,
    rejectionReason: rejectionReason,
    createdAt: createdAt,
  );
}

List<SkuComponent> _components(Object? value) {
  if (value is! List) return const <SkuComponent>[];
  return value
      .map(SkuComponent.tryParse)
      .whereType<SkuComponent>()
      .take(12)
      .toList(growable: false);
}

List<String> _strings(Object? value, {required int max}) {
  if (value is! List) return const <String>[];
  return value
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .take(max)
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
