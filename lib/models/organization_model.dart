/// Chokro — the obligated entity (EPR-3, §5.1).
///
/// Plain Dart, no Firebase imports (§5.1). The service layer converts Firestore
/// `Timestamp` values to [DateTime] before calling [OrganizationModel.fromJson].
library;

import '../core/constants.dart';
import '../core/epr_categories.dart';
import '../core/epr_period.dart';

/// A company obligated under the 2026 EPR guidelines, or applying to be
/// onboarded as one.
///
/// ## Almost every field here is server-owned, and that is the design
///
/// The applicant supplies its own contact details and legal name. Everything
/// that *decides* anything — the size class that fixes which gazette targets
/// apply, the obligation start date, the status that opens the workspace, the
/// verification stamp — is written by the trusted service after an Admin has
/// reviewed evidence (EPR-41). A company that could set its own `sizeClass`
/// could choose which year's targets it is measured against, and a company that
/// could set its own `status` would not need to be reviewed at all.
///
/// The fields marked *(S)* below have no client write path in `firestore.rules`,
/// Admins included, in the manner of `wallets` and `orders`.
class OrganizationModel {
  const OrganizationModel({
    required this.id,
    required this.legalName,
    required this.tradeName,
    required this.status,
    this.bin,
    this.tradeLicenceNo,
    this.doeRegistrationNo,
    this.sizeClass,
    this.obligationStartDate,
    this.complianceRoute = ComplianceRoute.self,
    this.categories = const <String>[],
    this.contactName = '',
    this.contactEmail = '',
    this.contactPhone = '',
    this.address = '',
    this.district = '',
    this.city = '',
    this.verifiedBy,
    this.verifiedAt,
    this.createdAt,
  });

  /// Firestore document id.
  final String id;

  /// The name on the trade licence. What a filing is made in.
  final String legalName;

  /// The name on the packaging. What a Champion would recognise, and therefore
  /// what brand-collision detection compares (EPR-14).
  final String tradeName;

  /// *(S)* Business Identification Number.
  final String? bin;

  /// *(S)*
  final String? tradeLicenceNo;

  /// *(S)* The Department of Environment EPR registration number, once the
  /// producer holds one.
  ///
  /// Null is the normal state for a company that has engaged Chokro *before*
  /// registering — which is most of them, since registration is due within six
  /// months of listing and the evidence takes longer than that to accumulate.
  /// Nothing may treat its absence as a compliance failure.
  final String? doeRegistrationNo;

  /// *(S)* Gazette phase-in class. See [OrgSizeClass].
  ///
  /// Null until onboarding review sets it. A null size class means the
  /// applicable target is not yet known, and no target may be displayed.
  final String? sizeClass;

  /// *(S)* When this entity's obligation began, from its size class and listing
  /// date.
  ///
  /// This is the clock that [obligationYearAt] counts from, and therefore the
  /// clock that decides whether the 15%/7.5% or the 30%/15% target applies.
  final DateTime? obligationStartDate;

  /// *(S)* Self-compliance or through a PRO. See [ComplianceRoute].
  final String complianceRoute;

  /// *(S)* Which of the five gazette categories this producer is obligated for.
  ///
  /// Set during onboarding review from the products the company actually places
  /// on the market. A subset, not a free list: values outside
  /// [GazetteCategory.all] are dropped on parse rather than displayed, because a
  /// category this build does not recognise cannot be reported against.
  final List<String> categories;

  /// *(S)* One of [OrgStatus].
  final String status;

  final String contactName;
  final String contactEmail;
  final String contactPhone;
  final String address;
  final String district;
  final String city;

  /// *(S)* The Admin who approved onboarding, and when.
  final String? verifiedBy;
  final DateTime? verifiedAt;

  /// *(S)* Server clock.
  final DateTime? createdAt;

  /// Whether the portal is open for work.
  ///
  /// A suspended organisation keeps read access to its own history — suspension
  /// stops new issuance, it does not erase what Chokro already certified
  /// (EPR-47) — so this is deliberately narrower than "can see anything".
  bool get isActive => status == OrgStatus.active;

  bool get isAwaitingReview => status == OrgStatus.pendingReview;

  /// Read-only: the workspace opens, nothing may be submitted or issued.
  bool get isReadOnly => status != OrgStatus.active;

  /// Which year of its own obligation this entity is in at [now], counting the
  /// first year as 1.
  ///
  /// Null when [obligationStartDate] has not been set, which is the honest
  /// answer rather than a default of 1: year 1 carries the 15% target and year
  /// 3 carries 30%, so guessing here would print the wrong law beside a
  /// producer's figure.
  ///
  /// Years are counted on anniversaries rather than by dividing elapsed days,
  /// so a leap year does not shift the boundary.
  int? obligationYearAt(DateTime now) {
    final start = obligationStartDate;
    if (start == null) return null;
    if (now.isBefore(start)) return null;

    var years = now.year - start.year;
    final anniversary = DateTime(now.year, start.month, start.day);
    if (now.isBefore(anniversary)) years -= 1;
    return years + 1;
  }

  /// The gazette collection target that applies to this entity at [now].
  ///
  /// Null when the obligation year is unknown. Callers must render nothing
  /// rather than a placeholder: EPR-26 forbids presenting a target as though it
  /// had been established when it has not.
  double? collectionTargetAt(DateTime now) {
    final year = obligationYearAt(now);
    if (year == null) return null;
    return GazetteTargets.collectionRateForYear(year);
  }

  double? recyclingTargetAt(DateTime now) {
    final year = obligationYearAt(now);
    if (year == null) return null;
    return GazetteTargets.recyclingRateForYear(year);
  }

  /// Which obligation year the reporting period [periodId] falls in.
  ///
  /// ## Why this is not [obligationYearAt] with the period's start date
  ///
  /// [obligationYearAt] answers "which year are we in at this instant", and it
  /// is right for that. This answers "which year does this reporting month
  /// belong to", which is a different question with a different failure mode.
  ///
  /// A reporting period is a calendar month in Asia/Dhaka, so `periodStartUtc`
  /// of `2026-07` is `2026-06-30T18:00:00Z`. [obligationStartDate] is a
  /// calendar DAY, stored as UTC midnight. Comparing those two as instants says
  /// July 2026 precedes an obligation that began on 1 July 2026 — by six hours
  /// — and a null obligation year means no target is shown at all (EPR-26).
  ///
  /// So both sides are reduced to a Dhaka calendar year-and-month first.
  /// Day-of-month is deliberately ignored: a reporting period cannot be half in
  /// one obligation year and half in the next, and month granularity is the
  /// finest the scheme has.
  ///
  /// ## This must agree with the server, exactly
  ///
  /// `passports.js` computes the same figure to decide the applicable target
  /// printed on a Plastic Passport, and this decides the one shown on the
  /// dashboard. A producer comparing the two would be comparing the same period
  /// against two different laws. §5.3's rule for a deliberate duplicate applies:
  /// `test/models/organization_model_test.dart` asserts the same cases the
  /// server's `passports.test.js` does, so a change to one side fails the other.
  int? obligationYearForPeriod(String periodId) {
    final start = obligationStartDate;
    if (start == null) return null;
    if (!isValidPeriodId(periodId)) return null;

    // The Dhaka calendar month the obligation started in.
    final startDhaka = start.toUtc().add(dhakaOffset);
    final periodYear = int.parse(periodId.substring(0, 4));
    final periodMonth = int.parse(periodId.substring(5));

    final monthsElapsed =
        (periodYear - startDhaka.year) * 12 + (periodMonth - startDhaka.month);

    if (monthsElapsed < 0) return null;
    return (monthsElapsed ~/ 12) + 1;
  }

  /// The gazette collection target for a reporting period, or null.
  ///
  /// Null when the obligation year is not established. EPR-26 forbids
  /// presenting a target as though it had been established when it has not, so
  /// a caller renders nothing rather than a placeholder.
  double? collectionTargetForPeriod(String periodId) {
    final year = obligationYearForPeriod(periodId);
    return year == null ? null : GazetteTargets.collectionRateForYear(year);
  }

  /// The name to show. Trade name where there is one, since that is what the
  /// packaging says; legal name otherwise.
  String get displayName => tradeName.isNotEmpty ? tradeName : legalName;

  factory OrganizationModel.fromJson(
    Map<String, dynamic> json, {
    required String id,
  }) {
    return OrganizationModel(
      id: id,
      legalName: _string(json['legalName']),
      tradeName: _string(json['tradeName']),
      bin: _nullableString(json['bin']),
      tradeLicenceNo: _nullableString(json['tradeLicenceNo']),
      doeRegistrationNo: _nullableString(json['doeRegistrationNo']),
      sizeClass: _enumOrNull(json['sizeClass'], OrgSizeClass.all),
      obligationStartDate: _date(json['obligationStartDate']),
      complianceRoute:
          _enumOrNull(json['complianceRoute'], ComplianceRoute.all) ??
          ComplianceRoute.self,
      // Fail closed on status, exactly as `UserModel` does with role: an
      // unreadable or unrecognised value must not open a workspace. Pending
      // review is the least privileged state that still exists.
      status: _enumOrNull(json['status'], OrgStatus.all) ?? OrgStatus.pendingReview,
      categories: _categoryList(json['categories']),
      contactName: _string(json['contactName']),
      contactEmail: _string(json['contactEmail']),
      contactPhone: _string(json['contactPhone']),
      address: _string(json['address']),
      district: _string(json['district']),
      city: _string(json['city']),
      verifiedBy: _nullableString(json['verifiedBy']),
      verifiedAt: _date(json['verifiedAt']),
      createdAt: _date(json['createdAt']),
    );
  }

  /// The applicant-supplied fields only.
  ///
  /// Every server-owned field is deliberately absent: this map is what a client
  /// may propose, and the rules reject any key beyond it. `createdAt` is
  /// omitted for the reason every `toJson` in this codebase omits it — it must
  /// be written with `FieldValue.serverTimestamp()` by the service layer, never
  /// from a device clock.
  Map<String, dynamic> toApplicationJson() => <String, dynamic>{
    'legalName': legalName,
    'tradeName': tradeName,
    'contactName': contactName,
    'contactEmail': contactEmail,
    'contactPhone': contactPhone,
    'address': address,
    'district': district,
    'city': city,
  };
}

String _string(Object? value, {String fallback = ''}) =>
    value is String ? value : fallback;

String? _nullableString(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// A closed-enum field: the stored value if this build recognises it, else null.
///
/// Silently dropping an unrecognised value is the fail-closed reading. A
/// `sizeClass` from a future release that this build renders as an unknown
/// string would end up beside a gazette target chosen by a fallback, which is
/// the one thing §6.7 forbids.
String? _enumOrNull(Object? value, List<String> allowed) =>
    value is String && allowed.contains(value) ? value : null;

List<String> _categoryList(Object? value) {
  if (value is! List) return const <String>[];
  final seen = <String>{};
  // Gazette order, not stored order, so two organisations' category lists are
  // always directly comparable on screen and in an export.
  return GazetteCategory.all
      .where((c) => value.contains(c) && seen.add(c))
      .toList(growable: false);
}

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
