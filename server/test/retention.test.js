/**
 * The retention schedule (SEC-13).
 *
 * Every test here is about ABSENCE behaving correctly. The module's whole
 * claim is that an unset duration is loud, is never approximated, and never
 * renders the same as "nothing to do" — so that is what gets tested.
 */

jest.mock('../src/firebase', () => ({
  db: jest.fn(),
  serverTimestamp: jest.fn(() => '__TS__'),
}));

const fs = require('fs');
const path = require('path');
const firebase = require('../src/firebase');
const retention = require('../src/retention');

function scheduleDoc(data) {
  return {
    collection: () => ({
      doc: () => ({
        get: jest.fn().mockResolvedValue({
          exists: data !== undefined,
          data: () => data,
        }),
      }),
    }),
  };
}

beforeEach(() => jest.clearAllMocks());

// ---------------------------------------------------------------------------

describe('the schedule is complete and well-formed', () => {
  test('every entry names a class, a disposition and an erasure outcome', () => {
    for (const entry of retention.SCHEDULE) {
      expect(Object.values(retention.CLASSES)).toContain(entry.class);
      expect(Object.values(retention.DISPOSITIONS)).toContain(entry.disposition);
      expect(Object.values(retention.ERASURE)).toContain(entry.erasure);
      expect(typeof entry.why).toBe('string');
      expect(entry.why.length).toBeGreaterThan(20);
    }
  });

  test('no entry ships with a duration', () => {
    // The point of the module. A default here would be an engineering answer
    // to a question SEC-13 assigns to counsel.
    for (const entry of retention.SCHEDULE) {
      expect(entry.months).toBeNull();
    }
  });

  test('every expiring entry names the field its clock runs from', () => {
    // A duration with nothing to subtract it from is how a retention rule
    // quietly becomes "whenever someone remembers".
    for (const entry of retention.SCHEDULE) {
      if (entry.disposition === retention.DISPOSITIONS.retain) continue;
      expect(entry.basis).toBeTruthy();
    }
  });

  test('no collection is listed twice', () => {
    const names = retention.SCHEDULE.map((e) => e.collection);
    expect(new Set(names).size).toBe(names.length);
  });

  test('the collections the server actually touches are all classified', () => {
    // Comments are stripped before scanning. Three separate times in this
    // codebase a source-scanning test has matched the scanner's own prose.
    const dir = path.join(__dirname, '..', 'src');
    const found = new Set();

    for (const file of fs.readdirSync(dir)) {
      if (!file.endsWith('.js')) continue;
      const source = fs
        .readFileSync(path.join(dir, file), 'utf8')
        .replace(/\/\*[\s\S]*?\*\//g, '')
        .replace(/\/\/.*$/gm, '');

      for (const match of source.matchAll(/\.collection\(\s*'([a-zA-Z]+)'\s*\)/g)) {
        found.add(match[1]);
      }
    }

    const classified = new Set(retention.SCHEDULE.map((e) => e.collection));
    const unclassified = [...found].filter((c) => !classified.has(c));

    // `config`, `platform` and `stats` hold no personal data and no compliance
    // record — settings documents and counters. Named explicitly rather than
    // pattern-excluded, so adding a collection cannot slip through by
    // resembling one of them.
    const outOfScope = ['config', 'platform', 'stats'];
    expect(unclassified.filter((c) => !outOfScope.includes(c))).toEqual([]);
  });
});

// ---------------------------------------------------------------------------

describe('a malformed stored duration is treated as unset, never coerced', () => {
  test.each([
    ['a string', '36'],
    ['a fraction', 36.5],
    ['zero', 0],
    ['negative', -1],
    ['beyond a century', 1201],
    ['NaN', NaN],
    ['null', null],
    ['undefined', undefined],
  ])('%s reads as null', (_label, value) => {
    expect(retention.readMonths(value)).toBeNull();
  });

  test('a plain integer inside the bounds is accepted', () => {
    expect(retention.readMonths(36)).toBe(36);
    expect(retention.readMonths(1)).toBe(1);
    expect(retention.readMonths(1200)).toBe(1200);
  });
});

// ---------------------------------------------------------------------------

describe('what is still missing is reported by name', () => {
  test('with nothing configured, every expiring collection is pending', async () => {
    firebase.db.mockReturnValue(scheduleDoc(undefined));

    const pending = await retention.pendingDeterminations();
    const expiring = retention.SCHEDULE.filter(
      (e) => e.disposition !== retention.DISPOSITIONS.retain,
    );

    expect(pending).toHaveLength(expiring.length);
    expect(pending.map((p) => p.collection)).toContain('disposals');
  });

  test('entries that never expire are not reported as missing', async () => {
    firebase.db.mockReturnValue(scheduleDoc(undefined));

    const pending = await retention.pendingDeterminations();
    // An outstanding list that can never empty is one an operator learns to
    // ignore.
    expect(pending.map((p) => p.collection)).not.toContain('plasticPassports');
    expect(pending.map((p) => p.collection)).not.toContain('producerAuditLog');
  });

  test('assertConfigured throws and names the collections', async () => {
    firebase.db.mockReturnValue(scheduleDoc({ months: { disposals: 36 } }));

    await expect(retention.assertConfigured()).rejects.toThrow(/attributions/);
    await expect(retention.assertConfigured()).rejects.toMatchObject({
      code: 'retention_unconfigured',
    });
  });

  test('assertConfigured passes once every expiring collection has a duration', async () => {
    const months = {};
    for (const entry of retention.SCHEDULE) {
      if (entry.disposition !== retention.DISPOSITIONS.retain) {
        months[entry.collection] = 36;
      }
    }
    firebase.db.mockReturnValue(scheduleDoc({ months }));

    await expect(retention.assertConfigured()).resolves.toBe(true);
  });

  test('a read failure is not reported as "nothing configured"', async () => {
    firebase.db.mockReturnValue({
      collection: () => ({
        doc: () => ({ get: jest.fn().mockRejectedValue(new Error('offline')) }),
      }),
    });

    await expect(retention.loadSchedule()).rejects.toThrow(
      'retention_schedule_unavailable',
    );
  });
});

// ---------------------------------------------------------------------------

describe('the cutoff', () => {
  const march31 = new Date('2026-03-31T00:00:00.000Z');

  test('an unconfigured collection throws rather than returning null', () => {
    // A null cutoff compared against a timestamp is `false`, so returning one
    // would make an unconfigured collection look like an empty one.
    expect(() =>
      retention.cutoffFor({ collection: 'attributions', months: null }, march31),
    ).toThrow(/not configured/);
  });

  test('a never-expiring collection has no cutoff and does not throw', () => {
    expect(
      retention.cutoffFor(
        {
          collection: 'plasticPassports',
          months: null,
          disposition: retention.DISPOSITIONS.retain,
        },
        march31,
      ),
    ).toBeNull();
  });

  test('month arithmetic rolls over rather than counting 30-day months', () => {
    const cutoff = retention.cutoffFor(
      { collection: 'x', months: 1, disposition: 'purge' },
      march31,
    );
    // 31 March minus one month is not 1 March. JavaScript lands on 3 March,
    // which is the documented rollover — the point of the test is that it is
    // calendar arithmetic and not `now - 30 * 86400000`.
    expect(cutoff.getUTCMonth()).toBe(2);
    expect(cutoff.toISOString()).not.toBe('2026-03-01T00:00:00.000Z');
  });

  test('three years back lands on the same day three years earlier', () => {
    const cutoff = retention.cutoffFor(
      { collection: 'x', months: 36, disposition: 'purge' },
      new Date('2026-09-16T00:00:00.000Z'),
    );
    expect(cutoff.toISOString()).toBe('2023-09-16T00:00:00.000Z');
  });
});

// ---------------------------------------------------------------------------

describe('planExpiry plans and does not delete', () => {
  function dbWithCount(count) {
    return {
      collection: (name) => {
        if (name === 'config') {
          return {
            doc: () => ({
              get: jest.fn().mockResolvedValue({
                exists: true,
                data: () => ({ months: { attributions: 36 } }),
              }),
            }),
          };
        }
        return {
          where: () => ({
            count: () => ({
              get: jest.fn().mockResolvedValue({ data: () => ({ count }) }),
            }),
          }),
        };
      },
    };
  }

  test('it says, in the result, that it executed nothing', async () => {
    firebase.db.mockReturnValue(dbWithCount(7));

    const result = await retention.planExpiry({
      now: new Date('2026-09-16T00:00:00.000Z'),
      collections: ['attributions'],
    });

    expect(result.executed).toBe(false);
    expect(result.executorImplemented).toBe(false);
  });

  test('an unconfigured collection reports `unconfigured`, not a count of zero', async () => {
    firebase.db.mockReturnValue(dbWithCount(7));

    const result = await retention.planExpiry({
      now: new Date('2026-09-16T00:00:00.000Z'),
      collections: ['claims'],
    });

    const row = result.plan[0];
    expect(row.status).toBe('unconfigured');
    // The distinction the whole module rests on.
    expect(row.dueCount).toBeNull();
    expect(row.dueCount).not.toBe(0);
  });

  test('a never-expiring collection reports `neverExpires`', async () => {
    firebase.db.mockReturnValue(dbWithCount(7));

    const result = await retention.planExpiry({
      now: new Date('2026-09-16T00:00:00.000Z'),
      collections: ['plasticPassports'],
    });

    expect(result.plan[0].status).toBe('neverExpires');
  });

  test('a configured collection reports its count and its cutoff', async () => {
    firebase.db.mockReturnValue(dbWithCount(7));

    const result = await retention.planExpiry({
      now: new Date('2026-09-16T00:00:00.000Z'),
      collections: ['attributions'],
    });

    expect(result.plan[0]).toMatchObject({
      collection: 'attributions',
      status: 'planned',
      dueCount: 7,
      months: 36,
      cutoff: '2023-09-16T00:00:00.000Z',
    });
  });

  test('a collection it cannot count says so rather than counting zero', async () => {
    firebase.db.mockReturnValue({
      collection: (name) => {
        if (name === 'config') {
          return {
            doc: () => ({
              get: jest.fn().mockResolvedValue({
                exists: true,
                data: () => ({ months: { attributions: 36 } }),
              }),
            }),
          };
        }
        return {
          where: () => ({
            count: () => ({
              get: jest.fn().mockRejectedValue(new Error('no index')),
            }),
          }),
        };
      },
    });

    const result = await retention.planExpiry({
      now: new Date('2026-09-16T00:00:00.000Z'),
      collections: ['attributions'],
    });

    expect(result.plan[0].status).toBe('uncountable');
    expect(result.plan[0].dueCount).toBeNull();
  });

  test('it refuses to run without an explicit clock', async () => {
    firebase.db.mockReturnValue(dbWithCount(0));
    await expect(retention.planExpiry({})).rejects.toThrow(/explicit/);
  });

  test('the module exports no executor', () => {
    // If one is ever added, this test should be deleted deliberately and
    // replaced by tests of what it deletes — not quietly allowed to pass.
    expect(retention.execute).toBeUndefined();
    expect(retention.runExpiry).toBeUndefined();
    expect(retention.deleteExpired).toBeUndefined();
  });
});

// ---------------------------------------------------------------------------

describe('erasureImpact measures the collision', () => {
  function dbFor({ disposals, attributions, passports }) {
    return {
      collection: (name) => {
        if (name === 'disposals') {
          return {
            where: () => ({
              limit: () => ({
                get: jest.fn().mockResolvedValue({
                  size: disposals.length,
                  docs: disposals.map((id) => ({ id, data: () => ({}) })),
                }),
              }),
            }),
          };
        }
        if (name === 'attributions') {
          return {
            where: () => ({
              get: jest.fn().mockResolvedValue({
                docs: attributions.map((a) => ({ id: a.id, data: () => a })),
              }),
            }),
          };
        }
        if (name === 'plasticPassports') {
          return {
            where: () => ({
              where: () => ({
                get: jest.fn().mockResolvedValue({
                  docs: passports.map((p) => ({ id: p.serial, data: () => p })),
                }),
              }),
            }),
          };
        }
        throw new Error(`unexpected collection ${name}`);
      },
    };
  }

  test('it totals the mass a Champion contributed to each issued certificate', async () => {
    firebase.db.mockReturnValue(
      dbFor({
        disposals: ['d1', 'd2'],
        attributions: [
          { id: 'a1', disposalId: 'd1', orgId: 'org1', periodId: '2026-03', massMg: 21000 },
          { id: 'a2', disposalId: 'd2', orgId: 'org1', periodId: '2026-03', massMg: 19000 },
        ],
        passports: [{ serial: 'CHKR-PP-AAAA-BBBB', status: 'issued' }],
      }),
    );

    const impact = await retention.erasureImpact('champion-1');

    expect(impact.disposals).toBe(2);
    expect(impact.attributions).toBe(2);
    expect(impact.contributedMassMg).toBe(40000);
    expect(impact.organizations).toEqual(['org1']);
    expect(impact.certificates).toEqual([
      {
        serial: 'CHKR-PP-AAAA-BBBB',
        orgId: 'org1',
        periodId: '2026-03',
        status: 'issued',
        contributedMassMg: 40000,
      },
    ]);
  });

  test('it never states a resolution', async () => {
    firebase.db.mockReturnValue(
      dbFor({ disposals: [], attributions: [], passports: [] }),
    );

    const impact = await retention.erasureImpact('champion-1');
    // Reporting a collision is not the same as resolving it, and a screen
    // rendering this must not read as a decision Chokro has taken.
    expect(impact.resolution).toBe('undetermined');
    expect(impact.resolutionNote).toMatch(/decision 9/);
  });

  test('a truncated scan says so rather than under-reporting the collision', async () => {
    firebase.db.mockReturnValue(
      dbFor({
        disposals: ['d1', 'd2', 'd3'],
        attributions: [],
        passports: [],
      }),
    );

    const impact = await retention.erasureImpact('champion-1', { limit: 2 });
    expect(impact.truncated).toBe(true);
    expect(impact.disposals).toBe(2);
  });

  test('it refuses an empty uid', async () => {
    await expect(retention.erasureImpact('')).rejects.toThrow(/uid/);
  });
});

// ---------------------------------------------------------------------------

describe('the data-flow map stays true (SEC-3, SEC-13)', () => {
  /**
   * `docs/DATA_FLOW_MAP.md` §3 makes one absolute claim: no producer-facing
   * route returns a Champion identifier. A document asserting that is worth
   * much less than a test enforcing it, because the document cannot fail when
   * someone adds a route.
   */
  test('no producer-guarded route handler touches a Champion identifier', () => {
    const source = fs
      .readFileSync(path.join(__dirname, '..', 'src', 'index.js'), 'utf8')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/\/\/.*$/gm, '');

    const blocks = source.split(/(?=app\.(?:get|post|put|patch|delete)\()/);
    const offenders = [];
    let producerRoutes = 0;

    for (const block of blocks) {
      const match = block.match(
        /app\.(get|post|put|patch|delete)\(\s*\n?\s*'([^']+)'/,
      );
      if (!match) continue;

      const [, method, routePath] = match;
      if (!routePath.startsWith('/epr/')) continue;
      if (routePath.startsWith('/epr/admin/')) continue;

      const head = block.slice(0, 400);
      if (!/requireOrgRole|requireProducer/.test(head)) continue;
      producerRoutes += 1;

      // `:uid` in a members route is an ORG MEMBER's uid — the producer's own
      // staff, documented in the map §3.3. A Champion identifier is one of
      // these field names appearing in the handler body.
      for (const field of ['userId', 'championUid', 'championName', 'championEmail']) {
        if (new RegExp(`\\b${field}\\b`).test(block)) {
          offenders.push(`${method.toUpperCase()} ${routePath} → ${field}`);
        }
      }
    }

    // Guards the guard: if the block-splitting regex ever stops matching, this
    // test would pass vacuously on zero routes.
    expect(producerRoutes).toBeGreaterThan(20);
    expect(offenders).toEqual([]);
  });

  test('the passport renderer has no image path at all (EPR-32)', () => {
    // The map §4 says no photograph reaches a producer by any route, and the
    // reason is structural rather than filtered: there is nothing to filter.
    // If an image path is ever added, EPR-32's publication gate and per-image
    // Admin approval must be built first and the map rewritten.
    for (const file of ['passportPdf.js', 'passports.js']) {
      const source = fs
        .readFileSync(path.join(__dirname, '..', 'src', file), 'utf8')
        .replace(/\/\*[\s\S]*?\*\//g, '')
        .replace(/\/\/.*$/gm, '');

      expect(source).not.toMatch(/\.image\s*\(/);
      expect(source).not.toMatch(/\bphotoUrl\b/);
      expect(source).not.toMatch(/\bsecure_url\b/);
    }
  });
});
