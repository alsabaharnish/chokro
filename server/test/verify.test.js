/**
 * Pure unit tests for the verification pipeline (F2.11, F2.12).
 *
 * Everything here runs without Firebase, without a network and without an image
 * — which is why `averageHash`, `decide` and `parseVerdict` are written as
 * separate functions from the I/O that feeds them.
 */

const {
  averageHash,
  hammingDistance,
  findDuplicate,
  hashSourceUrl,
  DUPLICATE_THRESHOLD,
  PIXEL_COUNT,
} = require('../src/phash');

const {
  decide,
  isApprovable,
  explain,
  FLAGS,
  CONFIDENCE_THRESHOLD,
} = require('../src/decide');

const { parseVerdict, buildPrompt, isConfigured } = require('../src/screen');

// ---------------------------------------------------------------------------
// Hashing
// ---------------------------------------------------------------------------

/** 64 pixels: the first `bright` of them above the mean. */
function pixels(bright) {
  return Array.from({ length: PIXEL_COUNT }, (_, i) => (i < bright ? 255 : 0));
}

describe('averageHash', () => {
  test('produces 16 hex characters — 64 bits', () => {
    const hash = averageHash(pixels(32));
    expect(hash).toMatch(/^[0-9a-f]{16}$/);
  });

  test('is deterministic', () => {
    expect(averageHash(pixels(20))).toBe(averageHash(pixels(20)));
  });

  test('a uniform image hashes to all zeros', () => {
    // No pixel exceeds the mean when every pixel is the mean.
    expect(averageHash(Array(PIXEL_COUNT).fill(128))).toBe('0'.repeat(16));
  });

  test('different images hash differently', () => {
    expect(averageHash(pixels(10))).not.toBe(averageHash(pixels(50)));
  });

  test('rejects the wrong number of pixels', () => {
    expect(() => averageHash([1, 2, 3])).toThrow();
    expect(() => averageHash(null)).toThrow();
  });

  test('brightness shifts do not change the hash', () => {
    // The property that makes this perceptual: the comparison is against the
    // image's own mean, so uniformly brightening it changes nothing.
    const base = pixels(32);
    const brighter = base.map((p) => Math.min(255, p + 40));
    expect(averageHash(brighter)).toBe(averageHash(base));
  });
});

describe('hammingDistance', () => {
  test('identical hashes are distance 0', () => {
    expect(hammingDistance('abcd1234abcd1234', 'abcd1234abcd1234')).toBe(0);
  });

  test('counts differing bits', () => {
    expect(hammingDistance('0', '1')).toBe(1);
    expect(hammingDistance('0', 'f')).toBe(4);
    expect(hammingDistance('00', 'ff')).toBe(8);
  });

  test('refuses mismatched lengths', () => {
    expect(() => hammingDistance('abcd', 'ab')).toThrow();
  });
});

describe('findDuplicate', () => {
  const hash = averageHash(pixels(32));

  test('an empty history is never a duplicate', () => {
    expect(findDuplicate(hash, []).isDuplicate).toBe(false);
  });

  test('an identical hash is a duplicate', () => {
    const result = findDuplicate(hash, ['0000000000000000', hash]);
    expect(result.isDuplicate).toBe(true);
    expect(result.distance).toBe(0);
  });

  test('a distant hash is not a duplicate', () => {
    const other = averageHash(pixels(4));
    const result = findDuplicate(hash, [other]);
    expect(result.distance).toBeGreaterThan(DUPLICATE_THRESHOLD);
    expect(result.isDuplicate).toBe(false);
  });

  test('a near-identical hash inside the threshold is a duplicate', () => {
    // One bit different.
    const near = `${hash.slice(0, 15)}${(parseInt(hash[15], 16) ^ 1).toString(16)}`;
    const result = findDuplicate(hash, [near]);
    expect(result.distance).toBe(1);
    expect(result.isDuplicate).toBe(true);
  });

  test('ignores malformed entries in the history', () => {
    expect(() => findDuplicate(hash, [null, 42, 'short'])).not.toThrow();
    expect(findDuplicate(hash, [null, 42, 'short']).isDuplicate).toBe(false);
  });
});

describe('hashSourceUrl', () => {
  test('requests an 8x8 grayscale PNG', () => {
    const url = hashSourceUrl('chokro/disposals/u1/abc', 'demo');
    expect(url).toContain('w_8');
    expect(url).toContain('h_8');
    expect(url).toContain('e_grayscale');
    expect(url).toContain('f_png');
  });
});

// ---------------------------------------------------------------------------
// The decision
// ---------------------------------------------------------------------------

describe('decide', () => {
  const clean = {
    distanceMeters: 12,
    radiusMeters: 50,
    isDuplicate: false,
    declaredItemCount: 3,
    screening: {
      confidence: 0.9,
      itemCount: 3,
      itemTypeMatches: true,
      notes: 'Bottles visible beside a bin.',
    },
    approvedToday: 0,
    dailyCap: 3,
  };

  test('every check passing auto-approves', () => {
    const result = decide(clean);
    expect(result.decision).toBe('autoApprove');
    expect(result.flags).toEqual([]);
  });

  test('outside the radius routes to review', () => {
    const result = decide({ ...clean, distanceMeters: 80 });
    expect(result.decision).toBe('review');
    expect(result.flags).toContain(FLAGS.OUTSIDE_RADIUS);
  });

  test('exactly on the radius still passes', () => {
    expect(decide({ ...clean, distanceMeters: 50 }).decision).toBe('autoApprove');
  });

  test('a duplicate photo routes to review', () => {
    const result = decide({ ...clean, isDuplicate: true });
    expect(result.flags).toContain(FLAGS.DUPLICATE_PHOTO);
  });

  test('missing screening routes to review, never approves', () => {
    // The most important test in this file. An outage must not become a
    // silent auto-approve of everything.
    const result = decide({ ...clean, screening: null });
    expect(result.decision).toBe('review');
    expect(result.flags).toContain(FLAGS.SCREENING_UNAVAILABLE);
  });

  test('low confidence routes to review', () => {
    const result = decide({
      ...clean,
      screening: { ...clean.screening, confidence: CONFIDENCE_THRESHOLD - 0.01 },
    });
    expect(result.flags).toContain(FLAGS.LOW_CONFIDENCE);
  });

  test('a count mismatch flags but does not reject', () => {
    const result = decide({
      ...clean,
      screening: { ...clean.screening, itemCount: 7 },
    });
    expect(result.decision).toBe('review');
    expect(result.flags).toContain(FLAGS.COUNT_MISMATCH);
  });

  test('a screen that cannot count does not raise a mismatch', () => {
    const result = decide({
      ...clean,
      screening: { ...clean.screening, itemCount: null },
    });
    expect(result.flags).not.toContain(FLAGS.COUNT_MISMATCH);
    expect(result.decision).toBe('autoApprove');
  });

  test('an item type mismatch routes to review', () => {
    const result = decide({
      ...clean,
      screening: { ...clean.screening, itemTypeMatches: false },
    });
    expect(result.flags).toContain(FLAGS.ITEM_TYPE_MISMATCH);
  });

  test('the daily cap flags', () => {
    const result = decide({ ...clean, approvedToday: 3, dailyCap: 3 });
    expect(result.flags).toContain(FLAGS.DAILY_CAP_REACHED);
  });

  test('several problems produce several flags', () => {
    const result = decide({
      ...clean,
      distanceMeters: 500,
      isDuplicate: true,
      screening: null,
    });
    expect(result.flags.length).toBeGreaterThanOrEqual(3);
    expect(result.decision).toBe('review');
  });

  test('a non-numeric distance routes to review rather than passing', () => {
    expect(decide({ ...clean, distanceMeters: NaN }).decision).toBe('review');
    expect(decide({ ...clean, distanceMeters: undefined }).decision).toBe(
      'review',
    );
  });

  test('every flag carries an explanation for the reviewer', () => {
    const result = decide({
      ...clean,
      distanceMeters: 999,
      isDuplicate: true,
      screening: null,
    });
    expect(result.reasons).toHaveLength(result.flags.length);
    for (const reason of result.reasons) {
      expect(reason.length).toBeGreaterThan(10);
    }
  });
});

describe('isApprovable', () => {
  test('advisory flags may be overridden by a person', () => {
    expect(isApprovable([FLAGS.LOW_CONFIDENCE, FLAGS.COUNT_MISMATCH])).toBe(true);
    expect(isApprovable([FLAGS.OUTSIDE_RADIUS])).toBe(true);
  });

  test('the daily cap may not be overridden', () => {
    // Approving past the cap breaches the policy regardless of who asks, and
    // award.js throws on it, so the UI must not offer the button.
    expect(isApprovable([FLAGS.DAILY_CAP_REACHED])).toBe(false);
  });

  test('no flags is approvable', () => {
    expect(isApprovable([])).toBe(true);
  });
});

describe('explain', () => {
  test('returns a sentence for a known flag', () => {
    expect(explain(FLAGS.OUTSIDE_RADIUS)).toContain('radius');
  });

  test('falls back to the flag name for an unknown one', () => {
    expect(explain('somethingNew')).toBe('somethingNew');
  });
});

// ---------------------------------------------------------------------------
// Screening
// ---------------------------------------------------------------------------

describe('parseVerdict', () => {
  test('parses a bare JSON object', () => {
    const verdict = parseVerdict(
      '{"confidence":0.9,"itemCount":3,"itemTypeMatches":true,"notes":"ok"}',
    );
    expect(verdict.confidence).toBe(0.9);
    expect(verdict.itemCount).toBe(3);
    expect(verdict.itemTypeMatches).toBe(true);
  });

  test('tolerates a markdown fence', () => {
    const verdict = parseVerdict(
      '```json\n{"confidence":0.8,"itemCount":2,"itemTypeMatches":true}\n```',
    );
    expect(verdict.confidence).toBe(0.8);
  });

  test('tolerates commentary around the object', () => {
    const verdict = parseVerdict(
      'Here is my analysis: {"confidence":0.7,"itemTypeMatches":false} Hope that helps.',
    );
    expect(verdict.confidence).toBe(0.7);
    expect(verdict.itemTypeMatches).toBe(false);
  });

  test('returns null for unparseable text — never a default approval', () => {
    expect(parseVerdict('I cannot analyse this image.')).toBeNull();
    expect(parseVerdict('')).toBeNull();
    expect(parseVerdict(null)).toBeNull();
    expect(parseVerdict('{broken json')).toBeNull();
  });

  test('rejects a confidence outside 0-1', () => {
    expect(parseVerdict('{"confidence":1.5}')).toBeNull();
    expect(parseVerdict('{"confidence":-0.2}')).toBeNull();
    expect(parseVerdict('{"itemCount":3}')).toBeNull();
  });

  test('itemTypeMatches defaults to false when absent', () => {
    // Absent is not agreement.
    expect(parseVerdict('{"confidence":0.9}').itemTypeMatches).toBe(false);
  });

  test('truncates overlong notes', () => {
    const long = 'x'.repeat(500);
    const verdict = parseVerdict(
      JSON.stringify({ confidence: 0.9, notes: long }),
    );
    expect(verdict.notes.length).toBeLessThanOrEqual(300);
  });
});

describe('buildPrompt', () => {
  test('names the declared type in words', () => {
    expect(buildPrompt('plasticBottles', 3)).toContain('plastic bottles');
    expect(buildPrompt('plasticBottles', 3)).toContain('3');
  });

  test('falls back to the raw key for an unknown type', () => {
    expect(buildPrompt('somethingNew', 1)).toContain('somethingNew');
  });

  test('does not ask the model whether to approve', () => {
    // The model reports what it sees; decide() owns the decision. Handing the
    // approval question to the model would put a payout decision somewhere
    // that cannot be tested deterministically.
    const prompt = buildPrompt('glass', 2).toLowerCase();
    expect(prompt).not.toContain('should this be approved');
    expect(prompt).not.toContain('approve');
  });
});

describe('isConfigured', () => {
  test('reports whether a key is present', () => {
    const original = process.env.GROQ_API_KEY;
    delete process.env.GROQ_API_KEY;
    expect(isConfigured()).toBe(false);
    process.env.GROQ_API_KEY = 'test-key';
    expect(isConfigured()).toBe(true);
    if (original === undefined) delete process.env.GROQ_API_KEY;
    else process.env.GROQ_API_KEY = original;
  });
});
