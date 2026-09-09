/**
 * Chokro — producer organisations, membership and invitations
 * (EPR-3, EPR-4, EPR-40, EPR-41, SEC-1, SEC-2, SEC-8).
 *
 * THE RULE THIS MODULE EXISTS TO ENFORCE
 * Membership is a stored document and nothing else. Not a custom claim, not an
 * `orgId` in a request body, not an email domain. Every authorisation decision
 * in the producer portal — here, in `firestore.rules` and in `requireOrgRole` —
 * resolves the same `organizationMembers/{orgId}_{uid}` document, so a
 * membership revoked in this process takes effect on the next request
 * everywhere, rather than whenever a client next refreshes its token (SEC-2).
 *
 * WHY THERE IS NO SELF-REGISTRATION
 * A company's compliance data is not something anyone should be able to join by
 * filling in a form (EPR-4). An organisation is created and approved by a
 * Chokro Admin against real evidence; members arrive by invitation from an
 * owner or an Admin. The only unauthenticated endpoint in this module is
 * redemption, and redemption requires a 256-bit token that was issued for one
 * exact email address.
 *
 * WHAT IS STORED FOR AN INVITATION, AND WHAT IS NOT
 * The token is never stored. Its SHA-256 digest is, and the digest is the
 * document id — so redemption is a single document read, and a dump of this
 * collection yields nothing that can be redeemed. The link is shown to the
 * inviter exactly once, at the moment of issue, and cannot be recovered
 * afterwards by anyone including Chokro.
 */

const crypto = require('crypto');
const { db, auth, admin, serverTimestamp } = require('./firebase');
const audit = require('./producerAudit');
const passwordPolicy = require('./passwordPolicy');

const ORGS = 'organizations';
const MEMBERS = 'organizationMembers';
const INVITATIONS = 'orgInvitations';

const ORG_ROLES = Object.freeze(['orgOwner', 'orgReporter', 'orgViewer']);
const ORG_STATUSES = Object.freeze([
  'pendingReview',
  'active',
  'suspended',
  'closed',
]);
const SIZE_CLASSES = Object.freeze(['large', 'medium', 'small']);
const COMPLIANCE_ROUTES = Object.freeze(['self', 'pro']);
const GAZETTE_CATEGORIES = Object.freeze([
  'rigid',
  'flexible',
  'eps',
  'singleUse',
  'other',
]);

/** SEC-8: 256 bits, comfortably above the 128-bit floor. */
const TOKEN_BYTES = 32;

/** SEC-8: default expiry. Long enough for a working day either side. */
const INVITATION_TTL_HOURS = 72;

/**
 * SEC-8: per-organisation invitation ceiling within the TTL window.
 *
 * A cap rather than a rate limiter with its own state, because the pending
 * invitations *are* the state: an organisation with twenty live invitations has
 * either a very large compliance team or a problem.
 */
const MAX_PENDING_INVITATIONS = 20;

// ---------------------------------------------------------------------------
// Small pure helpers — no Firebase, unit-testable on their own
// ---------------------------------------------------------------------------

function normalizeEmail(value) {
  return typeof value === 'string' ? value.trim().toLowerCase() : '';
}

/**
 * Deliberately permissive. This is a shape check, not an address validator: the
 * authority on whether an address exists is whether its owner can redeem the
 * invitation sent to it.
 */
function looksLikeEmail(value) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(value);
}

function hashToken(token) {
  return crypto.createHash('sha256').update(token, 'utf8').digest('hex');
}

function generateToken() {
  return crypto.randomBytes(TOKEN_BYTES).toString('base64url');
}

/**
 * Whether `held` carries at least `required`.
 *
 * Mirrors `OrgRoles.atLeast` in Dart and `orgRoleAtLeast` in `firestore.rules`.
 * All three must agree. Fails closed on an unrecognised value in either
 * position.
 */
function orgRoleAtLeast(held, required) {
  const heldRank = ORG_ROLES.indexOf(held);
  const requiredRank = ORG_ROLES.indexOf(required);
  if (heldRank < 0 || requiredRank < 0) return false;
  return heldRank <= requiredRank;
}

function memberDocId(orgId, uid) {
  return `${orgId}_${uid}`;
}

/**
 * A normalised brand key for collision detection (EPR-14).
 *
 * Case, punctuation and spacing are stripped, so "Coca-Cola Bangladesh",
 * "coca cola bangladesh" and "CocaCola  Bangladesh" collide. That is the point:
 * an organisation registering a brand it does not own would not pick a spelling
 * that matches character for character.
 */
function brandKey(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '');
}

function validateOrganizationInput({ legalName, tradeName, contactEmail }) {
  const problems = [];

  if (typeof legalName !== 'string' || legalName.trim().length < 2) {
    problems.push('A registered legal name is required.');
  } else if (legalName.length > 200) {
    problems.push('The legal name is too long.');
  }

  if (typeof tradeName !== 'string' || tradeName.trim().length < 2) {
    problems.push('A trade or brand name is required.');
  } else if (tradeName.length > 200) {
    problems.push('The trade name is too long.');
  }

  const email = normalizeEmail(contactEmail);
  if (!looksLikeEmail(email)) {
    problems.push('A valid contact email address is required.');
  }

  return problems;
}

function sanitizeCategories(value) {
  if (!Array.isArray(value)) return [];
  // Gazette order, deduplicated, unknown values dropped. Mirrors the Dart
  // parser, so a category list never renders in two different orders.
  return GAZETTE_CATEGORIES.filter((c) => value.includes(c));
}

// ---------------------------------------------------------------------------
// Organisations
// ---------------------------------------------------------------------------

/**
 * Creates an organisation in `pendingReview` (EPR-41).
 *
 * Admin-only, because there is no self-registration. The record starts pending
 * even when created by an Admin: the size class that fixes which gazette target
 * applies, and the category scope, are set by the review step against evidence,
 * and skipping straight to active would skip the step that makes the record
 * mean anything.
 */
async function createOrganization({
  legalName,
  tradeName,
  contactName = '',
  contactEmail,
  contactPhone = '',
  address = '',
  district = '',
  city = '',
  bin = null,
  tradeLicenceNo = null,
  adminUid,
  adminName = '',
}) {
  const problems = validateOrganizationInput({
    legalName,
    tradeName,
    contactEmail,
  });
  if (problems.length > 0) {
    const error = new Error(problems.join(' '));
    error.problems = problems;
    throw error;
  }

  const firestore = db();
  const orgRef = firestore.collection(ORGS).doc();

  const collisions = await findBrandCollisions({ tradeName, legalName });

  const record = {
    legalName: legalName.trim(),
    tradeName: tradeName.trim(),
    tradeNameKey: brandKey(tradeName),
    legalNameKey: brandKey(legalName),
    bin: bin || null,
    tradeLicenceNo: tradeLicenceNo || null,
    doeRegistrationNo: null,
    sizeClass: null,
    obligationStartDate: null,
    complianceRoute: 'self',
    status: 'pendingReview',
    categories: [],
    contactName: String(contactName || '').slice(0, 120),
    contactEmail: normalizeEmail(contactEmail),
    contactPhone: String(contactPhone || '').slice(0, 40),
    address: String(address || '').slice(0, 300),
    district: String(district || '').slice(0, 80),
    city: String(city || '').slice(0, 80),
    verifiedBy: null,
    verifiedAt: null,
    createdAt: serverTimestamp(),
  };

  await firestore.runTransaction(async (txn) => {
    // The append first, because it reads the chain head and Firestore requires
    // every read to precede every write. Every other transaction in this module
    // is ordered the same way.
    await audit.appendInTransaction(txn, {
      orgId: orgRef.id,
      action: audit.ACTIONS.ORG_APPLIED,
      actorUid: adminUid,
      actorName: adminName,
      actorRole: 'admin',
      targetType: 'organization',
      targetId: orgRef.id,
      summary: `Organisation record opened for ${record.legalName}.`,
      after: { legalName: record.legalName, tradeName: record.tradeName },
    });

    txn.set(orgRef, record);
  });

  return {
    orgId: orgRef.id,
    status: 'pendingReview',
    // Surfaced, never acted on automatically. EPR-14 makes a collision a
    // blocking flag for a person to resolve, not a rule for code to apply —
    // two genuinely different companies can share a word in their name.
    brandCollisions: collisions,
  };
}

/**
 * Organisations whose brand or legal name normalises to the same key (EPR-14).
 *
 * The motive this looks for is specific: registering a rival's brand to claim
 * the mass collected from its packaging, or registering a popular brand to
 * claim someone else's. Both show up as two organisations with one brand.
 *
 * Bounded (QA-10). More than a handful of hits is itself the finding.
 */
async function findBrandCollisions({ tradeName, legalName, excludeOrgId = null }) {
  const firestore = db();
  const keys = [brandKey(tradeName), brandKey(legalName)].filter(
    (k) => k.length >= 3,
  );
  if (keys.length === 0) return [];

  const seen = new Map();

  for (const key of new Set(keys)) {
    for (const field of ['tradeNameKey', 'legalNameKey']) {
      const snap = await firestore
        .collection(ORGS)
        .where(field, '==', key)
        .limit(10)
        .get();

      for (const d of snap.docs) {
        if (d.id === excludeOrgId) continue;
        const data = d.data();
        seen.set(d.id, {
          orgId: d.id,
          legalName: data.legalName,
          tradeName: data.tradeName,
          status: data.status,
          matchedOn: field,
        });
      }
    }
  }

  return [...seen.values()];
}

/**
 * The onboarding decision (EPR-41).
 *
 * Approval is where `sizeClass` is set, and `sizeClass` decides which gazette
 * targets this entity is measured against and from when. It is therefore
 * mandatory on approval and refused on the client side entirely — a company
 * that could set its own would be choosing its own obligation.
 *
 * @param {'approve'|'reject'|'requestInfo'} decision
 */
async function reviewOrganization({
  orgId,
  decision,
  reason = '',
  sizeClass = null,
  categories = null,
  obligationStartDate = null,
  complianceRoute = null,
  bin = null,
  tradeLicenceNo = null,
  doeRegistrationNo = null,
  adminUid,
  adminName = '',
}) {
  if (!['approve', 'reject', 'requestInfo'].includes(decision)) {
    throw new Error('Unknown review decision.');
  }
  if (decision !== 'approve' && String(reason || '').trim().length < 5) {
    // A rejection or an information request with no stated reason is a dead end
    // for the applicant and an unreviewable act for the auditor.
    throw new Error('A reason is required to reject or request information.');
  }
  if (decision === 'approve') {
    if (!SIZE_CLASSES.includes(sizeClass)) {
      throw new Error(
        'A gazette size class (large, medium or small) is required to approve.',
      );
    }
    if (!(obligationStartDate instanceof Date) || Number.isNaN(obligationStartDate.getTime())) {
      throw new Error('An obligation start date is required to approve.');
    }
    if (complianceRoute !== null && !COMPLIANCE_ROUTES.includes(complianceRoute)) {
      throw new Error('Unknown compliance route.');
    }
  }

  const firestore = db();
  const orgRef = firestore.collection(ORGS).doc(orgId);

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(orgRef);
    if (!snap.exists) throw new Error('That organisation no longer exists.');

    const before = snap.data();
    if (before.status !== 'pendingReview') {
      // Idempotence guard, in the manner of `approveDisposal`. Two Admins
      // pressing approve on the same queue item must not both act.
      throw new Error(
        `That organisation has already been reviewed (${before.status}).`,
      );
    }

    const update = {
      verifiedBy: adminUid,
      verifiedAt: serverTimestamp(),
      reviewReason: String(reason || '').slice(0, 500) || null,
    };

    let action;
    let summary;

    if (decision === 'approve') {
      update.status = 'active';
      update.sizeClass = sizeClass;
      update.obligationStartDate = admin.firestore.Timestamp.fromDate(
        obligationStartDate,
      );
      update.complianceRoute = complianceRoute || 'self';
      update.categories = sanitizeCategories(categories);
      if (bin !== null) update.bin = String(bin).slice(0, 40);
      if (tradeLicenceNo !== null) {
        update.tradeLicenceNo = String(tradeLicenceNo).slice(0, 80);
      }
      if (doeRegistrationNo !== null) {
        update.doeRegistrationNo = String(doeRegistrationNo).slice(0, 80);
      }
      action = audit.ACTIONS.ORG_APPROVED;
      summary = `Onboarding approved as a ${sizeClass} industry.`;
    } else if (decision === 'reject') {
      update.status = 'closed';
      action = audit.ACTIONS.ORG_REJECTED;
      summary = `Onboarding rejected: ${reason}`;
    } else {
      // Stays pending. The applicant is asked for more and the queue keeps it.
      action = audit.ACTIONS.ORG_INFO_REQUESTED;
      summary = `More information requested: ${reason}`;
    }

    await audit.appendInTransaction(txn, {
      orgId,
      action,
      actorUid: adminUid,
      actorName: adminName,
      actorRole: 'admin',
      targetType: 'organization',
      targetId: orgId,
      summary,
      before: { status: before.status, sizeClass: before.sizeClass || null },
      after: { status: update.status || before.status, sizeClass: update.sizeClass || before.sizeClass || null },
    });

    txn.update(orgRef, update);

    return { orgId, status: update.status || before.status, decision };
  });
}

/**
 * Suspends or reinstates an organisation (EPR-47).
 *
 * Suspension makes the portal read-only and stops new issuance. It never
 * deletes: the evidence Chokro has already certified on this producer's behalf
 * must survive, both because a passport already in a third party's hands refers
 * to it and because a regulator may ask about the period during which the
 * suspension happened.
 */
async function setOrganizationStatus({
  orgId,
  status,
  reason = '',
  adminUid,
  adminName = '',
}) {
  if (!['active', 'suspended', 'closed'].includes(status)) {
    throw new Error('Unknown organisation status.');
  }
  if (status !== 'active' && String(reason || '').trim().length < 5) {
    throw new Error('A reason is required to suspend or close an organisation.');
  }

  const firestore = db();
  const orgRef = firestore.collection(ORGS).doc(orgId);

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(orgRef);
    if (!snap.exists) throw new Error('That organisation no longer exists.');

    const before = snap.data();
    if (before.status === status) {
      throw new Error(`That organisation is already ${status}.`);
    }
    if (before.status === 'pendingReview') {
      throw new Error('Review that organisation before changing its status.');
    }

    await audit.appendInTransaction(txn, {
      orgId,
      action:
        status === 'active'
          ? audit.ACTIONS.ORG_REINSTATED
          : audit.ACTIONS.ORG_SUSPENDED,
      actorUid: adminUid,
      actorName: adminName,
      actorRole: 'admin',
      targetType: 'organization',
      targetId: orgId,
      summary:
        status === 'active'
          ? 'Organisation reinstated.'
          : `Organisation ${status}: ${reason}`,
      before: { status: before.status },
      after: { status },
    });

    txn.update(orgRef, {
      status,
      statusReason: String(reason || '').slice(0, 500) || null,
      statusChangedAt: serverTimestamp(),
      statusChangedBy: adminUid,
    });

    return { orgId, status };
  });
}

/** The Admin producer directory (EPR-40). Bounded (QA-10). */
async function listOrganizations({ status = null, limit = 200 } = {}) {
  let q = db().collection(ORGS);
  if (status) q = q.where('status', '==', status);

  const snap = await q.orderBy('createdAt', 'desc').limit(limit).get();
  return snap.docs.map((d) => ({ orgId: d.id, ...d.data() }));
}

async function getOrganization(orgId) {
  const snap = await db().collection(ORGS).doc(orgId).get();
  if (!snap.exists) return null;
  return { orgId: snap.id, ...snap.data() };
}

// ---------------------------------------------------------------------------
// Membership
// ---------------------------------------------------------------------------

/**
 * The single question every producer-facing authorisation asks (SEC-1).
 *
 * One document read against a path composed from `orgId` and `uid`. Returns
 * null for absent, invited or removed — an invitation is not a membership, and
 * neither is a revoked one.
 */
async function resolveMembership(orgId, uid) {
  if (!orgId || !uid) return null;

  const firestore = db();

  // Both documents, because both decide what this request may do. The
  // membership says whether this person belongs and in what capacity; the
  // organisation says whether its workspace is open at all.
  //
  // Reading only the membership is what let a suspended organisation keep
  // writing: suspension sets `organizations.status`, and it does not touch a
  // single membership document, so every member kept full write access with an
  // already-issued token. EPR-47 makes suspension mean "portal read-only, no
  // new issuance", and that has to be enforced where the writes are.
  const [memberSnap, orgSnap] = await Promise.all([
    firestore.collection(MEMBERS).doc(memberDocId(orgId, uid)).get(),
    firestore.collection(ORGS).doc(orgId).get(),
  ]);

  if (!memberSnap.exists) return null;

  const data = memberSnap.data();
  if (data.status !== 'active') return null;
  if (!ORG_ROLES.includes(data.orgRole)) return null;

  // A membership of an organisation that no longer exists is not a membership.
  if (!orgSnap.exists) return null;

  const orgStatus = orgSnap.data().status;

  return {
    orgId,
    uid,
    orgRole: data.orgRole,
    status: data.status,
    orgStatus,
    // Resolved here rather than compared at each call site, so "may this
    // organisation be written to" has one answer in one place.
    orgWritable: orgStatus === 'active',
  };
}

/**
 * The organisation this user belongs to, if any.
 *
 * v1 is one organisation per user (§16 puts multi-organisation membership out
 * of scope), so this returns the first active membership rather than a list.
 * The query is over `uid` and `status`, which is exactly the composite index
 * EPR-8 names.
 */
async function findMembershipForUser(uid) {
  const snap = await db()
    .collection(MEMBERS)
    .where('uid', '==', uid)
    .where('status', '==', 'active')
    .limit(1)
    .get();

  if (snap.empty) return null;
  const data = snap.docs[0].data();

  // Delegated rather than assembled here, so both resolution paths return the
  // same shape and the same `orgWritable` answer. Two membership resolvers that
  // disagree about whether an organisation is writable is a hole by
  // construction.
  return resolveMembership(data.orgId, uid);
}

/** One organisation's members and pending invitations. Bounded (QA-10). */
async function listMembers({ orgId, limit = 50 }) {
  const snap = await db()
    .collection(MEMBERS)
    .where('orgId', '==', orgId)
    .limit(limit)
    .get();

  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

/**
 * Changes a member's organisation role.
 *
 * Refuses to remove the last active owner, in the same breath and the same
 * transaction as the change. An organisation with no owner cannot invite, and
 * cannot attest a declaration — it would need a Chokro Admin to repair it, which
 * turns an ordinary administrative slip into a support ticket.
 */
async function changeMemberRole({ orgId, uid, orgRole, actorUid, actorName = '', actorRole = 'producer' }) {
  if (!ORG_ROLES.includes(orgRole)) throw new Error('Unknown organisation role.');

  const firestore = db();
  const memberRef = firestore.collection(MEMBERS).doc(memberDocId(orgId, uid));

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(memberRef);
    if (!snap.exists) throw new Error('That member does not exist.');

    const before = snap.data();
    if (before.status !== 'active') {
      throw new Error('That member is not active.');
    }
    if (before.orgRole === orgRole) {
      throw new Error(`That member is already ${orgRole}.`);
    }

    if (before.orgRole === 'orgOwner') {
      const owners = await txn.get(
        firestore
          .collection(MEMBERS)
          .where('orgId', '==', orgId)
          .where('orgRole', '==', 'orgOwner')
          .where('status', '==', 'active')
          .limit(2),
      );
      if (owners.size <= 1) {
        throw new Error(
          'An organisation must keep at least one owner. Promote someone else first.',
        );
      }
    }

    await audit.appendInTransaction(txn, {
      orgId,
      action: audit.ACTIONS.MEMBER_ROLE_CHANGED,
      actorUid,
      actorName,
      actorRole,
      targetType: 'member',
      targetId: uid,
      summary: `Member role changed from ${before.orgRole} to ${orgRole}.`,
      before: { orgRole: before.orgRole },
      after: { orgRole },
    });

    txn.update(memberRef, { orgRole, roleChangedAt: serverTimestamp() });

    return { orgId, uid, orgRole };
  });
}

/**
 * Removes a member (SEC-2).
 *
 * The membership is marked `removed`, never deleted — the audit trail refers to
 * it, and a deleted row makes "who had access in September?" unanswerable.
 *
 * Revocation takes effect on the next request because every authorisation
 * decision re-reads this document. It does *not* wait for the removed person's
 * token to expire, which is what makes this different from clearing a claim.
 */
async function removeMember({ orgId, uid, actorUid, actorName = '', actorRole = 'producer' }) {
  const firestore = db();
  const memberRef = firestore.collection(MEMBERS).doc(memberDocId(orgId, uid));

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(memberRef);
    if (!snap.exists) throw new Error('That member does not exist.');

    const before = snap.data();
    if (before.status === 'removed') {
      throw new Error('That member has already been removed.');
    }

    if (before.orgRole === 'orgOwner' && before.status === 'active') {
      const owners = await txn.get(
        firestore
          .collection(MEMBERS)
          .where('orgId', '==', orgId)
          .where('orgRole', '==', 'orgOwner')
          .where('status', '==', 'active')
          .limit(2),
      );
      if (owners.size <= 1) {
        throw new Error(
          'An organisation must keep at least one owner. Promote someone else first.',
        );
      }
    }

    await audit.appendInTransaction(txn, {
      orgId,
      action: audit.ACTIONS.MEMBER_REMOVED,
      actorUid,
      actorName,
      actorRole,
      targetType: 'member',
      targetId: uid,
      summary: `Member removed (${before.orgRole}).`,
      before: { orgRole: before.orgRole, status: before.status },
      after: { status: 'removed' },
    });

    txn.update(memberRef, {
      status: 'removed',
      removedAt: serverTimestamp(),
      removedBy: actorUid,
    });

    return { orgId, uid, status: 'removed' };
  });
}

// ---------------------------------------------------------------------------
// Invitations (SEC-8)
// ---------------------------------------------------------------------------

/**
 * Issues a single-use invitation.
 *
 * Returns the token **once**. It is not stored and cannot be recovered: the
 * document id is its SHA-256 digest, so a dump of this collection yields
 * nothing redeemable, and a Chokro Admin reading the database cannot mint
 * access to a customer's workspace from it.
 */
async function createInvitation({
  orgId,
  email,
  orgRole,
  actorUid,
  actorName = '',
  actorRole = 'producer',
  ttlHours = INVITATION_TTL_HOURS,
}) {
  const normalized = normalizeEmail(email);
  if (!looksLikeEmail(normalized)) {
    throw new Error('A valid work email address is required.');
  }
  if (!ORG_ROLES.includes(orgRole)) {
    throw new Error('Unknown organisation role.');
  }

  const firestore = db();

  const orgSnap = await firestore.collection(ORGS).doc(orgId).get();
  if (!orgSnap.exists) throw new Error('That organisation does not exist.');
  if (orgSnap.data().status !== 'active') {
    // A suspended or pending organisation must not grow. Its workspace is
    // read-only, and an invitation is a write to the tenancy boundary.
    throw new Error('That organisation is not active.');
  }

  const now = new Date();

  // SEC-8's per-organisation ceiling, measured over live invitations.
  //
  // THE EXPIRY FILTER IS IN THE QUERY, NOT ONLY IN THE FILTER AFTERWARDS.
  //
  // It used to fetch 21 documents `where status == 'pending'` and drop the
  // expired ones in JavaScript. Expiry is resolved lazily and nothing rewrites
  // a lapsed invitation's status (NFR-E-2), so `status: 'pending'` accumulates
  // for the life of the organisation. Once 21 stale rows existed, the page was
  // entirely stale, `live` came back empty, and *neither* the ceiling nor the
  // one-live-invitation-per-address check fired — so an owner could mint
  // unlimited concurrent tokens for one address, which is precisely the
  // single-use guarantee SEC-8 exists to provide.
  //
  // Filtering on `expiresAt` in the query means the page is of live
  // invitations, whatever has accumulated behind them. Costs the composite
  // index `orgInvitations(orgId, status, expiresAt)`.
  const pending = await firestore
    .collection(INVITATIONS)
    .where('orgId', '==', orgId)
    .where('status', '==', 'pending')
    .where('expiresAt', '>', admin.firestore.Timestamp.fromDate(now))
    .limit(MAX_PENDING_INVITATIONS + 1)
    .get();

  // Re-checked in JavaScript as well. The query bound is authoritative; this
  // costs nothing and keeps the invariant true even against a document whose
  // `expiresAt` is the wrong type.
  const live = pending.docs.filter((d) => {
    const expires = d.data().expiresAt;
    return expires?.toDate && expires.toDate() > now;
  });

  if (live.length >= MAX_PENDING_INVITATIONS) {
    throw new Error(
      'This organisation has too many invitations outstanding. Revoke one first.',
    );
  }

  // One live invitation per address. A second link to the same person is a
  // second way in, and revoking the first would no longer close the door.
  const duplicate = live.find((d) => d.data().email === normalized);
  if (duplicate) {
    throw new Error(
      'An invitation to that address is already outstanding. Revoke it to issue a new one.',
    );
  }

  const token = generateToken();
  const tokenHash = hashToken(token);
  const expiresAt = new Date(now.getTime() + ttlHours * 60 * 60 * 1000);

  await firestore.runTransaction(async (txn) => {
    const inviteRef = firestore.collection(INVITATIONS).doc(tokenHash);

    await audit.appendInTransaction(txn, {
      orgId,
      action: audit.ACTIONS.MEMBER_INVITED,
      actorUid,
      actorName,
      actorRole,
      targetType: 'invitation',
      targetId: tokenHash,
      // The address is in the summary because the organisation is entitled to
      // know who was invited to its own workspace. The token is not.
      summary: `Invited ${normalized} as ${orgRole}.`,
      after: { email: normalized, orgRole },
    });

    txn.set(inviteRef, {
      orgId,
      email: normalized,
      orgRole,
      status: 'pending',
      invitedBy: actorUid,
      invitedAt: serverTimestamp(),
      expiresAt: admin.firestore.Timestamp.fromDate(expiresAt),
      acceptedAt: null,
      acceptedByUid: null,
      revokedAt: null,
      revokedBy: null,
    });
  });

  return {
    invitationId: tokenHash,
    orgId,
    email: normalized,
    orgRole,
    expiresAt: expiresAt.toISOString(),
    // Shown once, to the inviter. Never returned again by any endpoint.
    token,
  };
}

async function revokeInvitation({ invitationId, actorUid, actorName = '', actorRole = 'producer', orgId = null }) {
  const firestore = db();
  const inviteRef = firestore.collection(INVITATIONS).doc(invitationId);

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(inviteRef);
    if (!snap.exists) throw new Error('That invitation does not exist.');

    const invitation = snap.data();
    // The caller's authority was resolved against one organisation; an
    // invitation id from a different one must not be actionable with it.
    if (orgId && invitation.orgId !== orgId) {
      throw new Error('That invitation does not exist.');
    }
    if (invitation.status !== 'pending') {
      throw new Error(`That invitation is already ${invitation.status}.`);
    }

    await audit.appendInTransaction(txn, {
      orgId: invitation.orgId,
      action: audit.ACTIONS.MEMBER_INVITATION_REVOKED,
      actorUid,
      actorName,
      actorRole,
      targetType: 'invitation',
      targetId: invitationId,
      summary: `Invitation to ${invitation.email} revoked.`,
      before: { status: 'pending' },
      after: { status: 'revoked' },
    });

    txn.update(inviteRef, {
      status: 'revoked',
      revokedAt: serverTimestamp(),
      revokedBy: actorUid,
    });

    return { invitationId, status: 'revoked' };
  });
}

/**
 * One organisation's invitations, without the tokens (there are none to give).
 *
 * `expired` is resolved lazily at read time, in the pattern of
 * `UserModel.isActiveAt` and for the same reason: nothing is running that could
 * flip a status when a clock passes (§3.3, NFR-E-2). The stored status stays
 * `pending`; every reader decides for itself.
 */
async function listInvitations({ orgId, limit = 50 }) {
  const snap = await db()
    .collection(INVITATIONS)
    .where('orgId', '==', orgId)
    .orderBy('invitedAt', 'desc')
    .limit(limit)
    .get();

  const now = new Date();

  return snap.docs.map((d) => {
    const data = d.data();
    const expiresAt = data.expiresAt ? data.expiresAt.toDate() : null;
    const expired = data.status === 'pending' && expiresAt !== null && expiresAt <= now;
    return {
      invitationId: d.id,
      orgId: data.orgId,
      email: data.email,
      orgRole: data.orgRole,
      status: expired ? 'expired' : data.status,
      invitedBy: data.invitedBy,
      expiresAt: expiresAt ? expiresAt.toISOString() : null,
    };
  });
}

/**
 * Redeems an invitation, creating the producer account (EPR-4, SEC-8).
 *
 * The only unauthenticated write path in this feature, and shaped accordingly:
 *
 * - The token is the whole authorisation. It is 256 bits, single-use, expiring,
 *   and bound to one address that the caller cannot change.
 * - The password is checked against the server-side policy before an account
 *   exists, not after (EPR-5).
 * - An address that already has a Chokro account is refused rather than
 *   converted. A Champion with a wallet and a disposal history must not become
 *   a producer, because the two roles are disjoint (EPR-1) and merging them
 *   would put one account on both sides of the same evidence.
 *
 * ORDER OF OPERATIONS, AND WHY
 * The Firebase Auth account is created before the Firestore transaction,
 * because Auth is not transactional with Firestore and there is no way to make
 * it so. If the transaction then fails, the auth account is deleted — a
 * compensating action, not a rollback. The residue of a failure is therefore an
 * unusable auth account at worst, never a redeemed invitation with no
 * membership behind it.
 */
async function redeemInvitation({ token, name, password }) {
  if (typeof token !== 'string' || token.length < 20) {
    throw invitationError('This invitation link is not valid.');
  }
  if (typeof name !== 'string' || name.trim().length < 2 || name.length > 80) {
    throw invitationError('Enter your name.');
  }

  const firestore = db();
  const tokenHash = hashToken(token);
  const inviteRef = firestore.collection(INVITATIONS).doc(tokenHash);
  const inviteSnap = await inviteRef.get();

  // One message for every unusable invitation — unknown, revoked, expired,
  // already redeemed. Distinguishing them tells someone holding a stolen link
  // which organisations exist and which addresses have been invited.
  if (!inviteSnap.exists) throw invitationError();

  const invitation = inviteSnap.data();
  if (invitation.status !== 'pending') throw invitationError();

  const expiresAt = invitation.expiresAt ? invitation.expiresAt.toDate() : null;
  if (!expiresAt || expiresAt <= new Date()) throw invitationError();

  const orgSnap = await firestore.collection(ORGS).doc(invitation.orgId).get();
  if (!orgSnap.exists || orgSnap.data().status !== 'active') {
    throw invitationError();
  }
  const organization = orgSnap.data();

  const problems = passwordPolicy.validatePassword(password, {
    email: invitation.email,
    name,
    organizationName: organization.tradeName || organization.legalName,
  });
  if (problems.length > 0) {
    const error = new Error(problems.join(' '));
    error.code = 'weak_password';
    error.problems = problems;
    throw error;
  }

  // An existing account is a refusal, not a conversion.
  try {
    await auth().getUserByEmail(invitation.email);
    const error = new Error(
      'An account already exists for that address. Ask a 3ZERO Admin to help.',
    );
    error.code = 'email_in_use';
    throw error;
  } catch (err) {
    if (err.code === 'email_in_use') throw err;
    if (err.code !== 'auth/user-not-found') {
      console.error('Invitation lookup failed:', err.message);
      const error = new Error('The account service is temporarily unavailable.');
      error.code = 'unavailable';
      throw error;
    }
  }

  const created = await auth().createUser({
    email: invitation.email,
    password,
    displayName: name.trim(),
    emailVerified: false,
  });

  try {
    await firestore.runTransaction(async (txn) => {
      const freshInvite = await txn.get(inviteRef);
      // Re-checked inside the transaction: two people opening the same link at
      // the same time must not both get an account, and the first commit wins.
      if (!freshInvite.exists || freshInvite.data().status !== 'pending') {
        throw invitationError();
      }

      const memberRef = firestore
        .collection(MEMBERS)
        .doc(memberDocId(invitation.orgId, created.uid));

      await audit.appendInTransaction(txn, {
        orgId: invitation.orgId,
        action: audit.ACTIONS.MEMBER_ACTIVATED,
        actorUid: created.uid,
        actorName: name.trim(),
        actorRole: 'producer',
        targetType: 'member',
        targetId: created.uid,
        summary: `${invitation.email} joined as ${invitation.orgRole}.`,
        after: { orgRole: invitation.orgRole, status: 'active' },
      });

      txn.set(firestore.collection('users').doc(created.uid), {
        name: name.trim(),
        email: invitation.email,
        role: 'producer',
        status: 'active',
        createdAt: serverTimestamp(),
      });

      txn.set(memberRef, {
        orgId: invitation.orgId,
        uid: created.uid,
        orgRole: invitation.orgRole,
        status: 'active',
        email: invitation.email,
        displayName: name.trim(),
        invitedBy: invitation.invitedBy,
        invitedAt: invitation.invitedAt,
        activatedAt: serverTimestamp(),
        removedAt: null,
      });

      txn.update(inviteRef, {
        status: 'accepted',
        acceptedAt: serverTimestamp(),
        acceptedByUid: created.uid,
      });
    });
  } catch (err) {
    // Compensating action. Leaving the auth account behind would block the
    // address from ever being invited again, by the check above.
    try {
      await auth().deleteUser(created.uid);
    } catch (cleanupErr) {
      console.error(
        `Invitation rollback left auth account ${created.uid}:`,
        cleanupErr.message,
      );
    }
    throw err;
  }

  return {
    uid: created.uid,
    email: invitation.email,
    orgId: invitation.orgId,
    orgRole: invitation.orgRole,
  };
}

function invitationError(message) {
  const error = new Error(
    message || 'This invitation link is no longer valid. Ask for a new one.',
  );
  error.code = 'invalid_invitation';
  return error;
}

module.exports = {
  ORGS,
  MEMBERS,
  INVITATIONS,
  ORG_ROLES,
  ORG_STATUSES,
  SIZE_CLASSES,
  COMPLIANCE_ROUTES,
  GAZETTE_CATEGORIES,
  INVITATION_TTL_HOURS,
  MAX_PENDING_INVITATIONS,
  normalizeEmail,
  looksLikeEmail,
  hashToken,
  generateToken,
  orgRoleAtLeast,
  memberDocId,
  brandKey,
  validateOrganizationInput,
  sanitizeCategories,
  createOrganization,
  findBrandCollisions,
  reviewOrganization,
  setOrganizationStatus,
  listOrganizations,
  getOrganization,
  resolveMembership,
  findMembershipForUser,
  listMembers,
  changeMemberRole,
  removeMember,
  createInvitation,
  revokeInvitation,
  listInvitations,
  redeemInvitation,
};
