/**
 * Chokro — bin registration (F2.1).
 *
 * Bins are server-owned. `firestore.rules` denies every client write to the
 * collection, including an administrator's, because a bin's coordinates and
 * radius are inputs this service trusts when it decides a payout. A client that
 * could move a bin could move the geofence, and the geofence is most of what
 * makes a disposal award worth more than a self-reported claim.
 *
 * The QR payload is allocated here for the same reason plus one more: it has to
 * be unique, and uniqueness is not a property a client can guarantee. Two
 * administrators registering bins at the same moment on two phones cannot
 * coordinate; this module checks for a collision before writing.
 */

const crypto = require('crypto');

const { db, serverTimestamp } = require('./firebase');
const { isValidLatitude, isValidLongitude } = require('./geo');

const DEFAULT_RADIUS_METERS = 50;
const MAX_RADIUS_METERS = 1000;

/**
 * An opaque bin identifier for the printed code.
 *
 * Carries no coordinates and no user data (§6). A photographed code discloses
 * nothing and possessing one proves nothing — it names a bin, and standing at
 * that bin is proved separately by GPS.
 *
 * Six random bytes is 2^48 values. At the scale of a neighbourhood deployment a
 * collision is vanishingly unlikely, and `allocateQrPayload` checks anyway
 * rather than relying on that.
 */
function generateQrPayload() {
  return `chokro:bin:${crypto.randomBytes(6).toString('hex')}`;
}

/**
 * Human-readable problems with a proposed bin. Empty means safe to write.
 *
 * Mirrors `BinModel.validate()` in the Flutter client. The client's copy gives
 * immediate feedback; this one is the check that counts.
 */
function validateBin({ label, lat, lng, radiusMeters }) {
  const problems = [];

  if (typeof label !== 'string' || label.trim().length === 0) {
    problems.push('Bin label is required.');
  } else if (label.trim().length > 120) {
    problems.push('Bin label may not exceed 120 characters.');
  }

  if (typeof lat !== 'number' || Number.isNaN(lat) || !isValidLatitude(lat)) {
    problems.push('Latitude is out of range.');
  }
  if (typeof lng !== 'number' || Number.isNaN(lng) || !isValidLongitude(lng)) {
    problems.push('Longitude is out of range.');
  }

  // Null Island. A GPS fix that failed frequently reports 0,0, and a bin there
  // would accept submissions from a boat in the Atlantic.
  if (lat === 0 && lng === 0) {
    problems.push('Coordinates look like a failed GPS fix.');
  }

  const radius = radiusMeters === undefined ? DEFAULT_RADIUS_METERS : radiusMeters;
  if (typeof radius !== 'number' || Number.isNaN(radius) || radius <= 0) {
    problems.push('Radius must be greater than zero.');
  } else if (radius > MAX_RADIUS_METERS) {
    problems.push(
      `Radius may not exceed ${MAX_RADIUS_METERS} m — a geofence that large no ` +
        'longer proves the user was at the bin.',
    );
  }

  return problems;
}

/**
 * A payload no existing bin is using.
 *
 * Throws rather than returning a duplicate. Failing to register a bin is
 * recoverable; two bins sharing a payload is not — `resolveByPayload` takes the
 * first match, so scans at one bin would silently credit against the other.
 */
async function allocateQrPayload(attempts = 5) {
  for (let i = 0; i < attempts; i += 1) {
    const payload = generateQrPayload();
    const existing = await db()
      .collection('bins')
      .where('qrPayload', '==', payload)
      .limit(1)
      .get();

    if (existing.empty) return payload;
  }
  throw new Error('Could not allocate a unique QR payload. Try again.');
}

/** Registers a bin and returns it, including its generated id and payload. */
async function createBin({ label, lat, lng, radiusMeters, adminUid }) {
  const qrPayload = await allocateQrPayload();
  const radius = radiusMeters === undefined ? DEFAULT_RADIUS_METERS : radiusMeters;

  const record = {
    label: label.trim(),
    lat,
    lng,
    radiusMeters: radius,
    qrPayload,
    active: true,
    createdBy: adminUid,
    createdAt: serverTimestamp(),
  };

  const ref = await db().collection('bins').add(record);

  // serverTimestamp() is a sentinel until it lands, so it is not returned. The
  // client reads createdAt from its own Firestore listener a moment later.
  return {
    id: ref.id,
    label: record.label,
    lat: record.lat,
    lng: record.lng,
    radiusMeters: record.radiusMeters,
    qrPayload,
    active: true,
    createdBy: adminUid,
  };
}

/**
 * Takes a bin in or out of service.
 *
 * Never deletes. Past disposals reference their bin, and a dangling reference
 * breaks a user's history and an administrator's ability to review it.
 */
async function setBinActive({ binId, active, adminUid }) {
  const ref = db().collection('bins').doc(binId);
  const snap = await ref.get();
  if (!snap.exists) throw new Error('That bin does not exist.');

  await ref.update({
    active: Boolean(active),
    deactivatedAt: active ? null : serverTimestamp(),
    lastChangedBy: adminUid,
  });

  return { id: binId, active: Boolean(active) };
}

module.exports = {
  DEFAULT_RADIUS_METERS,
  MAX_RADIUS_METERS,
  generateQrPayload,
  validateBin,
  allocateQrPayload,
  createBin,
  setBinActive,
};
