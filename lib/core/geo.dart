/// Chokro — geospatial arithmetic (F2.5).
///
/// Pure Dart. No Firebase, no plugins, no `geolocator` import. The `geolocator`
/// package supplies coordinates; this file decides what they mean. Keeping the
/// two apart is what makes the radius check unit-testable without a device.
///
/// TRUST BOUNDARY — read this before using any of it.
/// Everything here runs on the user's phone, on coordinates the phone reported.
/// A modified client can report any coordinates it likes. The distance computed
/// on-device is therefore **user feedback only** ("you appear to be 40m from
/// this bin"). The authoritative check runs on the server, against the
/// coordinates stored on the submission, at decision time. Both sides call the
/// same maths — that is the point of putting it in a pure file — but only one
/// side's answer is trusted. See §7.4 of the project brief.
library;

import 'dart:math' as math;

/// Mean Earth radius in metres (IUGG). Haversine assumes a sphere, which is
/// wrong by roughly 0.3% at worst — irrelevant at the scale of a bin geofence,
/// where the radius is tens of metres and GPS error alone is larger.
const double earthRadiusMeters = 6371000.0;

/// Great-circle distance in metres between two coordinates.
///
/// Returns 0 for identical points. Never negative. Accurate to well under a
/// metre for the short distances this app deals with.
double haversineDistance({
  required double lat1,
  required double lng1,
  required double lat2,
  required double lng2,
}) {
  final phi1 = _toRadians(lat1);
  final phi2 = _toRadians(lat2);
  final deltaPhi = _toRadians(lat2 - lat1);
  final deltaLambda = _toRadians(lng2 - lng1);

  final sinHalfLat = math.sin(deltaPhi / 2);
  final sinHalfLng = math.sin(deltaLambda / 2);

  final a =
      sinHalfLat * sinHalfLat +
      math.cos(phi1) * math.cos(phi2) * sinHalfLng * sinHalfLng;

  // asin form rather than atan2: numerically better behaved for small distances,
  // which is the only case that matters here.
  final clamped = a > 1.0 ? 1.0 : a;
  return 2 * earthRadiusMeters * math.asin(math.sqrt(clamped));
}

/// Whether a captured position falls inside a bin's accepted radius.
///
/// The comparison is inclusive: standing exactly on the boundary counts as
/// inside. GPS precision makes the boundary fuzzy anyway, and refusing an
/// honest user for a sub-metre difference is the wrong failure direction.
bool isWithinRadius({
  required double binLat,
  required double binLng,
  required double capturedLat,
  required double capturedLng,
  required double radiusMeters,
}) {
  if (radiusMeters <= 0) return false;
  final distance = haversineDistance(
    lat1: binLat,
    lng1: binLng,
    lat2: capturedLat,
    lng2: capturedLng,
  );
  return distance <= radiusMeters;
}

/// Whether a GPS fix is too imprecise to be the centre of a geofence this size
/// (F2.1).
///
/// Asked when an administrator registers a bin from a live fix, and judged
/// against the radius rather than a fixed threshold, because that ratio is what
/// decides whether honest submissions will pass.
///
/// A bin's recorded coordinates are not checked once — they become the reference
/// point every future submission at that bin is measured against, so an error
/// here is inherited by all of them. If the centre lands 30 m from the real bin
/// inside a 40 m radius, a resident standing at the bin can measure 70 m and be
/// refused, and nothing on the submission would ever reveal that the bin, not
/// the resident, was in the wrong place. A fix good to ±30 m is meanwhile
/// perfectly adequate for a 200 m compound.
///
/// Half the radius is the threshold: at that point the error alone can consume
/// the whole margin a resident has to stand in.
///
/// Returns false when either value is unknown or the radius is nonsensical —
/// this reports a fix that *is* too rough, and declines to guess otherwise.
bool isFixTooRoughForRadius({
  required double? accuracyMeters,
  required double? radiusMeters,
}) {
  if (accuracyMeters == null || radiusMeters == null) return false;
  if (accuracyMeters.isNaN || radiusMeters.isNaN) return false;
  if (radiusMeters <= 0) return false;
  return accuracyMeters > radiusMeters / 2;
}

/// Whether [latitude] is a possible latitude.
bool isValidLatitude(double latitude) =>
    !latitude.isNaN && latitude >= -90.0 && latitude <= 90.0;

/// Whether [longitude] is a possible longitude.
bool isValidLongitude(double longitude) =>
    !longitude.isNaN && longitude >= -180.0 && longitude <= 180.0;

/// Whether a coordinate pair is usable at all.
///
/// Guards against the `0, 0` that a failed location fix often produces — a real
/// point in the Gulf of Guinea, and never anywhere a Chokro bin will be. A
/// submission carrying null island coordinates is a broken fix, not a location.
bool isPlausibleCoordinate(double latitude, double longitude) {
  if (!isValidLatitude(latitude) || !isValidLongitude(longitude)) return false;
  if (latitude == 0.0 && longitude == 0.0) return false;
  return true;
}

/// Human-readable distance for the submission and review screens.
/// Metres below a kilometre, one decimal place of kilometres above it.
String formatDistance(double meters) {
  if (meters.isNaN || meters < 0) return '—';
  if (meters < 1000) return '${meters.round()} m';
  return '${(meters / 1000).toStringAsFixed(1)} km';
}

double _toRadians(double degrees) => degrees * math.pi / 180.0;
