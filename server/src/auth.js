/**
 * Request authentication.
 *
 * Every endpoint that touches user data requires a Firebase ID token, which the
 * Flutter app obtains from `FirebaseAuth.instance.currentUser.getIdToken()` and
 * sends as `Authorization: Bearer <token>`.
 *
 * WHY THE ROLE IS READ FROM FIRESTORE, NOT FROM THE TOKEN
 * The ID token is signed by Firebase and cannot be forged, so `uid` is
 * trustworthy. But the role lives in the user document, and a token minted
 * before a role change would carry a stale claim. Reading `users/{uid}` on each
 * request costs one lookup and means a suspension takes effect immediately
 * rather than whenever the client happens to refresh its token.
 */

const { auth, db } = require('./firebase');
const { isActiveProfile, suspensionMessage } = require('./suspension');
const organizations = require('./organizations');

/**
 * Verifies the bearer token and attaches `req.user = { uid, role, status }`.
 * Rejects with 401 for a missing or invalid token, 403 for a suspended account.
 */
async function requireAuth(req, res, next) {
  const header = req.get('Authorization') || '';
  const match = header.match(/^Bearer\s+(.+)$/i);

  if (!match) {
    return res.status(401).json({
      error: 'unauthenticated',
      message: 'Missing Authorization: Bearer <idToken> header.',
    });
  }

  let decoded;
  try {
    // `checkRevoked: true`.
    //
    // The comment at the top of this file claims the per-request Firestore read
    // makes a suspension take effect immediately. That is true of the `status`
    // field and of nothing else. Revocation at the *Firebase* level —
    // `disabled: true`, `deleteUser`, `revokeRefreshTokens`, a password change
    // after a compromise — is invisible to `verifyIdToken` without this flag, so
    // an administrator deleting a fraudulent account in the console would watch
    // it keep uploading for up to an hour until the ID token expired.
    //
    // It costs one extra lookup per request against Firebase's revocation state.
    // That is the right price for the account-deletion path meaning what an
    // administrator thinks it means.
    decoded = await auth().verifyIdToken(match[1], true);
  } catch (err) {
    return res.status(401).json({
      error: 'invalid_token',
      message: 'The ID token could not be verified.',
    });
  }

  let snapshot;
  try {
    snapshot = await db().collection('users').doc(decoded.uid).get();
  } catch (err) {
    // Express 4 does not automatically turn a rejected async middleware
    // promise into a response. Letting this throw left callers waiting until
    // their own timeout and could surface as an unhandled rejection. A profile
    // service outage is retryable and is neither a bad token nor a suspension.
    console.error(`Profile lookup for ${decoded.uid} failed:`, err.message);
    return res.status(503).json({
      error: 'account_service_unavailable',
      message: 'The account service is temporarily unavailable. Try again.',
    });
  }
  if (!snapshot.exists) {
    // A valid token for a user with no profile document. Should not happen —
    // registration writes both atomically — but treat it as unauthorised rather
    // than assuming a default role.
    return res.status(403).json({
      error: 'no_profile',
      message: 'No user profile exists for this account.',
    });
  }

  const profile = snapshot.data();

  // Resolved through the shared rule, NOT `profile.status !== 'active'`.
  //
  // A temporary suspension is never rewritten back to `active` — nothing is
  // running that could do it — so a lapsed one is permanently
  // `status: 'suspended'` plus a past date. The string comparison this replaces
  // therefore refused every server call forever, while `firestore.rules` and the
  // Flutter UI both treated the same user as active. See `suspension.js`.
  if (!isActiveProfile(profile)) {
    return res.status(403).json({
      error: 'account_suspended',
      message: suspensionMessage(profile),
    });
  }

  req.user = {
    uid: decoded.uid,
    role: profile.role || 'buyer',
    name: profile.name || '',
    email: profile.email || '',
    // The stored value, which for a lapsed suspension still reads 'suspended'.
    // Nothing downstream should compare this to 'active' — that is the mistake
    // this change fixes. `isActiveProfile` is the only correct test.
    status: profile.status,
    suspendedUntil: profile.suspendedUntil || null,
    // From the token, not the profile. `auth_time` is when this session last
    // proved possession of the credential, and it is what `requireFreshAuth`
    // measures for the privileged producer-portal actions (SEC-9). It cannot be
    // read from Firestore because it is a property of the session, not the
    // account.
    authTime: typeof decoded.auth_time === 'number' ? decoded.auth_time : null,
    emailVerified: decoded.email_verified === true,
  };

  return next();
}

/** Requires an administrator. Use after [requireAuth]. */
function requireAdmin(req, res, next) {
  if (!req.user || req.user.role !== 'admin') {
    return res.status(403).json({
      error: 'forbidden',
      message: 'This action requires a 3ZERO Admin.',
    });
  }
  return next();
}

/**
 * Requires a seller. Use after [requireAuth].
 *
 * An administrator passes, matching `UserModel.isSeller` in Dart and the
 * `role in ['seller', 'admin']` check in `firestore.rules`. All three have to
 * agree or one account will be able to list a product and not upload its
 * photograph — the failure would surface as a 403 from the upload endpoint with
 * a perfectly valid listing already written.
 */
function requireSeller(req, res, next) {
  if (!req.user || !['seller', 'admin'].includes(req.user.role)) {
    return res.status(403).json({
      error: 'forbidden',
      message: 'This action requires a 3ZERO Greenpreneur profile.',
    });
  }
  return next();
}

/**
 * Requires the disjoint producer role (EPR-1). Use after [requireAuth].
 *
 * The role alone authorises nothing inside the portal — it says which workspace
 * exists, not whose data may be touched. Every route that reaches an
 * organisation's data must also pass [requireOrgRole], which resolves a stored
 * membership. Mirrors `UserModel.isProducer` in Dart and `isProducerWith` in
 * `firestore.rules`.
 */
function requireProducer(req, res, next) {
  if (!req.user || req.user.role !== 'producer') {
    return res.status(403).json({
      error: 'forbidden',
      message: 'This action requires an EPR Producer account.',
    });
  }
  return next();
}

/**
 * Requires a verified email address (EPR-5).
 *
 * Multi-factor authentication needs Identity Platform, which needs billing —
 * the same barrier that shapes the no-scheduler decision. Until it is enabled,
 * a verified address is the only evidence this system has that the person
 * holding the password also controls the mailbox the invitation went to, and it
 * is what a password reset would depend on. So it gates the workspace rather
 * than being a badge on a settings screen.
 *
 * Read from the token's `email_verified` claim, which Firebase refreshes when
 * verification completes.
 */
function requireVerifiedEmail(req, res, next) {
  if (!req.user || req.user.emailVerified !== true) {
    return res.status(403).json({
      error: 'email_unverified',
      message:
        'Verify your email address before using the producer workspace. '
        + 'Check your inbox for the verification link.',
    });
  }
  return next();
}

/**
 * Requires the session to have authenticated recently (SEC-9).
 *
 * Applied to the privileged actions — submitting a declaration, verifying a
 * mass, issuing a passport, changing membership. Its failure mode is an
 * unattended office desktop: a Firebase session refreshes itself indefinitely,
 * so without this an ID token minted six weeks ago is as good as one minted
 * this minute for the purpose of removing a colleague's access.
 *
 * A 403 with a distinguishable error code, so the client can re-prompt for the
 * password and retry rather than showing a generic refusal.
 *
 * @param {number} maxAgeSeconds  how recently the credential must have been proved
 */
function requireFreshAuth(maxAgeSeconds = 30 * 60) {
  return function freshAuth(req, res, next) {
    const authTime = req.user?.authTime;

    // Fail closed. A token with no `auth_time` is not evidence of a recent
    // sign-in, so it is treated as an old one.
    if (typeof authTime !== 'number') {
      return res.status(403).json({
        error: 'reauthentication_required',
        message: 'Sign in again to continue.',
      });
    }

    const ageSeconds = Math.floor(Date.now() / 1000) - authTime;
    if (ageSeconds > maxAgeSeconds) {
      return res.status(403).json({
        error: 'reauthentication_required',
        message: 'Sign in again to continue.',
      });
    }

    return next();
  };
}

/**
 * Requires the organisation to be open for work (EPR-47). Use after
 * [requireOrgRole], on every write route.
 *
 * Suspension makes the portal read-only and stops new issuance. It never
 * deletes: the evidence Chokro has already certified must survive, both because
 * a passport in a third party's hands refers to it and because a regulator may
 * ask about the period during which the suspension happened. So reads stay open
 * and writes stop here.
 *
 * A SEPARATE MIDDLEWARE, NOT A FLAG ON requireOrgRole.
 * Every route then states which it is. A boolean parameter defaulting to
 * "writes allowed" is a route that silently permits writing when somebody
 * forgets to pass it, and this is the exact failure it replaces: `requireOrgRole`
 * resolved membership and never looked at the organisation, so a suspended
 * company's reporter kept full write access with an already-issued token.
 */
function requireActiveOrganization(req, res, next) {
  const membership = req.orgMembership;

  if (!membership) {
    // Reached only if a route forgot `requireOrgRole`. Fail closed rather than
    // waving the request through.
    return res.status(403).json({
      error: 'forbidden',
      message: 'You do not have access to that organisation.',
    });
  }

  if (membership.orgWritable !== true) {
    return res.status(403).json({
      error: 'organization_read_only',
      message:
        membership.orgStatus === 'suspended'
          ? 'This workspace is suspended and is read-only. Existing records and '
            + 'documents stay available; nothing new can be submitted or issued.'
          : 'This workspace is not open for changes yet.',
    });
  }

  return next();
}

/**
 * Requires an active membership of at least `minRole` in the organisation this
 * request concerns (SEC-1, SEC-5).
 *
 * WHAT THIS DELIBERATELY DOES NOT DO
 *
 * It does not read an `orgId` from the request body. A route that inferred its
 * tenant from the payload would let any producer name any organisation, and
 * the whole isolation boundary would rest on the client's honesty. The
 * organisation is taken from the route parameter when there is one and
 * otherwise from the caller's own membership — and in the route-parameter case
 * the two must agree, so a valid member of one company cannot address another.
 *
 * It does not read a custom claim (SEC-2). A claim is only as fresh as the
 * client's last token refresh, so a member removed this morning would keep
 * `orgOwner` in their token until it expired. The stored document is re-read
 * on every request, which is what makes revocation immediate.
 *
 * It does not let an administrator through. Admins have their own routes and
 * their own read-only view (EPR-46); a shared code path would produce an audit
 * trail that could not distinguish an owner acting in their company from a
 * Chokro employee acting on it, and a trail that cannot tell those apart is not
 * an audit trail.
 *
 * On success attaches `req.orgMembership = { orgId, orgRole }`. Handlers read
 * the organisation from there and never from `req.body`.
 */
function requireOrgRole(minRole) {
  return async function orgRole(req, res, next) {
    if (!req.user) {
      return res.status(401).json({
        error: 'unauthenticated',
        message: 'Sign in to continue.',
      });
    }

    if (req.user.role !== 'producer') {
      return res.status(403).json({
        error: 'forbidden',
        message: 'This action requires an EPR Producer account.',
      });
    }

    const requestedOrgId = req.params?.orgId || null;

    let membership;
    try {
      membership = requestedOrgId
        ? await organizations.resolveMembership(requestedOrgId, req.user.uid)
        : await organizations.findMembershipForUser(req.user.uid);
    } catch (err) {
      console.error(`Membership lookup for ${req.user.uid} failed:`, err.message);
      return res.status(503).json({
        error: 'account_service_unavailable',
        message: 'The account service is temporarily unavailable. Try again.',
      });
    }

    // One message for "you are not a member" and "that organisation does not
    // exist". Distinguishing them turns this endpoint into a way to enumerate
    // Chokro's customers.
    if (!membership) {
      return res.status(403).json({
        error: 'forbidden',
        message: 'You do not have access to that organisation.',
      });
    }

    if (!organizations.orgRoleAtLeast(membership.orgRole, minRole)) {
      return res.status(403).json({
        error: 'insufficient_org_role',
        message: `This action requires the ${minRole} capability.`,
      });
    }

    req.orgMembership = membership;
    return next();
  };
}

module.exports = {
  requireAuth,
  requireAdmin,
  requireSeller,
  requireProducer,
  requireVerifiedEmail,
  requireFreshAuth,
  requireOrgRole,
  requireActiveOrganization,
};
