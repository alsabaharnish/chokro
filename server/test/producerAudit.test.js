jest.mock('../src/firebase', () => ({
  db: jest.fn(),
  serverTimestamp: jest.fn(() => '__SERVER_TIMESTAMP__'),
}));

const firebase = require('../src/firebase');
const audit = require('../src/producerAudit');

/**
 * A minimal in-memory Firestore that is only as capable as this module needs:
 * document get/set on two collections, and a query on `orgId` ordered by
 * `sequence` or `timestamp`.
 */
/**
 * Firestore's query operators, as far as these tests use them.
 *
 * Timestamps are unwrapped through `toDate()` so a range filter on a stored
 * `Timestamp` compares against a real instant rather than against an object.
 */
function compare(stored, op, value) {
  const left = stored?.toDate ? stored.toDate().getTime() : stored;
  const right = value?.toDate ? value.toDate().getTime() : value;

  switch (op) {
    case '==':
      return left === right;
    case '!=':
      return left !== right;
    case '>':
      return left > right;
    case '>=':
      return left >= right;
    case '<':
      return left < right;
    case '<=':
      return left <= right;
    case 'in':
      return Array.isArray(right) && right.includes(left);
    default:
      throw new Error(`fake Firestore does not implement operator ${op}`);
  }
}

function fakeFirestore() {
  const store = new Map();

  const key = (col, id) => `${col}/${id}`;

  function collection(col) {
    const q = { col, filters: [], order: null, direction: 'asc', max: Infinity };
    const api = {
      doc(id) {
        const docId = id || `auto_${Math.random().toString(36).slice(2)}`;
        return {
          id: docId,
          path: key(col, docId),
          async get() {
            const data = store.get(key(col, docId));
            return { exists: data !== undefined, id: docId, data: () => data };
          },
        };
      },
      where(field, op, value) {
        // The operator is honoured, not ignored. A fake that treated every
        // `where` as equality silently returned nothing for a range filter, so
        // a query bounded on `expiresAt > now` looked empty and the
        // invitation ceiling it guards never fired in tests.
        q.filters.push([field, op, value]);
        return api;
      },
      orderBy(field, direction = 'asc') {
        q.order = field;
        q.direction = direction;
        return api;
      },
      limit(n) {
        q.max = n;
        return api;
      },
      async get() {
        let rows = [...store.entries()]
          .filter(([k]) => k.startsWith(`${col}/`))
          .map(([k, v]) => ({ id: k.slice(col.length + 1), data: () => v, ...v }));
        for (const [field, op, value] of q.filters) {
          rows = rows.filter((r) => compare(r.data()[field], op, value));
        }
        if (q.order) {
          rows.sort((a, b) => {
            const x = a.data()[q.order];
            const y = b.data()[q.order];
            return q.direction === 'desc' ? (y > x ? 1 : -1) : (x > y ? 1 : -1);
          });
        }
        rows = rows.slice(0, q.max);
        return { docs: rows, empty: rows.length === 0, size: rows.length };
      },
    };
    return api;
  }

  // Enforces the one rule a hand-written fake normally lets through:
  // Firestore requires every read in a transaction to precede every write, and
  // the Admin SDK throws unconditionally otherwise. Three real read-after-write
  // bugs shipped past this suite because the fake did not care.
  let writeIssued = false;

  const txn = {
    async get(target) {
      if (writeIssued) {
        throw new Error(
          'Firestore transactions require all reads to be executed before all writes.',
        );
      }
      return typeof target.get === 'function' ? target.get() : target;
    },
    set(ref, data, options) {
      writeIssued = true;
      store.set(
        ref.path,
        options?.merge ? { ...store.get(ref.path), ...data } : { ...data },
      );
    },
    update(ref, data) {
      writeIssued = true;
      store.set(ref.path, { ...store.get(ref.path), ...data });
    },
  };

  return {
    collection,
    async runTransaction(fn) {
      // A fresh transaction starts with no writes issued, exactly as a real
      // one does — otherwise the second transaction in a test would refuse
      // every read.
      writeIssued = false;
      return fn(txn);
    },
    _store: store,
    _txn: txn,
  };
}

let fs;

beforeEach(() => {
  jest.clearAllMocks();
  fs = fakeFirestore();
  firebase.db.mockReturnValue(fs);
});

// ---------------------------------------------------------------------------

describe('the digest (SEC-12)', () => {
  const base = {
    previousDigest: null,
    orgId: 'org_cola',
    sequence: 1,
    action: 'org.approved',
    actorUid: 'admin_1',
    targetType: 'organization',
    targetId: 'org_cola',
    summary: 'Onboarding approved.',
    beforeDigest: null,
    afterDigest: null,
    timestampIso: '2026-09-08T10:00:00.000Z',
  };

  test('is stable for identical input', () => {
    expect(audit.computeDigest(base)).toBe(audit.computeDigest({ ...base }));
    expect(audit.computeDigest(base)).toHaveLength(64);
  });

  test('changes when any single field changes', () => {
    const original = audit.computeDigest(base);
    for (const field of Object.keys(base)) {
      const mutated = { ...base, [field]: `${base[field] ?? ''}x` };
      expect(audit.computeDigest(mutated)).not.toBe(original);
    }
  });

  test('a field boundary cannot be shifted to forge a match', () => {
    // The separator is U+001F, which none of these values can contain. With a
    // comma or a colon, actor "a" + target "b,c" would digest identically to
    // actor "a,b" + target "c".
    expect(audit.FIELD_SEPARATOR.charCodeAt(0)).toBe(31);
    const left = audit.computeDigest({ ...base, actorUid: 'a', targetId: 'bc' });
    const right = audit.computeDigest({ ...base, actorUid: 'ab', targetId: 'c' });
    expect(left).not.toBe(right);
  });

  test('digestState hides the content while proving it changed', () => {
    const before = audit.digestState({ orgRole: 'orgReporter' });
    const after = audit.digestState({ orgRole: 'orgOwner' });
    expect(before).not.toBe(after);
    expect(before).toHaveLength(64);
    // The log is readable by the organisation's own members; a before-image of
    // a membership document would carry another person's details onto a screen
    // with no business showing them.
    expect(before).not.toContain('orgReporter');
    expect(audit.digestState(null)).toBeNull();
    expect(audit.digestState(undefined)).toBeNull();
  });
});

describe('the key that makes the chain a control (SEC-12)', () => {
  const original = process.env.AUDIT_CHAIN_KEY;

  afterEach(() => {
    if (original === undefined) {
      delete process.env.AUDIT_CHAIN_KEY;
    } else {
      process.env.AUDIT_CHAIN_KEY = original;
    }
  });

  const entry = {
    previousDigest: null,
    orgId: 'org_cola',
    sequence: 1,
    action: 'org.approved',
    actorUid: 'admin_1',
    actorName: 'Admin One',
    actorRole: 'admin',
    targetType: 'organization',
    targetId: 'org_cola',
    summary: 'Onboarding approved.',
    beforeDigest: null,
    afterDigest: null,
    timestampIso: '2026-09-09T10:00:00.000Z',
    ip: '203.0.113.4',
    userAgent: 'Chokro/1.0',
  };

  test('a key changes every digest, so an unkeyed forgery does not verify', () => {
    // The attack an unkeyed chain permits: an insider with Admin SDK access —
    // the adversary SEC-12 names — rewrites entry 12, recomputes its digest
    // with this same public function, then recomputes 13, 14, 15 in order, and
    // verifyChain reports intact. Keying it means forging also requires a
    // secret that the database operator does not hold.
    delete process.env.AUDIT_CHAIN_KEY;
    const unkeyed = audit.computeDigest(entry);
    expect(audit.isKeyed()).toBe(false);

    process.env.AUDIT_CHAIN_KEY = 'a-real-deployment-secret';
    const keyed = audit.computeDigest(entry);
    expect(audit.isKeyed()).toBe(true);

    expect(keyed).not.toBe(unkeyed);
    expect(keyed).toHaveLength(64);
  });

  test('two different keys give two different digests', () => {
    process.env.AUDIT_CHAIN_KEY = 'key-one';
    const a = audit.computeDigest(entry);
    process.env.AUDIT_CHAIN_KEY = 'key-two';
    expect(audit.computeDigest(entry)).not.toBe(a);
  });

  test('verifyChain reports whether the chain is keyed', async () => {
    // A console that printed "intact" without saying which would be
    // overstating the control.
    delete process.env.AUDIT_CHAIN_KEY;
    await audit.append({
      orgId: 'org_cola',
      action: audit.ACTIONS.ORG_APPROVED,
      actorUid: 'admin_1',
    });
    expect((await audit.verifyChain({ orgId: 'org_cola' })).keyed).toBe(false);
  });

  test('every displayed field is covered by the digest', () => {
    // A field shown on the EPR-44 timeline and in the audit pack but absent
    // from the digest is a field the log asserts and cannot defend. actorName
    // and actorRole were exactly that: an entry reading "Admin One / admin"
    // could become "System (automated)" with no finding.
    const baseline = audit.computeDigest(entry);
    for (const field of [
      'actorName',
      'actorRole',
      'ip',
      'userAgent',
      'actorUid',
      'summary',
      'action',
      'targetId',
      'sequence',
    ]) {
      const mutated = {
        ...entry,
        [field]: field === 'sequence' ? 99 : `${entry[field]}-tampered`,
      };
      expect(audit.computeDigest(mutated)).not.toBe(baseline);
    }
  });
});

describe('appending', () => {
  test('the first entry is sequence 1 with no predecessor', async () => {
    const result = await audit.append({
      orgId: 'org_cola',
      action: audit.ACTIONS.ORG_APPROVED,
      actorUid: 'admin_1',
    });

    expect(result.sequence).toBe(1);
    const entry = fs._store.get(`producerAuditLog/${result.entryId}`);
    expect(entry.previousDigest).toBeNull();
    expect(entry.digest).toBe(result.digest);
    expect(entry.timestamp).toBe('__SERVER_TIMESTAMP__');
  });

  test('each entry links to the one before it, per organisation', async () => {
    const first = await audit.append({
      orgId: 'org_cola',
      action: audit.ACTIONS.ORG_APPROVED,
      actorUid: 'admin_1',
    });
    const second = await audit.append({
      orgId: 'org_cola',
      action: audit.ACTIONS.MEMBER_INVITED,
      actorUid: 'admin_1',
    });

    const secondEntry = fs._store.get(`producerAuditLog/${second.entryId}`);
    expect(second.sequence).toBe(2);
    expect(secondEntry.previousDigest).toBe(first.digest);
  });

  test('two organisations keep independent chains', async () => {
    await audit.append({
      orgId: 'org_cola',
      action: audit.ACTIONS.ORG_APPROVED,
      actorUid: 'admin_1',
    });
    const pran = await audit.append({
      orgId: 'org_pran',
      action: audit.ACTIONS.ORG_APPROVED,
      actorUid: 'admin_1',
    });

    // Otherwise one company's activity would reveal the *rate* of another's.
    expect(pran.sequence).toBe(1);
    expect(
      fs._store.get(`producerAuditLog/${pran.entryId}`).previousDigest,
    ).toBeNull();
  });

  test('an unknown action is refused', async () => {
    // Keeps the action column a closed set that a query and a screen can rely
    // on. A vocabulary miss is a programming error, not a runtime condition.
    await expect(
      audit.append({
        orgId: 'org_cola',
        action: 'org.somethingNew',
        actorUid: 'admin_1',
      }),
    ).rejects.toThrow('Unknown audit action');
  });

  test('an entry with no organisation or no actor is refused', async () => {
    await expect(
      audit.append({ action: audit.ACTIONS.ORG_APPROVED, actorUid: 'admin_1' }),
    ).rejects.toThrow('must name an organisation');

    await expect(
      audit.append({ orgId: 'org_cola', action: audit.ACTIONS.ORG_APPROVED }),
    ).rejects.toThrow('must name an actor');
  });

  test('a long user agent is truncated rather than stored whole', async () => {
    const result = await audit.append({
      orgId: 'org_cola',
      action: audit.ACTIONS.ADMIN_VIEWED_AS_ORG,
      actorUid: 'admin_1',
      userAgent: 'u'.repeat(1000),
    });
    expect(
      fs._store.get(`producerAuditLog/${result.entryId}`).userAgent,
    ).toHaveLength(300);
  });
});

describe('verifyChain', () => {
  async function seedThree() {
    const ids = [];
    for (const action of [
      audit.ACTIONS.ORG_APPROVED,
      audit.ACTIONS.MEMBER_INVITED,
      audit.ACTIONS.MEMBER_ACTIVATED,
    ]) {
      const r = await audit.append({
        orgId: 'org_cola',
        action,
        actorUid: 'admin_1',
        summary: action,
      });
      ids.push(r.entryId);
    }
    return ids;
  }

  test('an untouched chain is intact', async () => {
    await seedThree();
    const result = await audit.verifyChain({ orgId: 'org_cola' });
    expect(result.intact).toBe(true);
    expect(result.complete).toBe(true);
    expect(result.entriesChecked).toBe(3);
    expect(result.findings).toEqual([]);
  });

  test('an edited entry is detected', async () => {
    // The named failure mode: an insider edits history, and nothing Chokro
    // issues can be defended afterwards.
    const ids = await seedThree();
    const path = `producerAuditLog/${ids[1]}`;
    fs._store.set(path, {
      ...fs._store.get(path),
      summary: 'Something else entirely.',
    });

    const result = await audit.verifyChain({ orgId: 'org_cola' });
    expect(result.intact).toBe(false);
    expect(result.findings.some((f) => f.problem === 'digestMismatch')).toBe(true);
  });

  test('a deleted entry in the middle is detected', async () => {
    const ids = await seedThree();
    fs._store.delete(`producerAuditLog/${ids[1]}`);

    const result = await audit.verifyChain({ orgId: 'org_cola' });
    expect(result.intact).toBe(false);
    // Both signals fire: the sequence skips, and entry 3 now points at a digest
    // that is no longer in the log.
    expect(result.findings.some((f) => f.problem === 'sequenceGap')).toBe(true);
    expect(result.findings.some((f) => f.problem === 'brokenLink')).toBe(true);
  });

  test('a truncated tail is detected, which a chain alone would not catch', async () => {
    // Lop off the last entries and what remains is a perfectly valid chain.
    // The head is what makes the loss visible.
    const ids = await seedThree();
    fs._store.delete(`producerAuditLog/${ids[2]}`);

    const result = await audit.verifyChain({ orgId: 'org_cola' });
    expect(result.intact).toBe(false);
    const truncation = result.findings.find((f) => f.problem === 'truncated');
    expect(truncation).toMatchObject({ expected: 3, found: 2 });
  });

  test('a wholly emptied log is detected', async () => {
    const ids = await seedThree();
    ids.forEach((id) => fs._store.delete(`producerAuditLog/${id}`));

    const result = await audit.verifyChain({ orgId: 'org_cola' });
    expect(result.intact).toBe(false);
    expect(result.findings.some((f) => f.problem === 'truncated')).toBe(true);
  });

  test('a log longer than the limit never reports itself intact', async () => {
    // "The first N entries are intact" is not the same claim as "the log is
    // intact" and must not be allowed to look like one.
    await seedThree();
    const result = await audit.verifyChain({ orgId: 'org_cola', limit: 2 });
    expect(result.complete).toBe(false);
    expect(result.intact).toBe(false);
  });

  test('an organisation with no head at all is a finding, not a clean bill', async () => {
    // The most complete attack available used to score best: delete every entry
    // for an organisation AND delete its head, and the truncation check — which
    // was guarded on the head being present — was skipped, so the result read
    // `intact: true` over an empty log.
    //
    // Every organisation that exists has a head, because createOrganization
    // writes its first audit entry in the same transaction as the organisation
    // record. So an absent head is never the innocent state it looks like.
    const result = await audit.verifyChain({ orgId: 'org_unknown' });
    expect(result.intact).toBe(false);
    expect(result.headPresent).toBe(false);
    expect(result.findings.some((f) => f.problem === 'headMissing')).toBe(true);
    expect(result.entriesChecked).toBe(0);
  });

  test('deleting the entries and the head together is still detected', async () => {
    const ids = await seedThree();
    ids.forEach((id) => fs._store.delete(`producerAuditLog/${id}`));
    fs._store.delete('producerAuditHeads/org_cola');

    const result = await audit.verifyChain({ orgId: 'org_cola' });
    expect(result.intact).toBe(false);
    expect(result.findings.some((f) => f.problem === 'headMissing')).toBe(true);
  });

  test('a rewritten server timestamp is detected', async () => {
    // `timestamp` is a Firestore sentinel and cannot be hashed, so it is the one
    // stored field outside the digest. Comparing it against the hashed
    // `timestampIso` is what makes rewriting it visible — and the timeline is
    // ordered by `sequence`, which IS hashed, so a rewritten clock cannot
    // reorder what a reader sees either.
    const ids = await seedThree();
    const path = `producerAuditLog/${ids[1]}`;
    fs._store.set(path, {
      ...fs._store.get(path),
      timestamp: { toDate: () => new Date('2020-01-01T00:00:00Z') },
    });

    const result = await audit.verifyChain({ orgId: 'org_cola' });
    expect(result.intact).toBe(false);
    expect(result.findings.some((f) => f.problem === 'timestampDrift')).toBe(
      true,
    );
  });
});
