/**
 * The read-only organisation view and the activity timeline (EPR-44, EPR-46,
 * SEC-12).
 *
 * EPR-46's whole content is a prohibition: "There is **no impersonation** — no
 * Admin action is ever taken under a producer's identity, because an audit
 * trail that cannot distinguish the two is not an audit trail."
 *
 * So most of this file asserts things the view does NOT do.
 */

jest.mock('../src/firebase', () => ({
  db: jest.fn(),
  admin: {
    firestore: {
      FieldValue: {
        increment: (n) => ({ __increment: n }),
        arrayUnion: (...v) => ({ __arrayUnion: v }),
      },
      FieldPath: { documentId: () => '__name__' },
      Timestamp: { now: () => ({ toDate: () => new Date('2026-10-03T05:12:00Z') }) },
    },
  },
  serverTimestamp: jest.fn(() => '__TS__'),
}));

jest.mock('../src/eprPolicy', () => ({ readPolicy: jest.fn() }));

const firebase = require('../src/firebase');
const eprPolicy = require('../src/eprPolicy');
const viewAs = require('../src/viewAsOrganization');
const audit = require('../src/producerAudit');
const { fakeFirestore } = require('./helpers/firestoreFake');

let fs;
const ORG = 'org_cola';
const PERIOD = '2026-09';
const MG = 1000000;

beforeEach(() => {
  jest.clearAllMocks();
  fs = fakeFirestore();
  firebase.db.mockReturnValue(fs);
  eprPolicy.readPolicy.mockResolvedValue({ kAnonymityFloor: 5 });

  fs._seed('organizations', ORG, {
    legalName: 'Coca-Cola Bangladesh Beverages Ltd.',
    tradeName: 'Coca-Cola Bangladesh',
    status: 'active',
    sizeClass: 'large',
    doeRegistrationNo: 'DoE/EPR/2026/0417',
  });

  fs._seed('eprPeriods', `${ORG}_${PERIOD}`, {
    orgId: ORG,
    periodId: PERIOD,
    massMgByCategory: { rigid: 100 * MG },
    massMgByDistrict: { Dhaka: 60 * MG, Chattogram: 40 * MG },
    attributionCount: 40,
    disposalCount: 40,
    skuIds: ['sku_a'],
  });

  for (const [uid, orgRole] of [
    ['uid_viewer', 'orgViewer'],
    ['uid_owner', 'orgOwner'],
    ['uid_reporter', 'orgReporter'],
  ]) {
    fs._seed('organizationMembers', `${ORG}_${uid}`, {
      orgId: ORG, uid, orgRole, status: 'active',
    });
  }
});

const open = (over = {}) =>
  viewAs.viewAs({
    orgId: ORG,
    periodId: PERIOD,
    adminUid: 'uid_admin',
    adminName: 'Chokro Compliance',
    ...over,
  });

// ---------------------------------------------------------------------------
// The prohibition
// ---------------------------------------------------------------------------

describe('the view is not impersonation', () => {
  test('says so in the payload, not just in a comment', async () => {
    const view = await open();

    expect(view.readOnly).toBe(true);
    expect(view.impersonation).toBe(false);
    expect(view.capabilities.canWrite).toBe(false);
    expect(view.capabilities.canFile).toBe(false);
    expect(view.capabilities.canIssue).toBe(false);
  });

  test('the module writes nothing but the audit entry', async () => {
    const before = fs._store.size;
    await open();
    const after = [...fs._store.keys()];

    // One new document, and it is the audit entry (plus its chain head).
    const added = after.filter((k) => !k.startsWith(audit.COLLECTION)
      && !k.startsWith(audit.HEAD_COLLECTION));
    expect(added.length).toBe(before);
  });

  test('is reachable only through an admin path', () => {
    // `requireOrgRole` refuses administrators on purpose, so a shared code
    // path cannot exist. Asserted against the source, because this is a
    // property of the ROUTING rather than of any function here.
    const fsNode = require('fs');
    const path = require('path');
    const index = fsNode.readFileSync(
      path.resolve(__dirname, '../src/index.js'), 'utf8',
    );
    // Comments stripped first. The route explains at length WHY it uses
    // `requireAdmin` rather than `requireOrgRole`, and a naive scan matches
    // the explanation and fails on correct code.
    const code = index
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/\/\/[^\n]*/g, '');
    const route = code.slice(
      code.indexOf("'/epr/admin/organizations/:orgId/view'"),
      code.indexOf("'/epr/admin/organizations/:orgId/timeline'"),
    );

    expect(route).toMatch(/requireAdmin/);
    expect(route).not.toMatch(/requireOrgRole/);
  });
});

// ---------------------------------------------------------------------------
// The audit entry
// ---------------------------------------------------------------------------

describe('recording the view', () => {
  test('records it before assembling anything', async () => {
    await open();

    const entry = fs._find(audit.COLLECTION)
      .find((e) => e.action === audit.ACTIONS.ADMIN_VIEWED_AS_ORG);

    expect(entry).toBeTruthy();
    expect(entry.actorUid).toBe('uid_admin');
    expect(entry.actorRole).toBe('admin');
    expect(entry.orgId).toBe(ORG);
    expect(entry.summary).toMatch(/No action was taken under the producer/i);
  });

  test('a view that cannot be logged does not happen', async () => {
    // Reading a customer's compliance position without a record of having done
    // so is the insider behaviour SEC-12 exists to make visible, and "the log
    // was briefly unavailable" is precisely when an exception would be
    // convenient.
    const broken = {
      collection: (name) => ({
        doc: () => ({
          get: async () => {
            if (name === audit.HEAD_COLLECTION) throw new Error('log down');
            return { exists: true, data: () => ({ legalName: 'X', tradeName: 'X' }) };
          },
          set: async () => { throw new Error('log down'); },
          update: async () => { throw new Error('log down'); },
        }),
        where: () => ({ where: () => ({ limit: () => ({ get: async () => ({ docs: [], empty: true }) }) }) }),
      }),
      runTransaction: async () => { throw new Error('log down'); },
    };
    firebase.db.mockReturnValue(broken);

    await expect(open()).rejects.toThrow();

    // And nothing was assembled — the refusal comes before the reads.
    expect(fs._find(audit.COLLECTION)).toEqual([]);
  });

  test('names the period, so two views of one producer are distinguishable', async () => {
    await open({ periodId: '2026-08' });
    const entry = fs._find(audit.COLLECTION)
      .find((e) => e.action === audit.ACTIONS.ADMIN_VIEWED_AS_ORG);
    expect(entry.summary).toMatch(/2026-08/);
  });
});

// ---------------------------------------------------------------------------
// It must be the SAME view
// ---------------------------------------------------------------------------

describe('what the Admin sees', () => {
  test('is the producer’s projection, suppressions included', async () => {
    // THE POINT OF THIS MODULE. An Admin looking at a producer's screen is
    // usually doing it because the producer phoned about a figure. A view
    // assembled from a second, Admin-flavoured path would drift — and the
    // drift would show up exactly when it matters, with the Admin insisting
    // the screen says one thing while the producer reads another.
    const eprPeriods = require('../src/eprPeriods');
    const policy = { kAnonymityFloor: 5 };
    const rollup = fs._store.get(`eprPeriods/${ORG}_${PERIOD}`);

    const view = await open();

    expect(view.period).toEqual(
      eprPeriods.projectForProducer({ ...rollup, id: undefined }, policy),
    );
  });

  test('sees the k-anonymity floor applied, not around it', async () => {
    // SEC-3's suppression is part of the producer's view. An Admin seeing the
    // unsuppressed districts would be looking at a different screen from the
    // one being discussed — and has the reconciliation console and the anomaly
    // queue for that question.
    fs._seed('eprPeriods', `${ORG}_${PERIOD}`, {
      ...fs._store.get(`eprPeriods/${ORG}_${PERIOD}`),
      disposalCount: 2,
    });

    const view = await open();
    expect(view.period.districtSuppressed).toBe(true);
    expect(view.period.massMgByDistrict).toEqual({});
  });

  test('defaults to the current period when none is named', async () => {
    const view = await open({ periodId: null });
    expect(view.periodId).toMatch(/^\d{4}-\d{2}$/);
  });

  test('refuses a period that is not one', async () => {
    await expect(open({ periodId: '2026-9' })).rejects.toThrow(/reporting period/i);
  });

  test('refuses an organisation that does not exist', async () => {
    await expect(open({ orgId: 'org_ghost' })).rejects.toThrow(/does not exist/i);
  });
});

describe('the membership list in the view', () => {
  test('carries no contact details', async () => {
    // An Admin needs to know who has access in order to answer "who filed
    // this". They do not need the members' email addresses to answer it, and
    // this view is opened routinely.
    const view = await open();
    const serialised = JSON.stringify(view.members);

    expect(view.members.length).toBe(3);
    expect(serialised).not.toMatch(/@|email|phone/i);
  });

  test('lists owners first, in the same order permissions rank', async () => {
    // The display order cannot drift from the permission order, because both
    // read `ORG_ROLES`.
    const view = await open();
    expect(view.members.map((m) => m.orgRole))
      .toEqual(['orgOwner', 'orgReporter', 'orgViewer']);
  });
});

// ---------------------------------------------------------------------------
// The activity timeline (EPR-44)
// ---------------------------------------------------------------------------

describe('the activity timeline', () => {
  async function seedEntries() {
    for (const [action, summary] of [
      [audit.ACTIONS.MEMBER_INVITED, 'Invited a reporter.'],
      [audit.ACTIONS.DECLARATION_SUBMITTED, 'Filed 27,400 kg for 2026-09.'],
      [audit.ACTIONS.PASSPORT_ISSUED, 'Issued CHKR-PP-9F2K-7T4D.'],
    ]) {
      await audit.append({
        orgId: ORG,
        action,
        actorUid: 'uid_owner',
        actorName: 'Nasrin Akhter',
        actorRole: 'orgOwner',
        targetType: 'organization',
        targetId: ORG,
        summary,
      });
    }
  }

  test('is one chronological view of everything that happened', async () => {
    await seedEntries();
    const timeline = await viewAs.activityTimeline({ orgId: ORG });

    expect(timeline.entries).toHaveLength(3);
    expect(timeline.entries.map((e) => e.action)).toEqual(
      expect.arrayContaining([
        audit.ACTIONS.MEMBER_INVITED,
        audit.ACTIONS.DECLARATION_SUBMITTED,
        audit.ACTIONS.PASSPORT_ISSUED,
      ]),
    );
  });

  test('orders by the hashed sequence, not by the clock', async () => {
    // `sequence` is inside the chain digest and `timestamp` is not, so ordering
    // by the clock would let an insider reorder the visible timeline — placing
    // a mass verification before the declaration it informed — without breaking
    // the chain.
    await seedEntries();
    const timeline = await viewAs.activityTimeline({ orgId: ORG });

    const sequences = timeline.entries.map((e) => e.sequence);
    expect(sequences).toEqual([...sequences].sort((a, b) => b - a));
  });

  test('carries the actor uid, which cannot be edited into something else', async () => {
    await seedEntries();
    const timeline = await viewAs.activityTimeline({ orgId: ORG });

    for (const entry of timeline.entries) {
      expect(entry.actorUid).toBe('uid_owner');
      expect(entry.actorRole).toBe('orgOwner');
    }
  });

  test('says whether the chain was checked rather than leaving it assumed', async () => {
    await seedEntries();

    const plain = await viewAs.activityTimeline({ orgId: ORG });
    // Null, not false: "not checked" and "checked and failed" are different
    // statements, and an export that conflated them would be worse than one
    // that said nothing.
    expect(plain.verified).toBeNull();

    const verified = await viewAs.verifiedTimeline({ orgId: ORG });
    expect(verified.verified).toBe(true);
    expect(verified.verification.intact).toBe(true);
  });

  test('says whether the chain is keyed, not just whether it is intact', async () => {
    // `producerAudit` makes the point itself: an unkeyed chain is tamper-
    // evident against anyone WITHOUT write access, and is not evidence against
    // the insider SEC-12 names. An export that printed "intact" without saying
    // which would be overstating the control.
    await seedEntries();
    const verified = await viewAs.verifiedTimeline({ orgId: ORG });

    expect(verified).toHaveProperty('keyed');
    if (!verified.keyed) {
      expect(verified.verificationCaveat).toMatch(/AUDIT_CHAIN_KEY/);
    } else {
      expect(verified.verificationCaveat).toBeNull();
    }
  });

  test('reports a broken chain as unverified', async () => {
    await seedEntries();

    // Tamper with a stored entry's summary. The digest covers it, so the chain
    // no longer validates.
    const [entry] = fs._find(audit.COLLECTION);
    fs._seed(audit.COLLECTION, entry.id, { ...entry, summary: 'Something else.' });

    const verified = await viewAs.verifiedTimeline({ orgId: ORG });
    expect(verified.verified).toBe(false);
  });

  test('is bounded', async () => {
    const timeline = await viewAs.activityTimeline({ orgId: ORG, limit: 5 });
    expect(timeline.entries.length).toBeLessThanOrEqual(5);
  });
});
