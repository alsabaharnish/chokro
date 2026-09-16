/// Regulator disclosure (SEC-13).
///
/// The one action in Chokro that deliberately re-identifies a person. These
/// models carry the record of it, and their job is to make sure nothing about
/// that record can be rendered as less than it was.
library;

import '../services/location_service.dart';

/// Where the Admin was when they did it — or why that is not known.
///
/// Never null and never absent. A refusal is a FACT ABOUT THE ACCESS and is
/// recorded as one; a blank column would read as "not collected", which is a
/// different and weaker statement.
class DisclosureLocation {
  const DisclosureLocation({
    required this.status,
    this.latitude,
    this.longitude,
    this.accuracyM,
  });

  const DisclosureLocation.unavailable() : this(status: 'unavailable');
  const DisclosureLocation.denied() : this(status: 'denied');

  /// 'granted', 'denied' or 'unavailable'. Never anything else.
  final String status;
  final double? latitude;
  final double? longitude;
  final int? accuracyM;

  bool get hasCoordinates =>
      status == 'granted' && latitude != null && longitude != null;

  /// What to show in the register. Never a dash.
  String get label => switch (status) {
    'granted' when hasCoordinates =>
      '${latitude!.toStringAsFixed(5)}, ${longitude!.toStringAsFixed(5)}'
          '${accuracyM == null ? '' : ' ±${accuracyM}m'}',
    'denied' => 'Refused by the Admin’s device',
    _ => 'Not available',
  };

  /// Built from the app's existing location service.
  ///
  /// A permission refusal maps to `denied` and everything else to
  /// `unavailable`, because "would not say" and "could not say" are different
  /// things to read six months later — one is a choice and the other is a
  /// timeout or a switched-off radio.
  factory DisclosureLocation.fromResult(LocationResult result) {
    return switch (result.outcome) {
      LocationOutcome.fixed when
          result.latitude != null && result.longitude != null =>
        DisclosureLocation(
          status: 'granted',
          latitude: result.latitude,
          longitude: result.longitude,
          accuracyM: result.accuracyMeters?.round(),
        ),
      LocationOutcome.denied ||
      LocationOutcome.deniedForever => const DisclosureLocation.denied(),
      _ => const DisclosureLocation.unavailable(),
    };
  }

  factory DisclosureLocation.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    return DisclosureLocation(
      status: status == 'granted' || status == 'denied'
          ? status as String
          : 'unavailable',
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      accuracyM: (json['accuracyM'] as num?)?.round(),
    );
  }

  Map<String, dynamic> toJson() => {
    'status': status,
    'latitude': latitude,
    'longitude': longitude,
    'accuracyM': accuracyM,
  };
}

/// One attribution behind a resolved reference.
class DisclosedAttribution {
  const DisclosedAttribution({
    required this.attributionId,
    this.periodId,
    this.skuId,
    this.units = 0,
    this.massMg = 0,
    this.binId,
    this.district,
    this.confidenceTier,
  });

  final String attributionId;
  final String? periodId;
  final String? skuId;
  final int units;
  final int massMg;
  final String? binId;
  final String? district;
  final String? confidenceTier;

  factory DisclosedAttribution.fromJson(Map<String, dynamic> json) {
    return DisclosedAttribution(
      attributionId: json['attributionId'] is String
          ? json['attributionId'] as String
          : '',
      periodId: json['periodId'] as String?,
      skuId: json['skuId'] as String?,
      units: (json['units'] as num?)?.round() ?? 0,
      massMg: (json['massMg'] as num?)?.round() ?? 0,
      binId: json['binId'] as String?,
      district: json['district'] as String?,
      confidenceTier: json['confidenceTier'] as String?,
    );
  }
}

/// The result of resolving a pseudonymous reference.
class DisclosureResult {
  const DisclosureResult({
    required this.found,
    required this.exhaustive,
    required this.attributions,
    this.registerId,
    this.disposalId,
    this.referenceKeyed,
    this.disposalPresent = false,
    this.photoUrl,
    this.binId,
    this.status,
    this.note,
  });

  final bool found;

  /// Whether the search covered everything it could.
  ///
  /// A not-found with `exhaustive: false` means the scan stopped early. Telling
  /// a regulator that a genuine row is unknown is the worst answer this feature
  /// can give, so the two must never render the same.
  final bool exhaustive;

  final List<DisclosedAttribution> attributions;

  /// The register row this access wrote. Null when the register write failed —
  /// rendered as a gap rather than hidden, because the access still happened.
  final String? registerId;

  final String? disposalId;

  /// Whether the reference was minted under a key.
  ///
  /// False means the export predates `AUDIT_CHAIN_KEY`. Worth knowing about an
  /// exhibit, so it is carried rather than dropped.
  final bool? referenceKeyed;

  /// False when the disposal has since been erased. Its attributions survive —
  /// that is the design, not a fault.
  final bool disposalPresent;
  final String? photoUrl;
  final String? binId;
  final String? status;
  final String? note;

  factory DisclosureResult.fromJson(Map<String, dynamic> json) {
    final evidence = json['evidence'];
    final e = evidence is Map<String, dynamic>
        ? evidence
        : const <String, dynamic>{};
    final rows = json['attributions'];

    return DisclosureResult(
      found: json['found'] == true,
      // Absent reads as NOT exhaustive. A missing field must never become the
      // stronger claim.
      exhaustive: json['exhaustive'] == true,
      attributions: rows is List
          ? rows
                .whereType<Map<String, dynamic>>()
                .map(DisclosedAttribution.fromJson)
                .toList(growable: false)
          : const <DisclosedAttribution>[],
      registerId: json['registerId'] as String?,
      disposalId: json['disposalId'] as String?,
      referenceKeyed: json['referenceKeyed'] is bool
          ? json['referenceKeyed'] as bool
          : null,
      disposalPresent: e['disposalPresent'] == true,
      photoUrl: e['photoUrl'] as String?,
      binId: e['binId'] as String?,
      status: e['status'] as String?,
      note: (json['note'] ?? e['note']) as String?,
    );
  }
}

/// One line of the register: who did what, when, from where, and why.
class DisclosureRecord {
  const DisclosureRecord({
    required this.id,
    required this.kind,
    required this.location,
    this.orgId,
    this.subject,
    this.doeReference,
    this.declaration,
    this.adminName,
    this.adminUid,
    this.ip,
    this.at,
  });

  final String id;

  /// 'resolve' or 'identity'. The second names a person and the register must
  /// show which is which at a glance.
  final String kind;

  final DisclosureLocation location;
  final String? orgId;
  final String? subject;
  final String? doeReference;

  /// The Admin's own words. The only field that says *why*, and the reason the
  /// register is worth reading at all.
  final String? declaration;

  final String? adminName;
  final String? adminUid;
  final String? ip;
  final DateTime? at;

  bool get namedAPerson => kind == 'identity';

  factory DisclosureRecord.fromJson(Map<String, dynamic> json) {
    final at = json['at'];
    return DisclosureRecord(
      id: json['id'] is String ? json['id'] as String : '',
      kind: json['kind'] is String ? json['kind'] as String : 'resolve',
      location: json['location'] is Map<String, dynamic>
          ? DisclosureLocation.fromJson(json['location'] as Map<String, dynamic>)
          : const DisclosureLocation.unavailable(),
      orgId: json['orgId'] as String?,
      subject: json['subject'] as String?,
      doeReference: json['doeReference'] as String?,
      declaration: json['declaration'] as String?,
      adminName: json['adminName'] as String?,
      adminUid: json['adminUid'] as String?,
      ip: json['ip'] as String?,
      at: at is String ? DateTime.tryParse(at) : null,
    );
  }
}

/// The register, and whether it is the whole of it.
class DisclosureRegister {
  const DisclosureRegister({
    required this.entries,
    required this.complete,
    required this.limit,
  });

  final List<DisclosureRecord> entries;

  /// False when the register reached its bound.
  ///
  /// Absent reads as INCOMPLETE. On a register of privileged accesses a missing
  /// row matters more than anywhere else in this product, so the reassuring
  /// reading is never the default.
  final bool complete;

  final int limit;

  factory DisclosureRegister.fromJson(Map<String, dynamic> json) {
    final rows = json['entries'];
    return DisclosureRegister(
      entries: rows is List
          ? rows
                .whereType<Map<String, dynamic>>()
                .map(DisclosureRecord.fromJson)
                .toList(growable: false)
          : const <DisclosureRecord>[],
      complete: json['complete'] == true,
      limit: (json['limit'] as num?)?.round() ?? 0,
    );
  }
}
