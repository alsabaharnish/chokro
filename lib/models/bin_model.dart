/// Chokro — bin model (F2.1).
///
/// Plain Dart, no Firebase imports (§5.1). The service layer converts Firestore
/// `Timestamp` values to [DateTime] before calling [BinModel.fromJson], and back
/// again on write. Models never know what a Timestamp is.
library;

/// A registered disposal point.
///
/// Bins are created by an administrator standing at the bin, so `lat`/`lng` come
/// from a live GPS fix rather than typed input (§5.3). The [qrPayload] is printed
/// and attached to the physical bin.
class BinModel {
  /// Firestore document ID. Null for a bin not yet written.
  final String? id;

  /// Human-readable name shown in the app and on the printed label,
  /// e.g. "Merul Badda — Block C gate".
  final String label;

  final double lat;
  final double lng;

  /// Accepted distance in metres for a disposal submission at this bin.
  /// Tuned per bin: a rooftop bin in a dense block needs a tighter radius than
  /// one in an open compound.
  final double radiusMeters;

  /// The opaque identifier encoded into the printed QR code.
  ///
  /// SECURITY: this carries no coordinates and no user data (§6). A photographed
  /// or copied code discloses nothing, and possessing one proves nothing — it
  /// only names a bin. Standing near that bin is proved separately, by GPS.
  final String qrPayload;

  /// Inactive bins stop accepting submissions but are never deleted, because
  /// past disposals reference them and a dangling reference breaks history.
  final bool active;

  /// UID of the administrator who registered the bin.
  final String createdBy;

  final DateTime? createdAt;

  const BinModel({
    this.id,
    required this.label,
    required this.lat,
    required this.lng,
    required this.radiusMeters,
    required this.qrPayload,
    required this.active,
    required this.createdBy,
    this.createdAt,
  });

  factory BinModel.fromJson(Map<String, dynamic> json, {String? id}) {
    return BinModel(
      id: id ?? json['id'] as String?,
      label: (json['label'] as String?) ?? '',
      lat: _toDouble(json['lat']),
      lng: _toDouble(json['lng']),
      radiusMeters: _toDouble(json['radiusMeters'], fallback: 50.0),
      qrPayload: (json['qrPayload'] as String?) ?? '',
      active: (json['active'] as bool?) ?? true,
      createdBy: (json['createdBy'] as String?) ?? '',
      createdAt: json['createdAt'] as DateTime?,
    );
  }

  /// Field map for a Firestore write.
  ///
  /// [createdAt] is deliberately omitted: it must be written with
  /// `FieldValue.serverTimestamp()` by the service layer, never with a
  /// client-authored clock value (§7.4).
  Map<String, dynamic> toJson() => <String, dynamic>{
        'label': label,
        'lat': lat,
        'lng': lng,
        'radiusMeters': radiusMeters,
        'qrPayload': qrPayload,
        'active': active,
        'createdBy': createdBy,
      };

  BinModel copyWith({
    String? id,
    String? label,
    double? lat,
    double? lng,
    double? radiusMeters,
    String? qrPayload,
    bool? active,
    String? createdBy,
    DateTime? createdAt,
  }) {
    return BinModel(
      id: id ?? this.id,
      label: label ?? this.label,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      radiusMeters: radiusMeters ?? this.radiusMeters,
      qrPayload: qrPayload ?? this.qrPayload,
      active: active ?? this.active,
      createdBy: createdBy ?? this.createdBy,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  /// Human-readable problems with this bin. Empty means it is safe to save.
  List<String> validate() {
    final problems = <String>[];
    if (label.trim().isEmpty) {
      problems.add('Bin label is required.');
    }
    if (qrPayload.trim().isEmpty) {
      problems.add('QR payload is required.');
    }
    if (createdBy.trim().isEmpty) {
      problems.add('Creating administrator is required.');
    }
    if (lat.isNaN || lat < -90 || lat > 90) {
      problems.add('Latitude is out of range.');
    }
    if (lng.isNaN || lng < -180 || lng > 180) {
      problems.add('Longitude is out of range.');
    }
    if (lat == 0 && lng == 0) {
      problems.add('Coordinates look like a failed GPS fix.');
    }
    if (radiusMeters <= 0) {
      problems.add('Radius must be greater than zero.');
    }
    if (radiusMeters > 1000) {
      problems.add('Radius may not exceed 1000 m — a geofence that large '
          'no longer proves the user was at the bin.');
    }
    return problems;
  }

  bool get isValid => validate().isEmpty;

  /// Whether this bin can currently accept submissions.
  bool get acceptsSubmissions => active && isValid;

  @override
  String toString() => 'BinModel(id: $id, label: $label, active: $active)';

  @override
  bool operator ==(Object other) =>
      other is BinModel &&
      other.id == id &&
      other.label == label &&
      other.lat == lat &&
      other.lng == lng &&
      other.radiusMeters == radiusMeters &&
      other.qrPayload == qrPayload &&
      other.active == active &&
      other.createdBy == createdBy &&
      other.createdAt == createdAt;

  @override
  int get hashCode => Object.hash(
        id,
        label,
        lat,
        lng,
        radiusMeters,
        qrPayload,
        active,
        createdBy,
        createdAt,
      );
}

double _toDouble(Object? value, {double fallback = 0.0}) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is num) return value.toDouble();
  return fallback;
}
