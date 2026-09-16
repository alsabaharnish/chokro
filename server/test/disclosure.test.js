/**
 * Lawful disclosure to the regulator (SEC-13).
 *
 * Two classes of test. The first is about the CONTROLS — that a disclosure
 * without a lawful basis is refused, that the record is written before the
 * resolution runs, and that naming a person is a separate act from producing
 * evidence.
 *
 * The second is about the ARITHMETIC, and it is the one that would actually
 * bite. The pseudonym is computed in `reportJobs` and reversed here, so two
 * implementations of one HMAC exist in the codebase. If they drift, a genuine
 * row resolves as not found, and Chokro tells a regulator that a real
 * collection is fabricated. That failure is silent and catastrophic, so it
 * gets its own tests.
 */

jest.mock('../src/firebase', () => ({
  db: jest.fn(),
  serverTimestamp: jest.fn(() => '__TS__'),
}));

jest.mock('../src/producerAudit', () => {
  const actual = jest.requireActual('../src/producerAudit');
  return { ...actual, append: jest.fn().mockResolvedValue(undefined) };
});

const firebase = require('../src/firebase');
const audit = require('../src/producerAudit');
const reportJobs = require('../src/reportJobs');
const disclosure = require('../src/disclosure');

const ADMIN = { adminUid: 'admin-1', adminName: 'Ayesha Rahman' };
const DOE = 'DoE/EPR/2026/0041';

function attributionPage(rows) {
  return {
    empty: rows.length === 0,
    size: rows.length,
    docs: rows.map((r) => ({ id: r.attributionId, data: () => r })),
  };
}

/**
 * A Firestore double that answers the scan, the row fetch and the document
 * reads the module makes, in whatever order it makes them.
 */
function fakeDb({ attributions = [], disposal = undefined, user = undefined }) {
  return {
    collection: (name) => {
      if (name === 'attributions') {
        const q = {
          where: () => q,
          orderBy: () => q,
          limit: () => q,
          startAfter: () => ({ get: async () => attributionPage([]) }),
          get: async () => attributionPage(attributions),
        };
        return q;
      }
      if (name === 'disposals') {
        return {
          doc: () => ({
            get: async () => ({
              exists: disposal !== undefined,
              data: () => disposal,
            }),
          }),
        };
      }
      if (name === 'users') {
        return {
          doc: () => ({
            get: async () => ({ exists: user !== undefined, data: () => user }),
          }),
        };
      }
      throw new Error(`unexpected collection ${name}`);
    },
  };
}

beforeEach(() => jest.clearAllMocks());

// ---------------------------------------------------------------------------
// The arithmetic. If this drifts, a real row reads as fabricated.
// ---------------------------------------------------------------------------

describe('the pseudonym this module reverses is the one reportJobs mints', () => {
  const ORG = 'org-1';
  const DISPOSAL = 'disposal-abc';

  afterEach(() => {
    delete process.env.AUDIT_CHAIN_KEY;
    jest.resetModules();
  });

  test('with a key set, the keyed candidate matches exactly', () => {
    process.env.AUDIT_CHAIN_KEY = 'a-real-looking-key';
    jest.resetModules();
    const rj = require('../src/reportJobs');
    const d = require('../src/disclosure');

    expect(d.candidateRefs(ORG, DISPOSAL).keyed).toBe(rj.pseudonym(ORG, DISPOSAL));
  });

  test('with no key set, the UNKEYED candidate matches exactly', () => {
    // The bug this test exists for: `reportJobs.pseudonym` falls back to an
    // EMPTY STRING key, not to a different algorithm. It is still an HMAC,
    // keyed ':<orgId>'. A reimplementation using createHash produces a digest
    // that matches nothing, and the symptom is a regulator being told a
    // genuine reference is unknown.
    delete process.env.AUDIT_CHAIN_KEY;
    jest.resetModules();
    const rj = require('../src/reportJobs');
    const d = require('../src/disclosure');

    expect(d.unkeyedPseudonym(ORG, DISPOSAL)).toBe(rj.pseudonym(ORG, DISPOSAL));
  });

  test('the keyed and unkeyed forms are different digests', () => {
    process.env.AUDIT_CHAIN_KEY = 'a-real-looking-key';
    jest.resetModules();
    const d = require('../src/disclosure');
    const refs = d.candidateRefs(ORG, DISPOSAL);

    expect(refs.keyed).not.toBe(refs.unkeyed);
  });

  test('the pseudonym is per-organisation, so two producers cannot correlate', () => {
    const a = disclosure.candidateRefs('org-1', DISPOSAL);
    const b = disclosure.candidateRefs('org-2', DISPOSAL);
    expect(a.keyed).not.toBe(b.keyed);
    expect(a.unkeyed).not.toBe(b.unkeyed);
  });
});

// ---------------------------------------------------------------------------
// The lawful basis
// ---------------------------------------------------------------------------

describe('a disclosure without a lawful basis is refused', () => {
  const ref = 'a'.repeat(24);

  test.each([
    ['absent', undefined],
    ['empty', ''],
    ['whitespace', '   '],
    ['too short to be a reference', 'x'],
  ])('a %s regulator reference is refused', async (_label, doeReference) => {
    await expect(
      disclosure.resolveDisposalRef({
        orgId: 'org-1',
        disposalRef: ref,
        doeReference,
        ...ADMIN,
      }),
    ).rejects.toThrow(/reference/);
  });

  test('nothing is recorded and nothing is read when it is refused', async () => {
    await expect(
      disclosure.resolveDisposalRef({
        orgId: 'org-1',
        disposalRef: ref,
        ...ADMIN,
      }),
    ).rejects.toThrow();

    // A refused disclosure must not appear in the log as an attempted one —
    // but more importantly, validation runs before the append, so a malformed
    // request cannot write to the chain at all.
    expect(audit.append).not.toHaveBeenCalled();
  });

  test('a malformed reference is refused before anything is read', async () => {
    await expect(
      disclosure.resolveDisposalRef({
        orgId: 'org-1',
        disposalRef: 'not-a-digest',
        doeReference: DOE,
        ...ADMIN,
      }),
    ).rejects.toThrow(/chain-of-custody/);
    expect(audit.append).not.toHaveBeenCalled();
  });

  test('a disclosure must name the Admin making it', async () => {
    await expect(
      disclosure.resolveDisposalRef({
        orgId: 'org-1',
        disposalRef: ref,
        doeReference: DOE,
        adminUid: '',
      }),
    ).rejects.toThrow(/Admin/);
  });
});

// ---------------------------------------------------------------------------
// The record comes first
// ---------------------------------------------------------------------------

describe('the resolution is recorded before it runs', () => {
  test('a resolution that cannot be recorded does not happen', async () => {
    audit.append.mockRejectedValueOnce(new Error('chain unavailable'));
    firebase.db.mockReturnValue(fakeDb({ attributions: [] }));

    await expect(
      disclosure.resolveDisposalRef({
        orgId: 'org-1',
        disposalRef: 'a'.repeat(24),
        doeReference: DOE,
        ...ADMIN,
      }),
    ).rejects.toThrow('chain unavailable');

    // The point: no read happened. Logging on success would leave a crashed
    // resolution untraced, and that is precisely the resolution somebody would
    // want untraced.
    expect(firebase.db).not.toHaveBeenCalled();
  });

  test('the entry names the regulator request and says identity was not released', async () => {
    firebase.db.mockReturnValue(fakeDb({ attributions: [] }));

    await disclosure.resolveDisposalRef({
      orgId: 'org-1',
      disposalRef: 'a'.repeat(24),
      doeReference: DOE,
      ...ADMIN,
    });

    expect(audit.append).toHaveBeenCalledTimes(1);
    const entry = audit.append.mock.calls[0][0];
    expect(entry.action).toBe(audit.ACTIONS.DISCLOSURE_RESOLVED);
    expect(entry.summary).toContain(DOE);
    expect(entry.summary).toContain('the Champion was not named');
    expect(entry.actorUid).toBe('admin-1');
  });
});

// ---------------------------------------------------------------------------
// Resolving
// ---------------------------------------------------------------------------

describe('resolving a reference', () => {
  const ORG = 'org-1';

  test('a keyed reference resolves to its disposal and attributions', async () => {
    const disposalId = 'disposal-abc';
    const ref = reportJobs.pseudonym(ORG, disposalId);

    firebase.db.mockReturnValue(
      fakeDb({
        attributions: [
          { attributionId: 'attr-1', disposalId, periodId: '2026-09', massMg: 21000, skuId: 'sku-1' },
        ],
        disposal: { photoUrl: 'https://example/p.jpg', binId: 'bin-7', status: 'approved', userId: 'champion-1' },
      }),
    );

    const result = await disclosure.resolveDisposalRef({
      orgId: ORG,
      disposalRef: ref,
      doeReference: DOE,
      ...ADMIN,
    });

    expect(result.found).toBe(true);
    expect(result.disposalId).toBe(disposalId);
    expect(result.evidence.disposalPresent).toBe(true);
    expect(result.evidence.binId).toBe('bin-7');
    expect(result.attributions).toHaveLength(1);
    expect(result.attributions[0].massMg).toBe(21000);
  });

  test('the evidence never carries the Champion, even though the record does', async () => {
    const disposalId = 'disposal-abc';
    const ref = reportJobs.pseudonym(ORG, disposalId);

    firebase.db.mockReturnValue(
      fakeDb({
        attributions: [{ attributionId: 'attr-1', disposalId }],
        disposal: { binId: 'bin-7', userId: 'champion-1', photoUrl: 'x' },
      }),
    );

    const result = await disclosure.resolveDisposalRef({
      orgId: ORG,
      disposalRef: ref,
      doeReference: DOE,
      ...ADMIN,
    });

    // The disposal document holds `userId` and this projection drops it. Most
    // regulator questions are "did this collection happen", and answering one
    // must not hand over a person as a side effect.
    expect(JSON.stringify(result)).not.toContain('champion-1');
    expect(result.evidence.userId).toBeUndefined();
  });

  test('a reference minted before the key was set still resolves, and says so', async () => {
    const disposalId = 'disposal-old';
    process.env.AUDIT_CHAIN_KEY = 'set-after-the-export';
    jest.resetModules();
    const d = require('../src/disclosure');
    const fb = require('../src/firebase');
    const a = require('../src/producerAudit');
    a.append.mockResolvedValue(undefined);

    const oldRef = d.unkeyedPseudonym(ORG, disposalId);
    fb.db.mockReturnValue(
      fakeDb({
        attributions: [{ attributionId: 'attr-1', disposalId }],
        disposal: { binId: 'bin-7' },
      }),
    );

    const result = await d.resolveDisposalRef({
      orgId: ORG,
      disposalRef: oldRef,
      doeReference: DOE,
      ...ADMIN,
    });

    expect(result.found).toBe(true);
    // Reported rather than hidden: a reference that resolves only unkeyed is
    // evidence the export predates keying, which is worth knowing about an
    // exhibit.
    expect(result.referenceKeyed).toBe(false);

    delete process.env.AUDIT_CHAIN_KEY;
    jest.resetModules();
  });

  test('a disposal that has been erased still resolves its attributions', async () => {
    const disposalId = 'disposal-gone';
    const ref = reportJobs.pseudonym(ORG, disposalId);

    firebase.db.mockReturnValue(
      fakeDb({
        attributions: [{ attributionId: 'attr-1', disposalId, massMg: 21000 }],
        disposal: undefined,
      }),
    );

    const result = await disclosure.resolveDisposalRef({
      orgId: ORG,
      disposalRef: ref,
      doeReference: DOE,
      ...ADMIN,
    });

    // The severing case. Attributions outlive their disposal by design, so a
    // missing disposal is a real state and not an error.
    expect(result.found).toBe(true);
    expect(result.evidence.disposalPresent).toBe(false);
    expect(result.attributions).toHaveLength(1);
  });

  test('an exhausted scan that found nothing says the reference is not this org\'s', async () => {
    firebase.db.mockReturnValue(
      fakeDb({ attributions: [{ attributionId: 'a', disposalId: 'other' }] }),
    );

    const result = await disclosure.resolveDisposalRef({
      orgId: ORG,
      disposalRef: 'b'.repeat(24),
      doeReference: DOE,
      ...ADMIN,
    });

    expect(result.found).toBe(false);
    // The distinction a regulator's conclusion turns on.
    expect(result.exhaustive).toBe(true);
    expect(result.note).toContain('Check the organisation');
  });
});

// ---------------------------------------------------------------------------
// Naming a person is a separate act
// ---------------------------------------------------------------------------

describe('releasing an identity', () => {
  test('it requires its own regulator reference', async () => {
    await expect(
      disclosure.releaseIdentity({
        orgId: 'org-1',
        disposalId: 'disposal-abc',
        ...ADMIN,
      }),
    ).rejects.toThrow(/reference/);
    expect(audit.append).not.toHaveBeenCalled();
  });

  test('it writes a DIFFERENT audit action from a resolution', async () => {
    firebase.db.mockReturnValue(
      fakeDb({
        disposal: { userId: 'champion-1' },
        user: { name: 'Rahim Uddin', email: 'rahim@example.com' },
      }),
    );

    const result = await disclosure.releaseIdentity({
      orgId: 'org-1',
      disposalId: 'disposal-abc',
      doeReference: DOE,
      ...ADMIN,
    });

    const entry = audit.append.mock.calls[0][0];
    // Permanently distinguishable in the log. An Admin who produced evidence
    // and one who named a person did different things, and six months later
    // the log has to still say which.
    expect(entry.action).toBe(audit.ACTIONS.DISCLOSURE_IDENTITY_RELEASED);
    expect(entry.action).not.toBe(audit.ACTIONS.DISCLOSURE_RESOLVED);
    expect(entry.summary).toContain('names a person');

    expect(result.released).toBe(true);
    expect(result.champion.name).toBe('Rahim Uddin');
  });

  test('an erased disposal releases nothing and says why', async () => {
    firebase.db.mockReturnValue(fakeDb({ disposal: undefined }));

    const result = await disclosure.releaseIdentity({
      orgId: 'org-1',
      disposalId: 'disposal-gone',
      doeReference: DOE,
      ...ADMIN,
    });

    expect(result.released).toBe(false);
    expect(result.note).toContain('about packaging');
    // Still recorded. An attempt to name someone is worth a line in the log
    // whether or not it succeeded.
    expect(audit.append).toHaveBeenCalledTimes(1);
  });
});
