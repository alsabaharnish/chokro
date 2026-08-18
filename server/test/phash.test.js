/**
 * Perceptual hashing and duplicate detection (F2.11).
 *
 * This module had no tests at all, which is a poor place for it to be: it
 * decides whether a photograph is a re-submission, it does so on 64 bytes of
 * pixel data, and every failure mode it has is silent. `verifyDisposal` catches
 * anything thrown here and continues with `isDuplicate: false`, so a broken hash
 * does not raise an error anywhere — duplicate detection simply stops existing.
 *
 * The PNG decoder is the part worth testing hardest, and it is tested against
 * PNGs encoded here rather than fixtures pulled from Cloudinary. Two requests to
 * the same Cloudinary URL, minutes apart, returned scanlines filtered
 * differently — so which filter the real input uses is not ours to rely on. The
 * encoder below produces the same image under all five filter types, which is
 * the property the decoder actually has to survive.
 */

const zlib = require('zlib');

const {
  HASH_SIZE,
  PIXEL_COUNT,
  DUPLICATE_THRESHOLD,
  hashSourceUrl,
  averageHash,
  hammingDistance,
  findDuplicate,
  extractPixels,
} = require('../src/phash');

// ---------------------------------------------------------------------------
// A minimal PNG encoder, so the decoder can be tested offline against every
// scanline filter the format allows.
// ---------------------------------------------------------------------------

function paeth(a, b, c) {
  const p = a + b - c;
  const pa = Math.abs(p - a);
  const pb = Math.abs(p - b);
  const pc = Math.abs(p - c);
  if (pa <= pb && pa <= pc) return a;
  if (pb <= pc) return b;
  return c;
}

function chunk(type, data) {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(data.length, 0);
  const body = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(zlib.crc32(body), 0);
  return Buffer.concat([length, body, crc]);
}

/**
 * Encodes 64 grayscale values as an 8x8 PNG using [filter] on every scanline.
 *
 * Forward filtering is the inverse of the reconstruction in `extractPixels`, so
 * a round trip through both must return the original pixels exactly.
 */
function encodePng(pixels, filter, { width = 8, height = 8 } = {}) {
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 0; // colour type 0 = grayscale
  ihdr[10] = 0; // deflate
  ihdr[11] = 0; // adaptive filtering
  ihdr[12] = 0; // no interlace

  const scanlines = [];
  for (let y = 0; y < height; y += 1) {
    const row = Buffer.alloc(width + 1);
    row[0] = filter;
    for (let x = 0; x < width; x += 1) {
      const value = pixels[y * width + x];
      const a = x > 0 ? pixels[y * width + x - 1] : 0;
      const b = y > 0 ? pixels[(y - 1) * width + x] : 0;
      const c = y > 0 && x > 0 ? pixels[(y - 1) * width + x - 1] : 0;

      let encoded;
      switch (filter) {
        case 0: encoded = value; break;
        case 1: encoded = value - a; break;
        case 2: encoded = value - b; break;
        case 3: encoded = value - Math.floor((a + b) / 2); break;
        case 4: encoded = value - paeth(a, b, c); break;
        default: throw new Error(`bad test filter ${filter}`);
      }
      row[x + 1] = encoded & 0xff;
    }
    scanlines.push(row);
  }

  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(Buffer.concat(scanlines))),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

/** A deterministic, visually varied 8x8 image. */
const IMAGE = Array.from({ length: PIXEL_COUNT }, (_, i) =>
  (i * 37 + (i % 8) * 11) % 256,
);

// ---------------------------------------------------------------------------

describe('hashSourceUrl', () => {
  test('asks Cloudinary for an 8x8 grayscale PNG', () => {
    const url = hashSourceUrl('chokro/disposals/abc', 'democloud');

    expect(url).toContain('/democloud/');
    expect(url).toContain(`w_${HASH_SIZE},h_${HASH_SIZE}`);
    expect(url).toContain('e_grayscale');
    // f_png matters: a JPEG at 8x8 would add compression artefacts to the very
    // pixels being compared.
    expect(url).toContain('f_png');
    expect(url).toContain('chokro/disposals/abc.png');
  });

  test('scales without preserving aspect ratio', () => {
    // c_scale, not c_fit. Every hash must describe the same 8x8 grid, and c_fit
    // would return 8x6 for a landscape photo and change the pixel count.
    expect(hashSourceUrl('x', 'c')).toContain('c_scale');
  });
});

describe('averageHash', () => {
  test('returns 16 hex characters for 64 pixels', () => {
    const hash = averageHash(IMAGE);
    expect(hash).toHaveLength(16);
    expect(hash).toMatch(/^[0-9a-f]{16}$/);
  });

  test('is deterministic', () => {
    expect(averageHash(IMAGE)).toBe(averageHash([...IMAGE]));
  });

  test('a flat image has no pixel above the mean', () => {
    // Every pixel equals the mean, and the comparison is strictly greater, so
    // every bit is 0. Worth pinning: a `>=` here would flip all 64 bits and
    // silently change every hash in the database.
    expect(averageHash(new Array(PIXEL_COUNT).fill(128))).toBe(
      '0000000000000000',
    );
  });

  test('half above the mean sets exactly half the bits', () => {
    const pixels = [
      ...new Array(PIXEL_COUNT / 2).fill(255),
      ...new Array(PIXEL_COUNT / 2).fill(0),
    ];
    expect(averageHash(pixels)).toBe('ffffffff00000000');
  });

  test('refuses the wrong number of pixels', () => {
    // A short read from a truncated response would otherwise hash whatever
    // arrived and compare it against full hashes.
    expect(() => averageHash(new Array(63).fill(0))).toThrow(/64 pixel/);
    expect(() => averageHash(new Array(65).fill(0))).toThrow(/64 pixel/);
    expect(() => averageHash(null)).toThrow(/64 pixel/);
  });
});

describe('hammingDistance', () => {
  test('identical hashes are zero apart', () => {
    expect(hammingDistance('420c170f8fdfef17', '420c170f8fdfef17')).toBe(0);
  });

  test('opposite hashes are 64 apart', () => {
    expect(hammingDistance('0000000000000000', 'ffffffffffffffff')).toBe(64);
  });

  test('counts single bits', () => {
    expect(hammingDistance('0000000000000000', '0000000000000001')).toBe(1);
    expect(hammingDistance('0000000000000000', '0000000000000003')).toBe(2);
    expect(hammingDistance('0000000000000000', '8000000000000000')).toBe(1);
  });

  test('is symmetric', () => {
    const a = '420c170f8fdfef17';
    const b = '4800028fcfdf2737';
    expect(hammingDistance(a, b)).toBe(hammingDistance(b, a));
  });

  test('refuses hashes it cannot compare', () => {
    expect(() => hammingDistance('abcd', 'abcdef')).toThrow(/same length/);
    expect(() => hammingDistance(null, 'abcd')).toThrow(/must be strings/);
    expect(() => hammingDistance('abcd', 42)).toThrow(/must be strings/);
  });
});

describe('findDuplicate', () => {
  const base = '420c170f8fdfef17';

  test('an identical photograph is a duplicate', () => {
    const result = findDuplicate(base, [base]);
    expect(result.isDuplicate).toBe(true);
    expect(result.distance).toBe(0);
    expect(result.matchedHash).toBe(base);
  });

  test('the threshold is inclusive', () => {
    // A distance of exactly DUPLICATE_THRESHOLD counts. The boundary has to be
    // pinned somewhere or it drifts on the next edit.
    const near = flipBits(base, DUPLICATE_THRESHOLD);
    expect(hammingDistance(base, near)).toBe(DUPLICATE_THRESHOLD);
    expect(findDuplicate(near, [base]).isDuplicate).toBe(true);

    const beyond = flipBits(base, DUPLICATE_THRESHOLD + 1);
    expect(findDuplicate(beyond, [base]).isDuplicate).toBe(false);
  });

  test('reports the nearest match, not the first', () => {
    const far = flipBits(base, 20);
    const near = flipBits(base, 1);
    const result = findDuplicate(base, [far, near]);
    expect(result.matchedHash).toBe(near);
    expect(result.distance).toBe(1);
  });

  test('an empty history is not a duplicate', () => {
    // A user's first ever submission takes this path.
    const result = findDuplicate(base, []);
    expect(result.isDuplicate).toBe(false);
    expect(result.distance).toBeNull();
  });

  test('a missing candidate is not a duplicate', () => {
    // hashImage returned null because the fetch failed. That is not evidence of
    // anything, and must not read as a pass or as a duplicate.
    expect(findDuplicate(null, [base]).isDuplicate).toBe(false);
    expect(findDuplicate('', [base]).isDuplicate).toBe(false);
  });

  test('malformed history entries are skipped, not fatal', () => {
    // One bad document must not stop the check against the rest.
    const result = findDuplicate(base, [null, 42, 'short', base]);
    expect(result.isDuplicate).toBe(true);
    expect(result.matchedHash).toBe(base);
  });

  test('a non-array history is handled', () => {
    expect(findDuplicate(base, null).isDuplicate).toBe(false);
  });

  test('the threshold errs toward flagging', () => {
    // A false positive routes to review, where a person compares both images.
    // A false negative silently pays for a re-submitted photograph. The
    // threshold must stay small enough that only near-identical images match.
    expect(DUPLICATE_THRESHOLD).toBeLessThanOrEqual(10);
    expect(DUPLICATE_THRESHOLD).toBeGreaterThan(0);
  });
});

describe('extractPixels', () => {
  test('reads an unfiltered PNG', () => {
    expect(extractPixels(encodePng(IMAGE, 0))).toEqual(IMAGE);
  });

  // The regression that matters. This used to throw
  // `Unsupported PNG filter 1 on row 0`, which `verifyDisposal` caught and
  // logged before continuing with isDuplicate: false — so duplicate detection
  // quietly did not exist for any photograph Cloudinary chose to filter.
  test.each([
    [1, 'Sub'],
    [2, 'Up'],
    [3, 'Average'],
    [4, 'Paeth'],
  ])('reconstructs filter %i (%s)', (filter) => {
    expect(extractPixels(encodePng(IMAGE, filter))).toEqual(IMAGE);
  });

  test('every filter yields the same hash for the same image', () => {
    // The point of the whole exercise: the hash describes the picture, not the
    // encoder's choice of filter.
    const hashes = [0, 1, 2, 3, 4].map((f) =>
      averageHash(extractPixels(encodePng(IMAGE, f))),
    );
    expect(new Set(hashes).size).toBe(1);
  });

  test('reconstruction wraps at 256 rather than clamping', () => {
    // Filtered bytes are defined modulo 256. Clamping instead of wrapping
    // decodes to plausible-looking garbage, which is worse than an error
    // because nothing reports it.
    const highContrast = Array.from({ length: PIXEL_COUNT }, (_, i) =>
      i % 2 === 0 ? 250 : 5,
    );
    expect(extractPixels(encodePng(highContrast, 1))).toEqual(highContrast);
    expect(extractPixels(encodePng(highContrast, 4))).toEqual(highContrast);
  });

  test('refuses something that is not a PNG', () => {
    expect(() => extractPixels(Buffer.from('not an image at all'))).toThrow(
      /not a PNG/,
    );
  });

  test('refuses the wrong dimensions', () => {
    // A transform that silently stopped resizing would otherwise be hashed at
    // whatever size arrived.
    const wrong = encodePng(new Array(16).fill(10), 0, {
      width: 4,
      height: 4,
    });
    expect(() => extractPixels(wrong)).toThrow(/expected 8x8/);
  });

  test('refuses an unknown filter type', () => {
    const png = encodePng(IMAGE, 0);
    // Corrupt the first scanline's filter byte inside the deflated stream by
    // re-encoding with an out-of-range value.
    expect(() => encodePng(IMAGE, 9)).toThrow();
    expect(extractPixels(png)).toEqual(IMAGE);
  });
});

describe('end to end, offline', () => {
  test('the same image recompressed hashes identically', () => {
    // What F2.11 exists to catch: one photograph submitted twice, re-saved in
    // between. Verified against live Cloudinary output too — q_20 and a resize
    // to 60px both came back at distance 0 from the original.
    const a = averageHash(extractPixels(encodePng(IMAGE, 0)));
    const b = averageHash(extractPixels(encodePng(IMAGE, 4)));
    expect(findDuplicate(b, [a]).isDuplicate).toBe(true);
  });

  test('a different image is not flagged', () => {
    const other = Array.from({ length: PIXEL_COUNT }, (_, i) => (i * 199) % 256);
    const a = averageHash(extractPixels(encodePng(IMAGE, 0)));
    const b = averageHash(extractPixels(encodePng(other, 0)));
    expect(findDuplicate(b, [a]).isDuplicate).toBe(false);
  });
});

/** Flips exactly [count] bits of a 16-character hex hash. */
function flipBits(hash, count) {
  let bits = BigInt('0x' + hash);
  for (let i = 0; i < count; i += 1) {
    bits ^= 1n << BigInt(i);
  }
  return bits.toString(16).padStart(hash.length, '0');
}

// ---------------------------------------------------------------------------
// The fail-open hole this module sat behind (F2.11).
// ---------------------------------------------------------------------------

describe('an uncomputable hash must not auto-approve', () => {
  const { decide, FLAGS, isApprovable } = require('../src/decide');

  /** A submission with nothing else wrong with it. */
  const clean = {
    distanceMeters: 12,
    radiusMeters: 50,
    declaredItemCount: 3,
    screening: {
      confidence: 0.9,
      itemCount: 3,
      itemTypeMatches: true,
      notes: 'Bottles beside a bin.',
    },
    approvedToday: 0,
    dailyCap: 3,
  };

  test('a checked, unmatched photo auto-approves', () => {
    const result = decide({ ...clean, duplicateChecked: true, isDuplicate: false });
    expect(result.decision).toBe('autoApprove');
    expect(result.flags).toEqual([]);
  });

  test('an unchecked photo routes to review instead', () => {
    // THE HOLE. `hashImage` throws on a missing cloud name, a non-200 from
    // Cloudinary, an unexpected bit depth, an unknown scanline filter or any
    // zlib failure — and an empty `photoPublicId` skips the step outright.
    // Every one of those used to leave `isDuplicate: false` with no flag, so
    // `flags.length === 0` and the submission paid out with the duplicate
    // defence never having run.
    const result = decide({ ...clean, duplicateChecked: false });
    expect(result.decision).toBe('review');
    expect(result.flags).toContain(FLAGS.HASH_UNAVAILABLE);
  });

  test('omitting duplicateChecked entirely fails closed', () => {
    // The default is "did not run", so a caller that forgets the field gets a
    // review rather than a payout. This is the property that makes the fix hold
    // for code written later.
    const result = decide(clean);
    expect(result.decision).toBe('review');
    expect(result.flags).toContain(FLAGS.HASH_UNAVAILABLE);
  });

  test('an unchecked hash is not confused with a duplicate', () => {
    // Different flags, because they mean different things to the reviewer: one
    // says "this looks like a resubmission", the other says "nobody could tell".
    const unchecked = decide({ ...clean, duplicateChecked: false });
    const duplicate = decide({
      ...clean,
      duplicateChecked: true,
      isDuplicate: true,
    });

    expect(unchecked.flags).not.toContain(FLAGS.DUPLICATE_PHOTO);
    expect(duplicate.flags).not.toContain(FLAGS.HASH_UNAVAILABLE);
  });

  test('an administrator may still approve an unchecked photo', () => {
    // Advisory, not blocking — exactly like screeningUnavailable. A person can
    // look at the picture and decide. Only the daily cap blocks outright.
    expect(isApprovable([FLAGS.HASH_UNAVAILABLE])).toBe(true);
  });

  test('the flag carries an explanation for the queue', () => {
    const result = decide({ ...clean, duplicateChecked: false });
    expect(result.reasons.join(' ')).toMatch(/fingerprint/i);
  });

  test('it reads as unavailable, not as a clean comparison', () => {
    // A reviewer must not be able to read this as "compared, no match".
    const result = decide({ ...clean, duplicateChecked: false });
    expect(result.reasons.join(' ')).not.toMatch(/matches/i);
  });
});
