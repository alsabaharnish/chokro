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
  if (!looksLikeJpeg(buffer) && !looksLikePng(buffer)) {
    throw new Error('That file is not a JPEG or PNG image.');
  }

  return buffer;
}

/**
 * Uploads an image and returns its permanent URL.
 *
 * Folders are partitioned by user so that a stray listing cannot mix one
 * person's submissions with another's. This is organisation, not access control
 * — Cloudinary URLs are unguessable but public. Nothing sensitive belongs in a
 * disposal photograph, and the association between a photo and a user lives in
 * Firestore, where the rules actually apply.
 */
async function uploadImage({ base64, uid, kind = 'disposals' }) {
  configure();

  const buffer = decodeImage(base64);
  const dataUri = `data:image/jpeg;base64,${buffer.toString('base64')}`;

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

module.exports = { uploadImage, decodeImage, MAX_BYTES };
