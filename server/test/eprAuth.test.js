/**
 * The producer-portal authorisation middleware (SEC-1, SEC-2, SEC-5, SEC-9).
 *
 * Each test names the failure mode from §11 that it prevents.
 */

jest.mock('../src/firebase', () => ({
  auth: jest.fn(),
  db: jest.fn(),
  serverTimestamp: jest.fn(() => '__TS__'),
}));

jest.mock('../src/organizations', () => ({
  resolveMembership: jest.fn(),
  findMembershipForUser: jest.fn(),
  orgRoleAtLeast: jest.requireActual('../src/organizations').orgRoleAtLeast,
}));

const organizations = require('../src/organizations');
const {
  requireProducer,
  requireVerifiedEmail,
  requireFreshAuth,
  requireOrgRole,
  requireActiveOrganization,
} = require('../src/auth');

function response() {
  const res = { status: jest.fn(), json: jest.fn() };
  res.status.mockReturnValue(res);
  res.json.mockReturnValue(res);
  return res;
}

const nowSeconds = () => Math.floor(Date.now() / 1000);

function request(user, params = {}, body = {}) {
  return { user, params, body, get: jest.fn(() => '') };
}

beforeEach(() => jest.clearAllMocks());

// ---------------------------------------------------------------------------

describe('requireProducer', () => {
  test('lets a producer through', () => {
    const next = jest.fn();
    requireProducer(request({ uid: 'u', role: 'producer' }), response(), next);
    expect(next).toHaveBeenCalled();
  });

  test('refuses every citizen role, administrators included', () => {
    for (const role of ['buyer', 'seller', 'admin']) {
      const res = response();
      const next = jest.fn();
      requireProducer(request({ uid: 'u', role }), res, next);
      expect(next).not.toHaveBeenCalled();
      expect(res.status).toHaveBeenCalledWith(403);
    }
  });
});

describe('requireVerifiedEmail (EPR-5)', () => {
  test('refuses an unverified address', () => {
    const res = response();
    const next = jest.fn();
    requireVerifiedEmail(
      request({ uid: 'u', role: 'producer', emailVerified: false }),
      res,
      next,
    );
    expect(next).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(403);
    expect(res.json.mock.calls[0][0].error).toBe('email_unverified');
  });

  test('allows a verified one', () => {
    const next = jest.fn();
    requireVerifiedEmail(
      request({ uid: 'u', role: 'producer', emailVerified: true }),
      response(),
      next,
    );
    expect(next).toHaveBeenCalled();
  });
});

describe('requireFreshAuth (SEC-9)', () => {
  test('allows a session that signed in a minute ago', () => {
    const next = jest.fn();
    requireFreshAuth(1800)(
      request({ uid: 'u', authTime: nowSeconds() - 60 }),
      response(),
      next,
    );
    expect(next).toHaveBeenCalled();
  });

  test('refuses a session older than the window', () => {
    // The failure mode is an unattended office desktop. A Firebase session
    // refreshes itself indefinitely, so without this a token minted six weeks
    // ago is as good as one minted this minute for removing a colleague.
    const res = response();
    const next = jest.fn();
    requireFreshAuth(1800)(
      request({ uid: 'u', authTime: nowSeconds() - 7200 }),
      res,
      next,
    );
    expect(next).not.toHaveBeenCalled();
    expect(res.json.mock.calls[0][0].error).toBe('reauthentication_required');
  });

  test('fails closed when the token carries no auth_time', () => {
    const res = response();
    const next = jest.fn();
    requireFreshAuth(1800)(request({ uid: 'u' }), res, next);
    expect(next).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(403);
  });
});

describe('requireActiveOrganization (EPR-47)', () => {
  test('an active organisation passes', () => {
    const next = jest.fn();
    const req = request({ uid: 'u', role: 'producer' });
    req.orgMembership = { orgId: 'org_cola', orgRole: 'orgOwner', orgWritable: true };
    requireActiveOrganization(req, response(), next);
    expect(next).toHaveBeenCalled();
  });

  test('a suspended organisation is refused, with its own error code', () => {
    // EPR-47: suspension makes the portal read-only and stops new issuance. It
    // never deletes, so reads stay open — which is why this is a separate
    // middleware applied only to writes.
    const res = response();
    const next = jest.fn();
    const req = request({ uid: 'u', role: 'producer' });
    req.orgMembership = {
      orgId: 'org_cola',
      orgRole: 'orgOwner',
      orgStatus: 'suspended',
      orgWritable: false,
    };

    requireActiveOrganization(req, res, next);

    expect(next).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(403);
    expect(res.json.mock.calls[0][0].error).toBe('organization_read_only');
    expect(res.json.mock.calls[0][0].message).toContain('read-only');
  });

  test('a pending organisation is refused with a different sentence', () => {
    const res = response();
    const req = request({ uid: 'u', role: 'producer' });
    req.orgMembership = {
      orgId: 'org_new',
      orgRole: 'orgOwner',
      orgStatus: 'pendingReview',
      orgWritable: false,
    };

    requireActiveOrganization(req, res, jest.fn());
    expect(res.json.mock.calls[0][0].message).toContain('not open for changes');
  });

  test('a request with no resolved membership fails closed', () => {
    // Reached only if a route forgot requireOrgRole. Waving it through would
    // make the omission invisible.
    const res = response();
    const next = jest.fn();
    requireActiveOrganization(request({ uid: 'u' }), res, next);
    expect(next).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(403);
  });

  test('a missing orgWritable is treated as not writable', () => {
    // Fail closed on a membership shape from an older resolver.
    const res = response();
    const next = jest.fn();
    const req = request({ uid: 'u', role: 'producer' });
    req.orgMembership = { orgId: 'org_cola', orgRole: 'orgOwner' };
    requireActiveOrganization(req, res, next);
    expect(next).not.toHaveBeenCalled();
  });
});

describe('requireOrgRole (SEC-1, SEC-5)', () => {
  const producer = { uid: 'uid_owner', role: 'producer', emailVerified: true };

  test('attaches the resolved membership and never trusts the body', async () => {
    organizations.findMembershipForUser.mockResolvedValue({
      orgId: 'org_cola',
      uid: 'uid_owner',
      orgRole: 'orgOwner',
      status: 'active',
    });

    const next = jest.fn();
    // A body naming a different organisation. It must have no effect at all.
    const req = request(producer, {}, { orgId: 'org_pran' });
    await requireOrgRole('orgOwner')(req, response(), next);

    expect(next).toHaveBeenCalled();
    expect(req.orgMembership.orgId).toBe('org_cola');
    expect(organizations.findMembershipForUser).toHaveBeenCalledWith('uid_owner');
  });

  test('a route parameter is resolved against the stored membership', async () => {
    // The check is not "does the caller claim org_pran" but "is there a stored
    // membership of org_pran for this uid".
    organizations.resolveMembership.mockResolvedValue(null);

    const res = response();
    const next = jest.fn();
    await requireOrgRole('orgViewer')(
      request(producer, { orgId: 'org_pran' }),
      res,
      next,
    );

    expect(organizations.resolveMembership).toHaveBeenCalledWith(
      'org_pran',
      'uid_owner',
    );
    expect(next).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(403);
  });

  test('a non-member gets the same message as a non-existent organisation', async () => {
    // Distinguishing them turns this endpoint into a way to enumerate Chokro's
    // customers.
    organizations.resolveMembership.mockResolvedValue(null);
    const res = response();
    await requireOrgRole('orgViewer')(
      request(producer, { orgId: 'org_does_not_exist' }),
      res,
      jest.fn(),
    );
    expect(res.json.mock.calls[0][0].message).toBe(
      'You do not have access to that organisation.',
    );
  });

  test('an insufficient org role is refused with its own error code', async () => {
    // SEC-5's stated failure mode: an orgViewer submitting a legal declaration.
    organizations.findMembershipForUser.mockResolvedValue({
      orgId: 'org_cola',
      uid: 'uid_owner',
      orgRole: 'orgViewer',
      status: 'active',
    });

    const res = response();
    const next = jest.fn();
    await requireOrgRole('orgOwner')(request(producer), res, next);

    expect(next).not.toHaveBeenCalled();
    expect(res.json.mock.calls[0][0].error).toBe('insufficient_org_role');
  });

  test('a reporter satisfies a viewer requirement but not an owner one', async () => {
    organizations.findMembershipForUser.mockResolvedValue({
      orgId: 'org_cola',
      uid: 'uid_owner',
      orgRole: 'orgReporter',
      status: 'active',
    });

    const allowed = jest.fn();
    await requireOrgRole('orgViewer')(request(producer), response(), allowed);
    expect(allowed).toHaveBeenCalled();

    const refused = jest.fn();
    await requireOrgRole('orgOwner')(request(producer), response(), refused);
    expect(refused).not.toHaveBeenCalled();
  });

  test('an administrator does not pass — they have their own routes (EPR-46)', async () => {
    // A shared code path would give an audit trail that cannot distinguish an
    // owner acting in their company from a Chokro employee acting on it.
    const res = response();
    const next = jest.fn();
    await requireOrgRole('orgViewer')(
      request({ uid: 'admin_1', role: 'admin' }),
      res,
      next,
    );
    expect(next).not.toHaveBeenCalled();
    expect(res.status).toHaveBeenCalledWith(403);
    expect(organizations.findMembershipForUser).not.toHaveBeenCalled();
  });

  test('a Champion does not pass', async () => {
    const res = response();
    const next = jest.fn();
    await requireOrgRole('orgViewer')(
      request({ uid: 'uid_champ', role: 'buyer' }),
      res,
      next,
    );
    expect(next).not.toHaveBeenCalled();
    expect(organizations.findMembershipForUser).not.toHaveBeenCalled();
  });

  test('an unauthenticated request is a 401, not a 403', async () => {
    const res = response();
    await requireOrgRole('orgViewer')(request(undefined), res, jest.fn());
    expect(res.status).toHaveBeenCalledWith(401);
  });

  test('a membership lookup outage is a retryable 503, not a denial', async () => {
    // A 403 would tell a legitimate member their access had been revoked.
    organizations.findMembershipForUser.mockRejectedValue(new Error('down'));
    const errorSpy = jest.spyOn(console, 'error').mockImplementation(() => {});

    const res = response();
    const next = jest.fn();
    await requireOrgRole('orgViewer')(request(producer), res, next);

    expect(res.status).toHaveBeenCalledWith(503);
    expect(next).not.toHaveBeenCalled();
    errorSpy.mockRestore();
  });
});
