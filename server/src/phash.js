/**
 * Chokro — perceptual hashing for duplicate detection (F2.11).
 *
 * WHY NO IMAGE LIBRARY
 * A perceptual hash needs the image decoded to an 8x8 grayscale grid. The usual
 * way is `sharp`, a native binary that inflates the build and is memory-hungry
 * on a free Render instance. But Cloudinary already holds the image and can
 * return exactly that grid through a URL transform, so the decoding happens
 * upstream and this module works on 64 bytes of pixel values. One fewer
 * dependency, and nothing native to compile.
 *
 * WHY PERCEPTUAL, NOT CRYPTOGRAPHIC
 * A SHA of the bytes changes completely when a photograph is recompressed,
 * resized, or re-saved by a different camera app. Two submissions of the same
 * photograph would hash differently and the check would never fire. A
 * perceptual hash describes what the image *looks like*, so it survives that.
 *
 * WHY THE SERVER COMPUTES IT
 * A client-supplied fingerprint is worthless: a modified app would send a fresh
 * random value every time and the check would never fire. `firestore.rules`
 * rejects a `photoHash` key on creation for exactly this reason (§7.4).
 *
 * LIMITATION, to be stated in the term paper: hashes are compared within one
 * user's own history only. Detecting a photograph shared between two accounts
 * needs a global hash index, which is deferred (§7.2).
 */

const HASH_SIZE = 8; // 8x8 grid -> 64 bits
const PIXEL_COUNT = HASH_SIZE * HASH_SIZE;

/**
 * The Cloudinary URL that yields the grid this module hashes.
 *
 * Transform chain: resize to 8x8 ignoring aspect ratio, drop colour, emit PNG.
 * `f_png` matters — a JPEG at 8x8 would add compression artefacts to the very
 * pixels being compared.
 *
 * @param {string} publicId  Cloudinary public_id from the upload result
 * @param {string} cloudName
 */
function hashSourceUrl(publicId, cloudName) {
  const transform = `c_scale,w_${HASH_SIZE},h_${HASH_SIZE},e_grayscale,f_png`;
  return `https://res.cloudinary.com/${cloudName}/image/upload/${transform}/${publicId}.png`;
}

/**
 * Computes a 64-bit average hash from 64 grayscale pixel values.
 *
 * Each bit says whether that pixel is brighter than the image's mean. Returned
 * as 16 hex characters.
 *
 * Pure: given the same pixels it always returns the same string, which is what
 * makes it testable without a network or an image.
 *
 * @param {number[]} pixels  exactly 64 values, 0-255
 */
function averageHash(pixels) {
  if (!Array.isArray(pixels) || pixels.length !== PIXEL_COUNT) {
    throw new Error(`Expected ${PIXEL_COUNT} pixel values, got ${pixels?.length}`);
  }

  const mean = pixels.reduce((sum, p) => sum + p, 0) / PIXEL_COUNT;

  let hash = '';
  for (let nibble = 0; nibble < PIXEL_COUNT / 4; nibble += 1) {
    let value = 0;
    for (let bit = 0; bit < 4; bit += 1) {
      value <<= 1;
      if (pixels[nibble * 4 + bit] > mean) value |= 1;
    }
    hash += value.toString(16);
  }

  return hash;
}

/**
 * Differing bits between two hashes. 0 means identical, 64 means opposite.
 *
 * @returns {number}
 */
function hammingDistance(hashA, hashB) {
  if (typeof hashA !== 'string' || typeof hashB !== 'string') {
    throw new Error('Both hashes must be strings.');
  }
  if (hashA.length !== hashB.length) {
    throw new Error('Hashes must be the same length to compare.');
  }

  let distance = 0;
  for (let i = 0; i < hashA.length; i += 1) {
    let diff = parseInt(hashA[i], 16) ^ parseInt(hashB[i], 16);
    while (diff) {
      distance += diff & 1;
      diff >>= 1;
    }
  }
  return distance;
}

/**
 * Below this Hamming distance, two images are treated as the same photograph.
 *
 * 5 of 64 bits is deliberately conservative. A false positive here does not
 * reject anything — it flags for review, where a person looks at both images.
 * A false negative silently lets a duplicate through. So the threshold errs
 * toward flagging, consistent with failing toward review everywhere else.
 */
const DUPLICATE_THRESHOLD = 5;

/**
 * Whether [candidate] matches any hash in [previous].
 *
 * @param {string} candidate
 * @param {string[]} previous  hashes from this user's own earlier submissions
 * @returns {{isDuplicate: boolean, matchedHash: string|null, distance: number|null}}
 */
function findDuplicate(candidate, previous, threshold = DUPLICATE_THRESHOLD) {
  if (!candidate || !Array.isArray(previous)) {
    return { isDuplicate: false, matchedHash: null, distance: null };
  }

  let best = null;
  let bestDistance = Infinity;

  for (const hash of previous) {
    if (typeof hash !== 'string' || hash.length !== candidate.length) continue;
    const distance = hammingDistance(candidate, hash);
    if (distance < bestDistance) {
      bestDistance = distance;
      best = hash;
    }
  }

  if (best === null) {
    return { isDuplicate: false, matchedHash: null, distance: null };
  }

  return {
    isDuplicate: bestDistance <= threshold,
    matchedHash: best,
    distance: bestDistance,
  };
}

/**
 * Fetches the 8x8 grayscale PNG and hashes it.
 *
 * The only I/O in this module. Throws on any failure rather than returning a
 * sentinel — the caller treats an unavailable hash as a reason to route to
 * review, never as a reason to approve.
 */
async function hashImage(publicId, cloudName = process.env.CLOUDINARY_CLOUD_NAME) {
  if (!cloudName) throw new Error('CLOUDINARY_CLOUD_NAME is not set.');

  const url = hashSourceUrl(publicId, cloudName);
  const response = await fetch(url);

  if (!response.ok) {
    throw new Error(`Could not fetch the hash source (${response.status}).`);
  }

  const buffer = Buffer.from(await response.arrayBuffer());
  return averageHash(extractPixels(buffer));
}

/**
 * Reads 64 grayscale values from an 8x8 PNG.
 *
 * A minimal decoder for exactly the PNG Cloudinary returns: 8x8, no
 * interlacing, one IDAT stream. `zlib` is built into Node, so this needs no
 * dependency. Anything unexpected throws, and the caller routes to review.
 */
function extractPixels(buffer) {
  const zlib = require('zlib');

  const SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  if (!SIGNATURE.every((byte, i) => buffer[i] === byte)) {
    throw new Error('Hash source is not a PNG.');
  }

  let offset = 8;
  let width = 0;
  let height = 0;
  let colourType = 0;
  let bitDepth = 0;
  const idat = [];

  while (offset < buffer.length) {
    const length = buffer.readUInt32BE(offset);
    const type = buffer.toString('ascii', offset + 4, offset + 8);
    const data = buffer.subarray(offset + 8, offset + 8 + length);

    if (type === 'IHDR') {
      width = data.readUInt32BE(0);
      height = data.readUInt32BE(4);
      bitDepth = data[8];
      colourType = data[9];
      if (data[12] !== 0) throw new Error('Interlaced PNG is not supported.');
    } else if (type === 'IDAT') {
      idat.push(data);
    } else if (type === 'IEND') {
      break;
    }

    offset += 12 + length; // length + type + data + CRC
  }

  if (width !== HASH_SIZE || height !== HASH_SIZE) {
    throw new Error(`Hash source is ${width}x${height}, expected 8x8.`);
  }
  if (bitDepth !== 8) {
    throw new Error(`Unsupported bit depth: ${bitDepth}`);
  }

  // 0 = grayscale, 2 = RGB, 4 = grayscale+alpha, 6 = RGBA. Cloudinary's
  // e_grayscale may still emit RGB, so every channel layout is handled.
  const channels = { 0: 1, 2: 3, 4: 2, 6: 4 }[colourType];
  if (!channels) throw new Error(`Unsupported colour type: ${colourType}`);

  const raw = zlib.inflateSync(Buffer.concat(idat));
  const stride = width * channels;
  const pixels = [];

  for (let y = 0; y < height; y += 1) {
    // Each scanline is prefixed with a filter byte.
    const filter = raw[y * (stride + 1)];
    if (filter !== 0) {
      throw new Error(`Unsupported PNG filter ${filter} on row ${y}.`);
    }
    const start = y * (stride + 1) + 1;
    for (let x = 0; x < width; x += 1) {
      // Grayscale, so the first channel is the value. For RGB the channels are
      // already equal after e_grayscale.
      pixels.push(raw[start + x * channels]);
    }
  }

  return pixels;
}

module.exports = {
  HASH_SIZE,
  PIXEL_COUNT,
  DUPLICATE_THRESHOLD,
  hashSourceUrl,
  averageHash,
  hammingDistance,
  findDuplicate,
  extractPixels,
  hashImage,
};
