/**
 * Mass stays out of the points path (EPR-27, §6.8).
 *
 * §6.8 is the warning the specification asks the architect to read twice, and
 * this file is the "verify by test" it demands.
 *
 * The coupling it forbids has two consequences, both worth restating because a
 * later change that looks harmless will reintroduce one of them:
 *
 *   It turns the recognition model into a payout oracle, so every weakness in
 *   brand recognition becomes a way to mint points — print a wordmark,
 *   photograph it, repeat.
 *
 *   It gives Champions an incentive to *misstate* what they are disposing of,
 *   which pollutes the very dataset a regulator will audit.
 *
 * The second file-level claim tested here is EPR-16's: a screening outage must
 * degrade attribution, not disposal.
 */

const fs = require('fs');
const path = require('path');

const decide = require('../src/decide');

const SRC = path.resolve(__dirname, '../src');
const read = (name) => fs.readFileSync(path.join(SRC, name), 'utf8');

/**
 * A module's source with its comments removed.
 *
 * The source-level assertions below must read the *code*, not the prose. These
 * files explain at length why they do not touch a wallet or a points field, so
 * a naive substring scan matches the explanation and reports the very thing the
 * explanation is promising — which is how the first version of this test failed
 * on correct code.
 *
 * Strings are left intact, because a collection name in a string literal is
 * exactly what these assertions are looking for.
 */
function readCode(name) {
  return read(name)
    // Block comments first, so a line comment inside one is not left behind.
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .split('\n')
    .map((line) => {
      // Only a comment that starts the line. A `//` inside a string literal —
      // a URL, say — must survive, and these files have no trailing comments
      // on code lines.
      const trimmed = line.trimStart();
      return trimmed.startsWith('//') ? '' : line;
    })
    .join('\n');
}

/** Whether [code] mentions [identifier] as a whole word. */
function mentions(code, identifier) {
  return new RegExp(`\\b${identifier}\\b`).test(code);
}

// ---------------------------------------------------------------------------
// decide() reads exactly the fields it read before
// ---------------------------------------------------------------------------

describe('decide() is untouched by attribution', () => {
  const base = {
    distanceMeters: 4,
    radiusMeters: 50,
    isDuplicate: false,
    duplicateChecked: true,
    photoTrusted: true,
    declarationValid: true,
    locationValid: true,
    declaredItemCount: 2,
    screening: {
      confidence: 0.92,
      itemCount: 2,
      itemTypeMatches: true,
      binVisible: true,
      wasteInBin: true,
      notes: null,
    },
    approvedToday: 0,
    dailyCap: 3,
  };

  test('a clean submission still auto-approves', () => {
    // Appendix A step 4: the disposal auto-approves and credits Anik's points
    // exactly as it does today.
    expect(decide.decide(base).decision).toBe('autoApprove');
    expect(decide.decide(base).flags).toEqual([]);
  });

  test('recognition results in the screening block change nothing', () => {
    // The screening verdict now carries `skuMatches`. If `decide` read it —
    // even incidentally — a producer registering a product would change what a
    // Champion is paid.
    const withMatches = {
      ...base,
      screening: {
        ...base.screening,
        skuMatches: [{ skuId: 'sku_cola', units: 2, confidence: 0.91 }],
      },
    };
    const withNone = {
      ...base,
      screening: { ...base.screening, skuMatches: [] },
    };
    const withNull = {
      ...base,
      screening: { ...base.screening, skuMatches: null },
    };

    const baseline = decide.decide(base);
    for (const [label, input] of [
      ['a high-confidence match', withMatches],
      ['no matches', withNone],
      ['recognition unavailable', withNull],
    ]) {
      expect(decide.decide(input)).toEqual(baseline);
      expect(decide.decide(input).decision).toBe(
        baseline.decision,
        `${label} must not change the decision`,
      );
    }
  });

  test('a flagged submission stays flagged whatever recognition said', () => {
    const flagged = { ...base, distanceMeters: 400 };
    const flaggedWithMatches = {
      ...flagged,
      screening: {
        ...base.screening,
        skuMatches: [{ skuId: 'sku_cola', units: 99, confidence: 1 }],
      },
    };

    expect(decide.decide(flaggedWithMatches)).toEqual(decide.decide(flagged));
    expect(decide.decide(flaggedWithMatches).decision).toBe('review');
  });

  test('the flag vocabulary gained nothing', () => {
    // A new flag would be a new reason a disposal could be routed to review,
    // and attribution must never be one.
    expect(Object.values(decide.FLAGS).sort()).toEqual(
      [
        'dailyCapReached',
        'duplicatePhoto',
        'countMismatch',
        'hashUnavailable',
        'invalidDeclaration',
        'invalidLocation',
        'itemTypeMismatch',
        'lowConfidence',
        'noBinVisible',
        'outsideRadius',
        'photoUntrusted',
        'screeningUnavailable',
        'wasteNotInBin',
      ].sort(),
    );
  });
});

// ---------------------------------------------------------------------------
// The source-level guarantee
// ---------------------------------------------------------------------------

describe('the attribution path cannot reach the points path', () => {
  test('decide.js imports nothing from the EPR feature', () => {
    const source = readCode('decide.js');
    for (const forbidden of [
      'attribute',
      'producerSkus',
      'eprPolicy',
      'eprPeriod',
      'skuShortlist',
      'skuMatches',
    ]) {
      expect(source).not.toContain(forbidden);
    }
  });

  test('attribute.js writes to no collection that decides a payout', () => {
    // A wallet balance, a ledger entry, the daily cap counter and the per-bin
    // lockout are the four things that decide or record a payout. Attribution
    // names none of them.
    const source = readCode('attribute.js');
    for (const collection of [
      "'wallets'",
      "'transactions'",
      "'dailyCaps'",
      "'lockouts'",
      "'stats'",
    ]) {
      expect(source).not.toContain(collection);
    }
  });

  test('attribute.js does not require the award or decision modules', () => {
    const source = readCode('attribute.js');
    expect(source).not.toContain("require('./award')");
    expect(source).not.toContain("require('./decide')");
    expect(source).not.toContain("require('./pointsPolicy')");
  });

  test('attribute.js never writes a points field', () => {
    const source = readCode('attribute.js');
    for (const field of [
      'pointsAwarded',
      'balanceAfter',
      'pointsIssued',
      'walletRef',
    ]) {
      expect(mentions(source, field)).toBe(false);
    }
  });

  test('the disposal update names only the EPR-6 server-owned fields', () => {
    // EPR-6: `disposals` gains these server-only fields "and nothing else".
    const source = readCode('attribute.js');
    const start = source.indexOf('txn.update(disposalRef, {');
    expect(start).toBeGreaterThan(0);
    const updateBlock = source.slice(start, source.indexOf('});', start));

    for (const expected of [
      'attributionStatus',
      'skuMatchCount',
      'attributedMassGrams',
      'gazetteCategoryResolved',
    ]) {
      expect(mentions(updateBlock, expected)).toBe(true);
    }

    // And nothing that decides or records a payout, or that could move the
    // disposal out of the state the decision put it in.
    for (const forbidden of [
      'pointsAwarded',
      'flags',
      'reviewedBy',
      'reviewedAt',
    ]) {
      expect(mentions(updateBlock, forbidden)).toBe(false);
    }

    // `status` itself, as its own field — `attributionStatus` is a different
    // field and is expected. Re-writing `status` here could resurrect a
    // rejected disposal.
    expect(/(^|[^A-Za-z])status\s*:/.test(updateBlock)).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// EPR-16: attribution failure degrades attribution, not disposal
// ---------------------------------------------------------------------------

describe('the approval path survives every attribution outcome', () => {
  test('the hook runs after the commit, not inside the transaction', () => {
    // "AFTER the commit, never inside it. Firestore retries a transaction body
    // on contention, so a send inside one fires once per attempt." The same
    // reasoning that puts the push notification outside puts this outside.
    const source = read('award.js');
    const commitIndex = source.indexOf('return {\n      disposalId,\n      userId: uid,');
    const hookIndex = source.indexOf('attributeModule.attributeDisposal');

    expect(commitIndex).toBeGreaterThan(0);
    expect(hookIndex).toBeGreaterThan(commitIndex);
  });

  test('nothing the hook returns is used', () => {
    // If a caller's response depended on the attribution outcome, an
    // attribution failure would become a visible submission failure.
    const source = readCode('award.js');
    const hookIndex = source.indexOf('attributeModule.attributeDisposal');
    expect(hookIndex).toBeGreaterThan(0);

    // Only to the end of `approveDisposal`, not the rest of the file —
    // `rejectDisposal` follows it and legitimately throws.
    const tail = source.slice(hookIndex, source.indexOf('return result;', hookIndex));

    // The only use of the outcome is a log line naming it.
    expect(tail).toContain('console.warn');
    expect(mentions(tail, 'throw')).toBe(false);
    expect(mentions(tail, 'pointsAwarded')).toBe(false);
    // And the function still returns the transaction's own result.
    expect(source.slice(hookIndex)).toContain('return result;');
  });

  test('attributeDisposal cannot throw into its caller', async () => {
    // Every failure comes back as an outcome string. Proven by calling it with
    // no Firebase configured at all, which is the harshest failure available.
    jest.resetModules();
    jest.doMock('../src/firebase', () => ({
      db: () => {
        throw new Error('Firestore is unreachable');
      },
      admin: { firestore: { FieldValue: {}, Timestamp: {} } },
      serverTimestamp: () => null,
    }));

    const isolated = require('../src/attribute');
    const previous = process.env.EPR_ATTRIBUTION_ENABLED;
    process.env.EPR_ATTRIBUTION_ENABLED = 'true';
    const errorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

    await expect(
      isolated.attributeDisposal({ disposalId: 'disposal_1' }),
    ).resolves.toMatchObject({ outcome: 'failed' });

    errorSpy.mockRestore();
    if (previous === undefined) {
      delete process.env.EPR_ATTRIBUTION_ENABLED;
    } else {
      process.env.EPR_ATTRIBUTION_ENABLED = previous;
    }
    jest.dontMock('../src/firebase');
    jest.resetModules();
  });
});

// ---------------------------------------------------------------------------
// The flag the sequencing note asks for
// ---------------------------------------------------------------------------

describe('the feature flag (§14 sequencing note)', () => {
  const previous = process.env.EPR_ATTRIBUTION_ENABLED;

  afterEach(() => {
    if (previous === undefined) {
      delete process.env.EPR_ATTRIBUTION_ENABLED;
    } else {
      process.env.EPR_ATTRIBUTION_ENABLED = previous;
    }
  });

  test('off by default, so the disposal path behaves as it did', () => {
    delete process.env.EPR_ATTRIBUTION_ENABLED;
    const attribute = require('../src/attribute');
    expect(attribute.isEnabled()).toBe(false);
  });

  test('a disabled attribution does nothing and says so', async () => {
    delete process.env.EPR_ATTRIBUTION_ENABLED;
    const attribute = require('../src/attribute');
    await expect(
      attribute.attributeDisposal({ disposalId: 'anything' }),
    ).resolves.toEqual({ outcome: 'disabled' });
  });

  test('only the exact string enables it', () => {
    const attribute = require('../src/attribute');
    for (const value of ['1', 'yes', 'TRUE', 'on', '']) {
      process.env.EPR_ATTRIBUTION_ENABLED = value;
      expect(attribute.isEnabled()).toBe(false);
    }
    process.env.EPR_ATTRIBUTION_ENABLED = 'true';
    expect(attribute.isEnabled()).toBe(true);
  });

  test('with it off, verification sends the prompt it always sent', () => {
    // The shortlist is only built when attribution is enabled, and an empty
    // shortlist produces a byte-identical prompt.
    const screen = require('../src/screen');
    expect(screen.buildPrompt('plasticBottle', 2)).toBe(
      screen.buildPrompt('plasticBottle', 2, []),
    );
    expect(screen.buildPrompt('plasticBottle', 2, [])).not.toContain('skuMatches');
  });
});
