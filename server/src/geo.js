/**
 * Geospatial arithmetic — Node port of `lib/core/geo.dart`.
 *
 * DUPLICATION IS INTENTIONAL (§5.3). The client computes distance so it can tell
 * the user "you are 12 m from this bin". The server recomputes it to decide
 * whether to pay. Both must agree, and both are unit-tested against the same
 * reference values, but only the server's answer is trusted — a client can lie
 * about its coordinates and about the distance it derived from them.
 *
 * Sharing code across the language boundary would cost more than it saves at
 * this scale. Keeping the two in step is a test's job, not a build step's.
 */

/** Mean Earth radius in metres (IUGG). */
const EARTH_RADIUS_METERS = 6371000.0;

function toRadians(degrees) {
  return (degrees * Math.PI) / 180.0;
}

/**
 * Great-circle distance in metres between two coordinates.
 * Returns 0 for identical points. Never negative.
 */
function haversineDistance(lat1, lng1, lat2, lng2) {
  const phi1 = toRadians(lat1);
  const phi2 = toRadians(lat2);
  const deltaPhi = toRadians(lat2 - lat1);
  const deltaLambda = toRadians(lng2 - lng1);

  const sinHalfLat = Math.sin(deltaPhi / 2);
  const sinHalfLng = Math.sin(deltaLambda / 2);

  const a =
    sinHalfLat * sinHalfLat +
    Math.cos(phi1) * Math.cos(phi2) * sinHalfLng * sinHalfLng;

  // Clamp guards against a rounding error pushing the term above 1, which would
  // make asin return NaN for antipodal points.
  const clamped = a > 1.0 ? 1.0 : a;
  return 2 * EARTH_RADIUS_METERS * Math.asin(Math.sqrt(clamped));
}

/**
 * Whether a captured position falls inside a bin's accepted radius.
 * Inclusive at the boundary: GPS precision makes the edge fuzzy, and refusing an
 * honest user over a sub-metre difference is the wrong failure direction.
 */
function isWithinRadius({
  binLat,
  binLng,
  capturedLat,
  capturedLng,
  radiusMeters,
}) {
  if (!(radiusMeters > 0)) return false;
  const distance = haversineDistance(binLat, binLng, capturedLat, capturedLng);
  return distance <= radiusMeters;
}

function isValidLatitude(latitude) {
  return Number.isFinite(latitude) && latitude >= -90 && latitude <= 90;
}

function isValidLongitude(longitude) {
  return Number.isFinite(longitude) && longitude >= -180 && longitude <= 180;
}

/**
 * Guards against the `0, 0` a failed location fix often produces — a real point
 * in the Gulf of Guinea, and never anywhere a Chokro bin will be.
 */
function isPlausibleCoordinate(latitude, longitude) {
  if (!isValidLatitude(latitude) || !isValidLongitude(longitude)) return false;
  if (latitude === 0 && longitude === 0) return false;
  return true;
}

module.exports = {
  EARTH_RADIUS_METERS,
  haversineDistance,
  isWithinRadius,
  isValidLatitude,
  isValidLongitude,
  isPlausibleCoordinate,
};
