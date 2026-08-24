/**
 * Image hosting via Cloudinary.
 *
 * WHY NOT FIREBASE STORAGE
 * Firebase requires the Blaze (billing) plan to provision a Storage bucket, and
 * this project deliberately runs without a billing relationship (§4.3). Photos
 * therefore go to Cloudinary's free tier instead, and they go *through this
 * service* rather than direct from the client.
 *
 * That routing is not a workaround, it is an improvement. The server needs the
 * raw bytes anyway — to compute the perceptual hash and to send the image for
 * screening. Uploading through here means one transfer instead of two, and the
 * hash is computed from exactly the bytes that were stored.
 *
 * The API secret never leaves this process. A client-side upload would need an
 * unsigned preset, which is a public write endpoint anyone can point a script at.
 */

const { v2: cloudinary } = require('cloudinary');

let configured = false;

/**
 * Upload folders the public API is allowed to create.
 *
 * Each purpose gets a separate folder because `firestore.rules` validates a
 * stored URL against `chokro/<kind>/<uid>/`: a listing cannot borrow evidence,
 * and a profile picture cannot point at another account or an arbitrary host.
 */
const PHOTO_KINDS = Object.freeze([
  'disposals',
  'claims',
  'products',
  'profiles',
]);

function configure() {
  if (configured) return;

  const cloudName = process.env.CLOUDINARY_CLOUD_NAME;
  const apiKey = process.env.CLOUDINARY_API_KEY;
  const apiSecret = process.env.CLOUDINARY_API_SECRET;

  if (!cloudName || !apiKey || !apiSecret) {
    throw new Error(
      'Cloudinary is not configured. Set CLOUDINARY_CLOUD_NAME, ' +
        'CLOUDINARY_API_KEY and CLOUDINARY_API_SECRET.',
    );
  }

  cloudinary.config({
    cloud_name: cloudName,
    api_key: apiKey,
    api_secret: apiSecret,
    secure: true,
  });

  configured = true;
}

/** JPEG files begin FF D8 FF. Cheap sanity check before spending an upload. */
function looksLikeJpeg(buffer) {
  return (
    buffer.length > 3 &&
    buffer[0] === 0xff &&
    buffer[1] === 0xd8 &&
    buffer[2] === 0xff
  );
}

/** PNG files begin with an 8-byte signature. */
function looksLikePng(buffer) {
  const sig = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (buffer.length < sig.length) return false;
  return sig.every((byte, i) => buffer[i] === byte);
}

function imageMimeType(buffer) {
  if (looksLikeJpeg(buffer)) return 'image/jpeg';
  if (looksLikePng(buffer)) return 'image/png';
  return null;
}

const MAX_BYTES = 5 * 1024 * 1024;

/**
 * Decodes and validates a base64 image payload.
 * Throws with a user-safe message; never logs the payload.
 */
function decodeImage(base64) {
  if (typeof base64 !== 'string' || base64.length === 0) {
    throw new Error('No image data was sent.');
  }

  // Tolerate a data URI prefix as well as bare base64.
  const cleaned = base64.replace(/^data:image\/[a-zA-Z+]+;base64,/, '');
  const buffer = Buffer.from(cleaned, 'base64');

  if (buffer.length === 0) {
    throw new Error('The image data could not be decoded.');
  }
  if (buffer.length > MAX_BYTES) {
    throw new Error('That image is too large. The app should compress first.');
  }
  if (imageMimeType(buffer) === null) {
    throw new Error('That file is not a JPEG or PNG image.');
  }

  return buffer;
}

/**
 * Uploads an image and returns its permanent URL.
 *
 * Folders are partitioned by user so that a stray listing cannot mix one
 * person's submissions with another's. This is organisation, not access control
 * — Cloudinary URLs are unguessable but public. Evidence must not contain
 * secrets, and a profile picture is public-facing by design. The association
 * between either image and a user lives in Firestore, where access and
 * publication permission are enforced.
 */
async function uploadImage({ base64, uid, kind = 'disposals' }) {
  if (typeof uid !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(uid)) {
    throw new Error('The signed-in account cannot store photographs.');
  }
  if (!PHOTO_KINDS.includes(kind)) {
    throw new Error('That photo category is not supported.');
  }

  configure();

  const buffer = decodeImage(base64);
  const mimeType = imageMimeType(buffer);
  const dataUri = `data:${mimeType};base64,${buffer.toString('base64')}`;

  const result = await cloudinary.uploader.upload(dataUri, {
    folder: `chokro/${kind}/${uid}`,
    resource_type: 'image',
    // Cloudinary strips EXIF by default on transform; the client has already
    // stripped it during compression (§7.4). Belt and braces.
    overwrite: false,
  });

  return {
    url: result.secure_url,
    publicId: result.public_id,
    bytes: result.bytes,
    width: result.width,
    height: result.height,
  };
}

/** Removes one managed image after a downstream operation failed. */
async function deleteImage(publicId) {
  const kinds = PHOTO_KINDS.join('|');
  const managedId = new RegExp(
    `^chokro/(?:${kinds})/[A-Za-z0-9_-]{1,128}/[A-Za-z0-9_-]{1,200}$`,
  );
  if (typeof publicId !== 'string' || !managedId.test(publicId)) {
    throw new Error('Only a managed Chokro image can be removed.');
  }

  configure();
  return cloudinary.uploader.destroy(publicId, {
    resource_type: 'image',
    invalidate: true,
  });
}

/**
 * Whether a Firestore photo reference names an original uploaded by this user.
 *
 * Firestore documents are client-created. Without this check a modified client
 * could replace the URL/public id returned by `/photos/*` with another image in
 * the Cloudinary account, and the verification pipeline would screen and hash
 * that unrelated asset. This validation is repeated in rules for fast rejection
 * and here because payout code must not rely on a client-facing rule alone.
 *
 * Only original delivery URLs are accepted — no transformations in the stored
 * URL — and the public id must live below the authenticated user's folder.
 */
function isTrustedImageReference({
  url,
  publicId,
  uid,
  kind,
  cloudName = process.env.CLOUDINARY_CLOUD_NAME,
}) {
  if (
    typeof url !== 'string' ||
    url.length === 0 ||
    url.length > 1000 ||
    typeof publicId !== 'string' ||
    publicId.length === 0 ||
    publicId.length > 500 ||
    typeof uid !== 'string' ||
    !/^[A-Za-z0-9_-]{1,128}$/.test(uid) ||
    !PHOTO_KINDS.includes(kind) ||
    typeof cloudName !== 'string' ||
    cloudName.length === 0
  ) {
    return false;
  }

  const prefix = `chokro/${kind}/${uid}/`;
  const assetId = publicId.slice(prefix.length);
  if (!publicId.startsWith(prefix) || !/^[A-Za-z0-9_-]{1,200}$/.test(assetId)) {
    return false;
  }

  try {
    const parsed = new URL(url);
    if (parsed.protocol !== 'https:' || parsed.hostname !== 'res.cloudinary.com') {
      return false;
    }

    const segments = parsed.pathname
      .split('/')
      .filter(Boolean)
      .map((segment) => decodeURIComponent(segment));

    if (
      segments[0] !== cloudName ||
      segments[1] !== 'image' ||
      segments[2] !== 'upload'
    ) {
      return false;
    }

    let assetSegments = segments.slice(3);
    if (/^v\d+$/.test(assetSegments[0] || '')) {
      assetSegments = assetSegments.slice(1);
    }

    const delivered = assetSegments.join('/');
    const extensionIndex = delivered.lastIndexOf('.');
    if (extensionIndex <= 0) return false;

    return delivered.slice(0, extensionIndex) === publicId;
  } catch {
    return false;
  }
}

module.exports = {
  uploadImage,
  deleteImage,
  decodeImage,
  imageMimeType,
  isTrustedImageReference,
  PHOTO_KINDS,
  MAX_BYTES,
};
