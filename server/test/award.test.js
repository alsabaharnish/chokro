/**
 * Tests for the single wallet-credit path (F2.8, F3.2, §7.3).
 *
 * ## Why this file exists
 *
 * An audit pointed out that `award.js` — the one function in the system that
 * writes a wallet balance — had no tests at all. The 212 that existed covered
 * pure functions well and the I/O half not at all, which meant the properties
 * the whole design rests on were asserted only by prose: that a decision cannot
 * credit twice, that a balance and its ledger entry move together, and that the
 * daily cap holds.
 *
 * The daily-cap bug is the argument for writing them. It counted disposals
 * *created* since UTC midnight rather than approvals *performed* today, so
 * banking submissions on one day and verifying them the next defeated the cap
 * entirely. No pure-function test could have caught it — the comparison was
 * correct, the thing being compared was wrong. Only a test that approves a
 * yesterday-created disposal finds it, and that needs the transaction.
 *
 * Firestore is faked rather than emulated: §9 of the brief allows pure Node unit
 * tests and no integration harness, and the fake is small enough to read.
 */

jest.mock('../src/firebase', () => {
  const increment = (n) => ({ __increment: n });
  return {
    db: jest.fn(),
    serverTimestamp: () => ({ __serverTimestamp: true }),
    admin: { firestore: { FieldValue: { increment } } },
  };
});

// Push is fire-and-forget after the commit and swallows its own failures; here
// it would only add noise.
jest.mock('../src/push', () => ({
  notifyDisposalApproved: jest.fn().mockResolvedValue(undefined),
  notifyDisposalRejected: jest.fn().mockResolvedValue(undefined),
}));

const firebase = require('../src/firebase');
const policyModule = require('../src/pointsPolicy');
const { approveDisposal, rejectDisposal } = require('../src/award');

const DAY = policyModule.dayKey(new Date());

/**
 * A Firestore stand-in that records what a transaction read and wrote.
 *
 * `seed` maps `collection/id` to document data. Anything absent reads as
 * non-existent, which is what an untouched daily counter looks like.
 */
function fakeFirestore(seed = {}) {
  const writes = [];
  const reads = [];
  let autoId = 0;

  const ref = (path) => ({ path, id: path.split('/').pop() });

  const txn = {
    get: async (target) => {
      // The old daily-cap implementation passed a *query* here rather than a
      // document reference. `queriesIssued` below is what asserts it no longer
      // does.
      if (!target || !target.path) {
        reads.push({ query: true, target });
        return { docs: [] };
      }
      reads.push({ path: target.path });
      const data = seed[target.path];
      return {
        exists: data !== undefined,
        data: () => data,
        ref: target,
      };
    },
    set: (target, data, options) =>
      writes.push({ op: 'set', path: target.path, data, options }),
    update: (target, data) => writes.push({ op: 'update', path: target.path, data }),
    delete: (target) => writes.push({ op: 'delete', path: target.path }),
  };

  const firestore = {
    collection: (name) => ({
      doc: (id) => ref(`${name}/${id ?? `auto_${(autoId += 1)}`}`),
      where() {
        // Returns a query object with no `path`, so `txn.get` records it as a
        // query rather than a document read.
        return { where: firestore.collection(name).where, __query: name };
      },
    }),
    runTransaction: async (body) => body(txn),
  };

  firebase.db.mockReturnValue(firestore);

  return {
    writes,
    reads,
    queriesIssued: () => reads.filter((r) => r.query).length,
    readPaths: () => reads.filter((r) => r.path).map((r) => r.path),
    writesTo: (prefix) => writes.filter((w) => w.path.startsWith(prefix)),
  };
}

/** A pending disposal that has completed verification, so it is approvable. */
function pendingDisposal(overrides = {}) {
  return {
    userId: 'u1',
    binId: 'bin1',
    status: 'pending',
    flags: [],
    verificationCompleted: true,
    photoHash: 'abcd',
    screenConfidence: 0.9,
    screenItemCount: 5,
    ...overrides,
  };
}

function baseSeed(overrides = {}) {
  return {
    'disposals/d1': pendingDisposal(),
    'wallets/u1': { balance: 100 },
    'config/points': null,
    ...overrides,
  };
}

beforeEach(() => {
  jest.clearAllMocks();
});

// ---------------------------------------------------------------------------
// The daily cap
// ---------------------------------------------------------------------------

describe('daily disposal cap', () => {
  it('credits when the counter for today is absent', async () => {
    const fake = fakeFirestore(baseSeed());

    const result = await approveDisposal({ disposalId: 'd1' });

    expect(result.pointsAwarded).toBe(policyModule.DEFAULTS.disposalAward);
    expect(result.status).toBe('autoApproved');
  });

  it('refuses once the counter has reached the cap', async () => {
    const fake = fakeFirestore(
      baseSeed({ [`dailyCaps/u1_${DAY}`]: { count: 3 } }),
    );

    await expect(approveDisposal({ disposalId: 'd1' })).rejects.toThrow(
      /daily limit/i,
    );
    // Nothing may move on a refusal.
    expect(fake.writesTo('wallets/')).toHaveLength(0);
    expect(fake.writesTo('transactions/')).toHaveLength(0);
  });

  it('THE REGRESSION: the cap ignores when the submission was created', async () => {
    // The bug: the cap counted disposals with `createdAt >= today's UTC
    // midnight`, so a submission banked yesterday and verified today was never
    // counted. Ten of them credited ten times against a cap of three.
    //
    // The fix keys the counter on the day the DECISION is made, so `createdAt`
    // is no longer an input. This asserts that directly: an ancient submission
    // still trips a counter that is already at the cap.
    const lastYear = new Date('2025-01-01T00:00:00Z');
    const fake = fakeFirestore(
      baseSeed({
        'disposals/d1': pendingDisposal({ createdAt: lastYear }),
        [`dailyCaps/u1_${DAY}`]: { count: 3 },
      }),
    );

    await expect(approveDisposal({ disposalId: 'd1' })).rejects.toThrow(
      /daily limit/i,
    );
  });

  it('reads a document, never a collection query', async () => {
    // The old implementation issued a `where()` query over `disposals` inside
    // the transaction. A query cannot express "approvals performed today", which
    // is what made it wrong — and it also made every approval read the user's
    // whole submission history.
    const fake = fakeFirestore(baseSeed());

    await approveDisposal({ disposalId: 'd1' });

    expect(fake.queriesIssued()).toBe(0);
    expect(fake.readPaths()).toContain(`dailyCaps/u1_${DAY}`);
  });

  it('increments the counter in the same transaction as the credit', async () => {
    const fake = fakeFirestore(baseSeed());

    await approveDisposal({ disposalId: 'd1' });

    const capWrite = fake.writesTo(`dailyCaps/u1_${DAY}`)[0];
    expect(capWrite).toBeDefined();
    expect(capWrite.data.count).toEqual({ __increment: 1 });
    expect(capWrite.options).toEqual({ merge: true });
    // A decision that pays must also be counted, or the cap drifts.
    expect(fake.writesTo('wallets/u1')).toHaveLength(1);
  });
});

// ---------------------------------------------------------------------------
// The invariants the design rests on
// ---------------------------------------------------------------------------

describe('the balance and its ledger entry move together (NFR-4)', () => {
  it('writes exactly one wallet update and one transaction per approval', async () => {
    const fake = fakeFirestore(baseSeed());

    await approveDisposal({ disposalId: 'd1' });

    expect(fake.writesTo('wallets/u1')).toHaveLength(1);
    expect(fake.writesTo('transactions/')).toHaveLength(1);
  });

  it('the ledger entry records the resulting balance and the source', async () => {
    const fake = fakeFirestore(baseSeed());

    await approveDisposal({ disposalId: 'd1' });

    const entry = fake.writesTo('transactions/')[0].data;
    expect(entry.userId).toBe('u1');
    expect(entry.delta).toBe(policyModule.DEFAULTS.disposalAward);
    expect(entry.source).toBe('disposal');
    expect(entry.refId).toBe('d1');
    // 100 seeded + 50 awarded. `balanceAfter` is only trustworthy because
    // nothing writes the balance with an increment().
    expect(entry.balanceAfter).toBe(150);

    const wallet = fake.writesTo('wallets/u1')[0].data;
    expect(wallet.balance).toBe(150);
  });
});

describe('idempotence', () => {
  it('refuses a submission that was already approved', async () => {
    const fake = fakeFirestore(
      baseSeed({ 'disposals/d1': pendingDisposal({ status: 'autoApproved' }) }),
    );

    await expect(approveDisposal({ disposalId: 'd1' })).rejects.toThrow(
      /already been decided/i,
    );
    expect(fake.writesTo('wallets/')).toHaveLength(0);
  });

  it('refuses a submission that was already rejected', async () => {
    fakeFirestore(
      baseSeed({ 'disposals/d1': pendingDisposal({ status: 'rejected' }) }),
    );

    await expect(approveDisposal({ disposalId: 'd1' })).rejects.toThrow(
      /already been decided/i,
    );
  });
});

describe('verification must have run before a payout', () => {
  it('refuses a submission whose verification has not completed', async () => {
    // A client-created pending document appears in the admin queue before the
    // submitting device's verify call finishes. Without this guard a fast
    // reviewer could approve inside that window, using the client-reported
    // distance and empty flags.
    fakeFirestore(
      baseSeed({
        'disposals/d1': {
          userId: 'u1',
          binId: 'bin1',
          status: 'pending',
          flags: [],
        },
      }),
    );

    await expect(approveDisposal({ disposalId: 'd1' })).rejects.toThrow(
      /Verification is still running/i,
    );
  });
});

describe('rejection', () => {
  it('requires a reason', async () => {
    fakeFirestore(baseSeed());

    await expect(
      rejectDisposal({ disposalId: 'd1', adminUid: 'a1', reason: '  ' }),
    ).rejects.toThrow(/must record a reason/i);
  });

  it('credits nothing and writes no ledger entry', async () => {
    const fake = fakeFirestore(baseSeed());

    await rejectDisposal({
      disposalId: 'd1',
      adminUid: 'a1',
      reason: 'The photograph did not show the declared items.',
    });

    expect(fake.writesTo('wallets/')).toHaveLength(0);
    expect(fake.writesTo('transactions/')).toHaveLength(0);
    expect(fake.writesTo(`dailyCaps/`)).toHaveLength(0);
  });

  it('releases the lockout only when this submission opened it', async () => {
    // The key is {uid}_{binId} with no disposal in it, so an unconditional
    // delete released whatever window happened to be there — and a user can
    // hold two pending submissions at one bin.
    const fake = fakeFirestore(
      baseSeed({ 'lockouts/u1_bin1': { disposalId: 'someone_elses' } }),
    );

    await rejectDisposal({
      disposalId: 'd1',
      adminUid: 'a1',
      reason: 'The photograph did not show the declared items.',
    });

    expect(fake.writesTo('lockouts/')).toHaveLength(0);
  });

  it('does release the lockout it owns', async () => {
    const fake = fakeFirestore(
      baseSeed({ 'lockouts/u1_bin1': { disposalId: 'd1' } }),
    );

    await rejectDisposal({
      disposalId: 'd1',
      adminUid: 'a1',
      reason: 'The photograph did not show the declared items.',
    });

    expect(fake.writesTo('lockouts/')[0].op).toBe('delete');
  });
});

// ---------------------------------------------------------------------------
// dayKey — the thing that now defines "today"
// ---------------------------------------------------------------------------

describe('dayKey', () => {
  it('is a sortable UTC calendar day', () => {
    expect(policyModule.dayKey(new Date('2026-08-20T12:00:00Z'))).toBe('2026-08-20');
  });

  it('zero-pads, so keys sort lexicographically', () => {
    expect(policyModule.dayKey(new Date('2026-01-05T00:00:00Z'))).toBe('2026-01-05');
  });

  it('rolls at UTC midnight, not at local midnight', () => {
    // 23:59 UTC on the 20th is 05:59 on the 21st in Dhaka. The counter is
    // UTC-anchored so that it agrees with the ISO-week quota; the consequence is
    // a 06:00 local reset, which is documented rather than accidental.
    expect(policyModule.dayKey(new Date('2026-08-20T23:59:59Z'))).toBe('2026-08-20');
    expect(policyModule.dayKey(new Date('2026-08-21T00:00:00Z'))).toBe('2026-08-21');
  });
});
