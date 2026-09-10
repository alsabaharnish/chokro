/**
 * Organisations, membership and invitations (EPR-3, EPR-4, EPR-14, SEC-8).
 *
 * The pure helpers are tested directly. The Firestore paths run against a small
 * in-memory fake, which is enough because the behaviour worth pinning here is
 * the decision logic — the rules tests prove the isolation, and the emulator
 * proves the queries.
 */

jest.mock('../src/firebase', () => ({
  db: jest.fn(),
  auth: jest.fn(),
  admin: {
    firestore: {
      Timestamp: {
        fromDate: (d) => ({ toDate: () => d, __ts: true }),
      },
    },
  },
  serverTimestamp: jest.fn(() => '__TS__'),
}));

const firebase = require('../src/firebase');
const organizations = require('../src/organizations');
const { fakeFirestore } = require('./helpers/firestoreFake');

// ---------------------------------------------------------------------------
// The pure half
// ---------------------------------------------------------------------------

describe('pure helpers', () => {
  test('email normalisation is case- and space-insensitive', () => {
    expect(organizations.normalizeEmail('  Compliance@Cola.TEST ')).toBe(
      'compliance@cola.test',
    );
    expect(organizations.normalizeEmail(null)).toBe('');
  });

  test('the email shape check is a shape check, not a validator', () => {
    expect(organizations.looksLikeEmail('a@b.co')).toBe(true);
    expect(organizations.looksLikeEmail('no-at-sign')).toBe(false);
    expect(organizations.looksLikeEmail('a@b')).toBe(false);
    expect(organizations.looksLikeEmail('a b@c.com')).toBe(false);
  });

  test('the brand key ignores case, spacing and punctuation (EPR-14)', () => {
    // An organisation registering a brand it does not own would not pick a
    // spelling that matches character for character.
    const key = organizations.brandKey('Coca-Cola Bangladesh');
    expect(organizations.brandKey('coca cola bangladesh')).toBe(key);
    expect(organizations.brandKey('CocaCola  Bangladesh')).toBe(key);
    expect(organizations.brandKey('Coca.Cola, Bangladesh')).toBe(key);
    expect(organizations.brandKey('Pran Bangladesh')).not.toBe(key);
  });

  test('org role ranking mirrors the Dart and rules copies', () => {
    expect(organizations.orgRoleAtLeast('orgOwner', 'orgViewer')).toBe(true);
    expect(organizations.orgRoleAtLeast('orgReporter', 'orgOwner')).toBe(false);
    expect(organizations.orgRoleAtLeast('orgSuperuser', 'orgViewer')).toBe(false);
    expect(organizations.orgRoleAtLeast('orgOwner', 'orgSuperuser')).toBe(false);
  });

  test('the member document id is composed the same way everywhere', () => {
    expect(organizations.memberDocId('org_1', 'uid_1')).toBe('org_1_uid_1');
  });

  test('a token is 256 bits of randomness and its digest is stable', () => {
    const a = organizations.generateToken();
    const b = organizations.generateToken();
    expect(a).not.toBe(b);
    // base64url of 32 bytes.
    expect(Buffer.from(a, 'base64url')).toHaveLength(32);
    expect(organizations.hashToken(a)).toBe(organizations.hashToken(a));
    expect(organizations.hashToken(a)).toHaveLength(64);
    expect(organizations.hashToken(a)).not.toBe(a);
  });

  test('categories are filtered to the gazette set and put in gazette order', () => {
    expect(
      organizations.sanitizeCategories(['other', 'compostable', 'rigid', 'rigid']),
    ).toEqual(['rigid', 'other']);
    expect(organizations.sanitizeCategories('rigid')).toEqual([]);
    expect(organizations.sanitizeCategories(null)).toEqual([]);
  });

  test('organisation input requires a legal name, trade name and email', () => {
    expect(
      organizations.validateOrganizationInput({
        legalName: 'Coca-Cola Bangladesh Beverages Ltd',
        tradeName: 'Coca-Cola Bangladesh',
        contactEmail: 'compliance@cola.test',
      }),
    ).toEqual([]);

    const problems = organizations.validateOrganizationInput({
      legalName: 'X',
      tradeName: '',
      contactEmail: 'nope',
    });
    expect(problems).toHaveLength(3);
  });
});

// ---------------------------------------------------------------------------
// The Firestore half
// ---------------------------------------------------------------------------



let fs;

beforeEach(() => {
  jest.clearAllMocks();
  fs = fakeFirestore();
  firebase.db.mockReturnValue(fs);
});

function seedActiveOrg(orgId = 'org_cola') {
  fs._seed('organizations', orgId, {
    legalName: 'Coca-Cola Bangladesh Beverages Ltd',
    tradeName: 'Coca-Cola Bangladesh',
    tradeNameKey: organizations.brandKey('Coca-Cola Bangladesh'),
    legalNameKey: organizations.brandKey('Coca-Cola Bangladesh Beverages Ltd'),
    status: 'active',
    sizeClass: 'large',
  });
  return orgId;
}

describe('membership resolution (SEC-1)', () => {
  test('an active membership in an active organisation resolves and is writable', async () => {
    seedActiveOrg();
    fs._seed('organizationMembers', 'org_cola_uid_1', {
      orgId: 'org_cola',
      uid: 'uid_1',
      orgRole: 'orgReporter',
      status: 'active',
    });

    await expect(
      organizations.resolveMembership('org_cola', 'uid_1'),
    ).resolves.toMatchObject({
      orgId: 'org_cola',
      orgRole: 'orgReporter',
      orgStatus: 'active',
      orgWritable: true,
    });
  });

  test('a suspended organisation resolves read-only (EPR-47)', async () => {
    // The hole this closes: suspension writes `organizations.status` and does
    // not touch a single membership document, so resolving only the membership
    // left every member with full write access on an already-issued token.
    // A reporter could keep registering products through a suspended workspace.
    fs._seed('organizations', 'org_cola', { status: 'suspended' });
    fs._seed('organizationMembers', 'org_cola_uid_1', {
      orgId: 'org_cola',
      uid: 'uid_1',
      orgRole: 'orgOwner',
      status: 'active',
    });

    const membership = await organizations.resolveMembership('org_cola', 'uid_1');
    // Still a member — reads stay open, because suspension must not erase the
    // evidence Chokro already certified.
    expect(membership).toMatchObject({ orgRole: 'orgOwner' });
    // But nothing may be written.
    expect(membership.orgWritable).toBe(false);
    expect(membership.orgStatus).toBe('suspended');
  });

  test('a pending organisation is not writable either', async () => {
    fs._seed('organizations', 'org_new', { status: 'pendingReview' });
    fs._seed('organizationMembers', 'org_new_uid_1', {
      orgId: 'org_new',
      uid: 'uid_1',
      orgRole: 'orgOwner',
      status: 'active',
    });

    const membership = await organizations.resolveMembership('org_new', 'uid_1');
    expect(membership.orgWritable).toBe(false);
  });

  test('a membership of an organisation that no longer exists is not a membership', async () => {
    fs._seed('organizationMembers', 'org_gone_uid_1', {
      orgId: 'org_gone',
      uid: 'uid_1',
      orgRole: 'orgOwner',
      status: 'active',
    });

    await expect(
      organizations.resolveMembership('org_gone', 'uid_1'),
    ).resolves.toBeNull();
  });

  test('both resolution paths agree about writability', async () => {
    // Two membership resolvers that disagree about whether an organisation is
    // writable is a hole by construction, so one delegates to the other.
    fs._seed('organizations', 'org_cola', { status: 'suspended' });
    fs._seed('organizationMembers', 'org_cola_uid_1', {
      orgId: 'org_cola',
      uid: 'uid_1',
      orgRole: 'orgOwner',
      status: 'active',
    });

    const byOrg = await organizations.resolveMembership('org_cola', 'uid_1');
    const byUser = await organizations.findMembershipForUser('uid_1');
    expect(byUser).toEqual(byOrg);
  });

  test('an invited or removed membership resolves to nothing', async () => {
    // An invitation is not a membership, and neither is a revoked one.
    seedActiveOrg();
    for (const status of ['invited', 'removed']) {
      fs._seed('organizationMembers', 'org_cola_uid_2', {
        orgId: 'org_cola',
        uid: 'uid_2',
        orgRole: 'orgOwner',
        status,
      });
      await expect(
        organizations.resolveMembership('org_cola', 'uid_2'),
      ).resolves.toBeNull();
    }
  });

  test('an unrecognised org role resolves to nothing', async () => {
    seedActiveOrg();
    fs._seed('organizationMembers', 'org_cola_uid_3', {
      orgId: 'org_cola',
      uid: 'uid_3',
      orgRole: 'orgSuperuser',
      status: 'active',
    });
    await expect(
      organizations.resolveMembership('org_cola', 'uid_3'),
    ).resolves.toBeNull();
  });

  test('a missing document, orgId or uid resolves to nothing', async () => {
    seedActiveOrg();
    await expect(
      organizations.resolveMembership('org_cola', 'nobody'),
    ).resolves.toBeNull();
    await expect(organizations.resolveMembership(null, 'uid_1')).resolves.toBeNull();
    await expect(organizations.resolveMembership('org_cola', '')).resolves.toBeNull();
  });
});

describe('brand collisions (EPR-14)', () => {
  test('a differently punctuated brand is found', async () => {
    seedActiveOrg();
    const hits = await organizations.findBrandCollisions({
      tradeName: 'coca cola bangladesh',
      legalName: 'Some Other Ltd',
    });
    expect(hits).toHaveLength(1);
    expect(hits[0].orgId).toBe('org_cola');
  });

  test('the organisation under review is not its own collision', async () => {
    seedActiveOrg();
    const hits = await organizations.findBrandCollisions({
      tradeName: 'Coca-Cola Bangladesh',
      legalName: 'Coca-Cola Bangladesh Beverages Ltd',
      excludeOrgId: 'org_cola',
    });
    expect(hits).toEqual([]);
  });

  test('a short name is not matched at all', async () => {
    // Two-letter trade names would otherwise collide with half the register.
    seedActiveOrg();
    await expect(
      organizations.findBrandCollisions({ tradeName: 'BD', legalName: 'X' }),
    ).resolves.toEqual([]);
  });
});

describe('creating an organisation', () => {
  test('writes the record and its first audit entry in one transaction', async () => {
    // This path had no test at all, which is exactly why its read-after-write
    // ordering violation shipped. The fake transaction now refuses a read
    // issued after a write, so a regression here fails rather than passing.
    const result = await organizations.createOrganization({
      legalName: 'Coca-Cola Bangladesh Beverages Ltd',
      tradeName: 'Coca-Cola Bangladesh',
      contactEmail: 'compliance@cola.test',
      adminUid: 'admin_1',
      adminName: 'Admin One',
    });

    expect(result.status).toBe('pendingReview');

    const stored = fs._store.get(`organizations/${result.orgId}`);
    expect(stored.legalName).toBe('Coca-Cola Bangladesh Beverages Ltd');
    expect(stored.tradeNameKey).toBe('cocacolabangladesh');
    // Server-owned fields start empty. Approval sets the size class and the
    // obligation clock against evidence — a record cannot arrive approved.
    expect(stored.status).toBe('pendingReview');
    expect(stored.sizeClass).toBeNull();
    expect(stored.obligationStartDate).toBeNull();
    expect(stored.categories).toEqual([]);

    const entries = fs._find('producerAuditLog');
    expect(entries).toHaveLength(1);
    expect(entries[0].action).toBe('org.applied');
    expect(entries[0].sequence).toBe(1);
  });

  test('an invalid application is refused with its problems', async () => {
    await expect(
      organizations.createOrganization({
        legalName: 'X',
        tradeName: '',
        contactEmail: 'nope',
        adminUid: 'admin_1',
      }),
    ).rejects.toMatchObject({ problems: expect.any(Array) });
  });

  test('a brand collision is surfaced, not acted on', async () => {
    // EPR-14 makes a collision a blocking flag for a person to resolve, not a
    // rule for code to apply: two genuinely different companies can share a
    // word in their name.
    seedActiveOrg();
    const result = await organizations.createOrganization({
      legalName: 'Coca Cola Bangladesh Beverages Ltd',
      tradeName: 'coca cola bangladesh',
      contactEmail: 'other@cola.test',
      adminUid: 'admin_1',
    });

    expect(result.brandCollisions.length).toBeGreaterThan(0);
    // And the record was still created, pending review.
    expect(result.status).toBe('pendingReview');
  });
});

describe('onboarding review (EPR-41)', () => {
  function seedPending(orgId = 'org_new') {
    fs._seed('organizations', orgId, {
      legalName: 'New Ltd',
      tradeName: 'New',
      status: 'pendingReview',
      sizeClass: null,
    });
    return orgId;
  }

  test('approval sets the size class and the obligation clock', async () => {
    const orgId = seedPending();
    const result = await organizations.reviewOrganization({
      orgId,
      decision: 'approve',
      sizeClass: 'large',
      obligationStartDate: new Date('2026-08-13T00:00:00Z'),
      categories: ['rigid', 'compostable'],
      adminUid: 'admin_1',
    });

    expect(result.status).toBe('active');
    const stored = fs._store.get(`organizations/${orgId}`);
    expect(stored.sizeClass).toBe('large');
    expect(stored.categories).toEqual(['rigid']);
    expect(stored.verifiedBy).toBe('admin_1');
  });

  test('approval without a size class is refused', async () => {
    // The size class decides which gazette targets this entity is measured
    // against and from when. Approving without one would leave a workspace
    // that cannot state its own obligation.
    const orgId = seedPending();
    await expect(
      organizations.reviewOrganization({
        orgId,
        decision: 'approve',
        obligationStartDate: new Date(),
        adminUid: 'admin_1',
      }),
    ).rejects.toThrow('size class');
  });

  test('approval without an obligation start date is refused', async () => {
    const orgId = seedPending();
    await expect(
      organizations.reviewOrganization({
        orgId,
        decision: 'approve',
        sizeClass: 'large',
        adminUid: 'admin_1',
      }),
    ).rejects.toThrow('obligation start date');
  });

  test('a rejection or information request needs a stated reason', async () => {
    const orgId = seedPending();
    for (const decision of ['reject', 'requestInfo']) {
      await expect(
        organizations.reviewOrganization({ orgId, decision, adminUid: 'admin_1' }),
      ).rejects.toThrow('reason is required');
    }
  });

  test('an information request leaves the organisation in the queue', async () => {
    const orgId = seedPending();
    await organizations.reviewOrganization({
      orgId,
      decision: 'requestInfo',
      reason: 'Please attach the trade licence.',
      adminUid: 'admin_1',
    });
    expect(fs._store.get(`organizations/${orgId}`).status).toBe('pendingReview');
  });

  test('a second review of the same organisation is refused', async () => {
    // Idempotence, in the manner of approveDisposal: two Admins pressing
    // approve on the same queue item must not both act.
    const orgId = seedPending();
    await organizations.reviewOrganization({
      orgId,
      decision: 'approve',
      sizeClass: 'large',
      obligationStartDate: new Date(),
      adminUid: 'admin_1',
    });
    await expect(
      organizations.reviewOrganization({
        orgId,
        decision: 'approve',
        sizeClass: 'small',
        obligationStartDate: new Date(),
        adminUid: 'admin_2',
      }),
    ).rejects.toThrow('already been reviewed');
  });

  test('an unknown decision is refused', async () => {
    await expect(
      organizations.reviewOrganization({
        orgId: seedPending(),
        decision: 'maybe',
        adminUid: 'admin_1',
      }),
    ).rejects.toThrow('Unknown review decision');
  });
});

describe('suspension (EPR-47)', () => {
  test('suspending keeps the record and records a reason', async () => {
    const orgId = seedActiveOrg();
    await organizations.setOrganizationStatus({
      orgId,
      status: 'suspended',
      reason: 'Mass declaration under investigation.',
      adminUid: 'admin_1',
    });

    const stored = fs._store.get(`organizations/${orgId}`);
    expect(stored.status).toBe('suspended');
    expect(stored.statusReason).toContain('investigation');
    // Never deleted: a passport already in a third party's hands refers to it.
    expect(stored.legalName).toBe('Coca-Cola Bangladesh Beverages Ltd');
  });

  test('suspension needs a reason; reinstatement does not', async () => {
    const orgId = seedActiveOrg();
    await expect(
      organizations.setOrganizationStatus({
        orgId,
        status: 'suspended',
        adminUid: 'admin_1',
      }),
    ).rejects.toThrow('reason is required');

    await organizations.setOrganizationStatus({
      orgId,
      status: 'suspended',
      reason: 'Under investigation.',
      adminUid: 'admin_1',
    });
    await expect(
      organizations.setOrganizationStatus({
        orgId,
        status: 'active',
        adminUid: 'admin_1',
      }),
    ).resolves.toMatchObject({ status: 'active' });
  });

  test('a pending organisation cannot be suspended before it is reviewed', async () => {
    fs._seed('organizations', 'org_pending', { status: 'pendingReview' });
    await expect(
      organizations.setOrganizationStatus({
        orgId: 'org_pending',
        status: 'suspended',
        reason: 'Not yet reviewed.',
        adminUid: 'admin_1',
      }),
    ).rejects.toThrow('Review that organisation');
  });
});

describe('invitations (SEC-8)', () => {
  test('the token is returned once and only its digest is stored', async () => {
    const orgId = seedActiveOrg();
    const invitation = await organizations.createInvitation({
      orgId,
      email: 'Engineer@Cola.TEST',
      orgRole: 'orgReporter',
      actorUid: 'uid_owner',
    });

    expect(invitation.token).toBeTruthy();
    expect(invitation.email).toBe('engineer@cola.test');

    const stored = fs._store.get(`orgInvitations/${invitation.invitationId}`);
    // A dump of this collection must yield nothing redeemable.
    expect(JSON.stringify(stored)).not.toContain(invitation.token);
    expect(invitation.invitationId).toBe(
      organizations.hashToken(invitation.token),
    );
  });

  test('an invitation to a non-active organisation is refused', async () => {
    // A suspended or pending workspace is read-only, and an invitation is a
    // write to the tenancy boundary.
    fs._seed('organizations', 'org_susp', { status: 'suspended' });
    await expect(
      organizations.createInvitation({
        orgId: 'org_susp',
        email: 'a@b.com',
        orgRole: 'orgViewer',
        actorUid: 'uid_owner',
      }),
    ).rejects.toThrow('not active');
  });

  test('a bad address or an unknown role is refused', async () => {
    const orgId = seedActiveOrg();
    await expect(
      organizations.createInvitation({
        orgId,
        email: 'not-an-email',
        orgRole: 'orgViewer',
        actorUid: 'uid_owner',
      }),
    ).rejects.toThrow('valid work email');

    await expect(
      organizations.createInvitation({
        orgId,
        email: 'a@b.com',
        orgRole: 'orgSuperuser',
        actorUid: 'uid_owner',
      }),
    ).rejects.toThrow('Unknown organisation role');
  });

  test('a second live invitation to the same address is refused', async () => {
    // Two links to one person are two ways in, and revoking the first would no
    // longer close the door.
    const orgId = seedActiveOrg();
    await organizations.createInvitation({
      orgId,
      email: 'engineer@cola.test',
      orgRole: 'orgReporter',
      actorUid: 'uid_owner',
    });
    await expect(
      organizations.createInvitation({
        orgId,
        email: 'ENGINEER@cola.test',
        orgRole: 'orgViewer',
        actorUid: 'uid_owner',
      }),
    ).rejects.toThrow('already outstanding');
  });

  test('stale pending invitations cannot crowd out the ceiling', async () => {
    // The bypass: expiry is lazy and nothing rewrites a lapsed invitation's
    // status, so `status: 'pending'` accumulates forever. Once a full page of
    // stale rows existed, the filtered `live` list came back empty and NEITHER
    // the ceiling nor the one-live-invitation-per-address check fired — so an
    // owner could mint unlimited concurrent tokens for one address.
    const orgId = seedActiveOrg();

    // More stale rows than the query page.
    for (let i = 0; i < organizations.MAX_PENDING_INVITATIONS + 5; i += 1) {
      await organizations.createInvitation({
        orgId,
        email: `stale${i}@cola.test`,
        orgRole: 'orgViewer',
        actorUid: 'uid_owner',
        ttlHours: -1,
      });
    }

    // One live invitation, then a second to the same address, which must be
    // refused rather than hidden behind the stale page.
    await organizations.createInvitation({
      orgId,
      email: 'alice@cola.test',
      orgRole: 'orgReporter',
      actorUid: 'uid_owner',
    });

    await expect(
      organizations.createInvitation({
        orgId,
        email: 'alice@cola.test',
        orgRole: 'orgReporter',
        actorUid: 'uid_owner',
      }),
    ).rejects.toThrow('already outstanding');
  });

  test('an expired invitation does not block a fresh one', async () => {
    const orgId = seedActiveOrg();
    await organizations.createInvitation({
      orgId,
      email: 'engineer@cola.test',
      orgRole: 'orgReporter',
      actorUid: 'uid_owner',
      ttlHours: -1,
    });
    await expect(
      organizations.createInvitation({
        orgId,
        email: 'engineer@cola.test',
        orgRole: 'orgReporter',
        actorUid: 'uid_owner',
      }),
    ).resolves.toHaveProperty('token');
  });

  test('the per-organisation ceiling holds', async () => {
    const orgId = seedActiveOrg();
    for (let i = 0; i < organizations.MAX_PENDING_INVITATIONS; i += 1) {
      await organizations.createInvitation({
        orgId,
        email: `person${i}@cola.test`,
        orgRole: 'orgViewer',
        actorUid: 'uid_owner',
      });
    }
    await expect(
      organizations.createInvitation({
        orgId,
        email: 'one.too.many@cola.test',
        orgRole: 'orgViewer',
        actorUid: 'uid_owner',
      }),
    ).rejects.toThrow('too many invitations');
  });

  test('revocation is scoped to the caller organisation', async () => {
    // An invitation id from another tenant must not be actionable with this
    // session's authority.
    const orgId = seedActiveOrg();
    const invitation = await organizations.createInvitation({
      orgId,
      email: 'engineer@cola.test',
      orgRole: 'orgReporter',
      actorUid: 'uid_owner',
    });

    await expect(
      organizations.revokeInvitation({
        invitationId: invitation.invitationId,
        orgId: 'org_pran',
        actorUid: 'uid_pran_owner',
      }),
    ).rejects.toThrow('does not exist');

    await expect(
      organizations.revokeInvitation({
        invitationId: invitation.invitationId,
        orgId,
        actorUid: 'uid_owner',
      }),
    ).resolves.toMatchObject({ status: 'revoked' });
  });

  test('a revoked invitation cannot be revoked again', async () => {
    const orgId = seedActiveOrg();
    const invitation = await organizations.createInvitation({
      orgId,
      email: 'engineer@cola.test',
      orgRole: 'orgReporter',
      actorUid: 'uid_owner',
    });
    await organizations.revokeInvitation({
      invitationId: invitation.invitationId,
      orgId,
      actorUid: 'uid_owner',
    });
    await expect(
      organizations.revokeInvitation({
        invitationId: invitation.invitationId,
        orgId,
        actorUid: 'uid_owner',
      }),
    ).rejects.toThrow('already revoked');
  });

  test('expiry is resolved lazily at read time, not by a scheduler', async () => {
    // Nothing runs on a timer in this system (§3.3, NFR-E-2). The stored status
    // stays `pending`; every reader decides for itself.
    const orgId = seedActiveOrg();
    const invitation = await organizations.createInvitation({
      orgId,
      email: 'engineer@cola.test',
      orgRole: 'orgReporter',
      actorUid: 'uid_owner',
      ttlHours: -1,
    });

    expect(
      fs._store.get(`orgInvitations/${invitation.invitationId}`).status,
    ).toBe('pending');

    const listed = await organizations.listInvitations({ orgId });
    expect(listed[0].status).toBe('expired');
  });
});

describe('membership changes (SEC-2)', () => {
  function seedMember(uid, orgRole, status = 'active') {
    fs._seed('organizationMembers', `org_cola_${uid}`, {
      orgId: 'org_cola',
      uid,
      orgRole,
      status,
    });
  }

  test('the last owner cannot be demoted or removed', async () => {
    // An organisation with no owner cannot invite anyone back, which turns an
    // ordinary administrative slip into a support ticket.
    seedActiveOrg();
    seedMember('uid_owner', 'orgOwner');
    seedMember('uid_reporter', 'orgReporter');

    await expect(
      organizations.changeMemberRole({
        orgId: 'org_cola',
        uid: 'uid_owner',
        orgRole: 'orgViewer',
        actorUid: 'uid_owner',
      }),
    ).rejects.toThrow('at least one owner');

    await expect(
      organizations.removeMember({
        orgId: 'org_cola',
        uid: 'uid_owner',
        actorUid: 'uid_owner',
      }),
    ).rejects.toThrow('at least one owner');
  });

  test('a second owner makes the first removable', async () => {
    seedActiveOrg();
    seedMember('uid_owner', 'orgOwner');
    seedMember('uid_owner_2', 'orgOwner');

    await expect(
      organizations.removeMember({
        orgId: 'org_cola',
        uid: 'uid_owner',
        actorUid: 'uid_owner_2',
      }),
    ).resolves.toMatchObject({ status: 'removed' });
  });

  test('removal marks the record rather than deleting it', async () => {
    // The audit trail refers to it, and a deleted row makes "who had access in
    // September?" unanswerable.
    seedActiveOrg();
    seedMember('uid_owner', 'orgOwner');
    seedMember('uid_reporter', 'orgReporter');

    await organizations.removeMember({
      orgId: 'org_cola',
      uid: 'uid_reporter',
      actorUid: 'uid_owner',
    });

    const stored = fs._store.get('organizationMembers/org_cola_uid_reporter');
    expect(stored.status).toBe('removed');
    expect(stored.orgRole).toBe('orgReporter');
    expect(stored.removedBy).toBe('uid_owner');
  });

  test('a removed member cannot be removed twice', async () => {
    seedActiveOrg();
    seedMember('uid_gone', 'orgViewer', 'removed');
    await expect(
      organizations.removeMember({
        orgId: 'org_cola',
        uid: 'uid_gone',
        actorUid: 'uid_owner',
      }),
    ).rejects.toThrow('already been removed');
  });

  test('an unknown org role is refused on a role change', async () => {
    seedActiveOrg();
    seedMember('uid_reporter', 'orgReporter');
    await expect(
      organizations.changeMemberRole({
        orgId: 'org_cola',
        uid: 'uid_reporter',
        orgRole: 'orgSuperuser',
        actorUid: 'uid_owner',
      }),
    ).rejects.toThrow('Unknown organisation role');
  });
});
