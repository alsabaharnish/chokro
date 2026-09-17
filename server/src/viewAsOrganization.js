/**
 * Chokro — the read-only organisation view (EPR-46, SEC-12).
 *
 * ===========================================================================
 * WHY THIS IS NOT IMPERSONATION, AND WHY THAT IS THE WHOLE DESIGN
 * ===========================================================================
 *
 * EPR-46 is emphatic: "There is **no impersonation** — no Admin action is ever
 * taken under a producer's identity, because an audit trail that cannot
 * distinguish the two is not an audit trail (SEC-12)."
 *
 * The tempting implementation is a flag on `requireOrgRole` that lets an
 * administrator through. It would be a dozen lines and it would destroy the
 * property the audit chain exists for: every subsequent write would be
 * indistinguishable from the producer's own, and Chokro could no longer answer
 * "did the producer file this, or did we?" — which is the first question anyone
 * asks about a disputed figure.
 *
 * `requireOrgRole` therefore refuses administrators, deliberately and with a
 * comment saying so. This module is the separate path: it READS, it never
 * writes, and it is reachable only through `requireAdmin`.
 *
 * ===========================================================================
 * IT MUST BE THE SAME VIEW, NOT A SIMILAR ONE
 * ===========================================================================
 *
 * An Admin looking at a producer's screen is usually doing it because the
 * producer has phoned to ask about a figure. A view assembled from a second,
 * Admin-flavoured code path would drift — and the drift would show up exactly
 * when it matters, with the Admin insisting the screen says one thing while the
 * producer reads another.
 *
 * So every figure here comes from the SAME projection the producer's own routes
 * use: `eprPeriods.projectForProducer`, which applies the k-anonymity floor
 * (SEC-3), and the same declaration and passport accessors. The Admin sees the
 * producer's view including its suppressions — not a privileged version of it.
 *
 * That is a deliberate limitation. An Admin who needs the unsuppressed district
 * breakdown has the reconciliation console and the anomaly queue for that; this
 * view answers "what is the producer looking at", and answering it with
 * something the producer cannot see would make it useless for the purpose.
 *
 * ===========================================================================
 * A VIEW THAT CANNOT BE LOGGED DID NOT HAPPEN
 * ===========================================================================
 *
 * The audit entry is written BEFORE the data is assembled, and a failure to
 * write it refuses the whole request. Reading a customer's compliance position
 * without a record of having done so is the insider behaviour SEC-12 exists to
 * make visible, and "the log was briefly unavailable" is not a reason to make
 * an exception — it is precisely when an exception would be convenient.
 */

const { db } = require('./firebase');
const audit = require('./producerAudit');
const eprPeriod = require('./eprPeriod');
const eprPeriods = require('./eprPeriods');
const eprPolicy = require('./eprPolicy');
const declarations = require('./declarations');
const passports = require('./passports');
const producerSkus = require('./producerSkus');
const organizations = require('./organizations');

const ORGS = 'organizations';
const MEMBERS = 'organizationMembers';

/**
 * Assembles what a producer sees, for an Admin, with the view recorded.
 *
 * `periodId` selects which reporting period the workspace is showing, the same
 * way the producer's own period selector does.
 */
async function viewAs({ orgId, periodId, adminUid, adminName = '', ip, userAgent }) {
  if (periodId && !eprPeriod.isValidPeriodId(periodId)) {
    throw badRequest('That is not a reporting period.');
  }

  const orgSnap = await db().collection(ORGS).doc(orgId).get();
  if (!orgSnap.exists) throw badRequest('That organisation does not exist.');
  const organization = orgSnap.data();

  const period = periodId || eprPeriod.periodIdFor(new Date());

  // FIRST, and allowed to fail the request.
  //
  // Recording the view before reading the data means a crash midway through
  // assembly still leaves the record. The alternative — log on success — would
  // mean a failed read of a customer's compliance position leaves no trace,
  // which is exactly the read somebody would want to leave no trace.
  await audit.append({
    orgId,
    action: audit.ACTIONS.ADMIN_VIEWED_AS_ORG,
    actorUid: adminUid,
    actorName: adminName,
    actorRole: 'admin',
    targetType: 'organization',
    targetId: orgId,
    summary:
      `Admin opened the read-only organisation view for ${period}. `
      + 'No action was taken under the producer’s identity.',
    ip,
    userAgent,
  });

  const [policy, rollup, declaration, issued, skus, members] = await Promise.all([
    eprPolicy.readPolicy(),
    eprPeriods.getPeriod({ orgId, periodId: period }),
    declarations.getDeclaration({ orgId, periodId: period }),
    passports.listPassports({ orgId, limit: 24 }),
    producerSkus.listSkus({ orgId, limit: 50 }),
    readMembers(orgId),
  ]);

  return {
    // Flagged in the payload as well as in the route, so a client that
    // rendered this without the visually distinct treatment EPR-46 requires
    // would have had to ignore something explicit.
    readOnly: true,
    viewedAs: true,
    impersonation: false,

    organization: {
      orgId,
      legalName: organization.legalName ?? '',
      tradeName: organization.tradeName ?? '',
      status: organization.status ?? 'unknown',
      sizeClass: organization.sizeClass ?? null,
      doeRegistrationNo: organization.doeRegistrationNo ?? null,
      complianceRoute: organization.complianceRoute ?? null,
      obligationStartDate: organization.obligationStartDate ?? null,
    },

    periodId: period,

    // THE SAME PROJECTION THE PRODUCER'S OWN ROUTE USES, k-anonymity floor
    // included. An Admin seeing a district breakdown the producer cannot see
    // would be looking at a different screen from the one being discussed.
    period: eprPeriods.projectForProducer(
      rollup ?? { orgId, periodId: period },
      policy,
    ),

    declaration: declaration ?? null,

    passports: issued.map((p) => ({
      serial: p.serial,
      periodId: p.periodId,
      status: p.status,
      contentHash: p.contentHash,
      issuedAt: p.issuedAt ?? null,
    })),

    skus: skus.map((sku) => ({
      id: sku.id,
      name: sku.name,
      brand: sku.brand,
      gazetteCategory: sku.gazetteCategory,
      status: sku.status,
      massStatus: sku.massStatus,
      verifiedUnitMassMg: sku.verifiedUnitMassMg ?? null,
    })),

    members,

    // What the Admin may do from here: nothing. Stated in the payload so a
    // client does not have to infer it, and so a future route that started
    // allowing writes would have to change this deliberately.
    capabilities: {
      canWrite: false,
      canFile: false,
      canIssue: false,
      note:
        'This is a read-only view of what the producer sees. No action can be '
        + 'taken from it under the producer’s identity — Admin actions go '
        + 'through the Admin routes and are recorded as Chokro’s, not the '
        + 'producer’s.',
    },
  };
}

/**
 * The membership list, without contact details.
 *
 * An Admin needs to know who has access in order to answer "who filed this".
 * They do not need the members' email addresses to answer it, and this view is
 * opened routinely — a support call, a query about a figure — so it carries the
 * least that makes it useful.
 */
async function readMembers(orgId) {
  const snap = await db()
    .collection(MEMBERS)
    .where('orgId', '==', orgId)
    .where('status', '==', 'active')
    .limit(50)
    .get();

  return snap.docs
    .map((d) => d.data())
    .map((member) => ({
      uid: member.uid,
      orgRole: member.orgRole,
      status: member.status,
      activatedAt: member.activatedAt ?? null,
    }))
    // Owners first. `ORG_ROLES` is already in descending-capability order,
    // and is the same list `orgRoleAtLeast` ranks against — so the display
    // order cannot drift from the permission order.
    .sort(
      (a, b) =>
        organizations.ORG_ROLES.indexOf(a.orgRole)
        - organizations.ORG_ROLES.indexOf(b.orgRole),
    );
}

/**
 * One organisation's chronological activity, for export (EPR-44).
 *
 * EPR-44: "A single chronological view over the `producerAuditLog`: member
 * invited, SKU submitted, mass verified, declaration filed, report generated,
 * passport issued, passport superseded. Exportable. This *is* the 'track each
 * company and their activities' requirement."
 *
 * Ordered by `sequence` rather than by timestamp, which `listForOrg` already
 * gets right and is worth restating: `sequence` is inside the chain digest and
 * the timestamp is not, so ordering by the clock would let an insider reorder
 * the visible timeline — placing a mass verification before the declaration it
 * informed — without breaking the chain.
 */
async function activityTimeline({ orgId, limit = 500 }) {
  const entries = await audit.listForOrg({ orgId, limit });

  return {
    orgId,
    entries: entries.map((entry) => ({
      sequence: entry.sequence,
      timestamp: entry.timestamp ?? null,
      action: entry.action,
      actorRole: entry.actorRole,
      // The actor's name where it was recorded, and the uid always. A timeline
      // an auditor reads needs to say WHO, and the uid is the part that cannot
      // be edited into something else later.
      actorUid: entry.actorUid,
      actorName: entry.actorName ?? '',
      targetType: entry.targetType ?? null,
      targetId: entry.targetId ?? null,
      summary: entry.summary ?? '',
    })),
    // The chain's integrity is a property of the whole sequence, so the export
    // says whether it was checked rather than leaving a reader to assume.
    verified: null,
  };
}

/**
 * The timeline with its hash chain verified (EPR-44, SEC-12).
 *
 * Separate from `activityTimeline` because verification walks the whole chain
 * and a screen refreshing a list should not pay for it. An export should.
 */
async function verifiedTimeline({ orgId, limit = 500 }) {
  const [timeline, verification] = await Promise.all([
    activityTimeline({ orgId, limit }),
    audit.verifyChain({ orgId }),
  ]);

  return {
    ...timeline,
    verified: verification.intact === true,
    // Which of the three non-intact answers this is: `broken` (a defect was
    // found), `noChain` (the organisation predates the log) or `partial` (the
    // scan hit its limit). `verified` stays the authoritative signal — a client
    // that does not understand a future value here still reads `false` and
    // treats it as unverified.
    chainState: verification.state,
    // Whether the chain is an HMAC under an operator-held key or a bare hash
    // anyone with read access can recompute. `producerAudit` makes the point
    // itself: a console that printed "intact" without saying which would be
    // overstating the control — an unkeyed chain is tamper-evident against
    // anything WITHOUT write access, and is not evidence against the insider
    // SEC-12 names.
    keyed: verification.keyed === true,
    verificationCaveat: verification.keyed
      ? null
      : 'This chain is an unkeyed hash. It detects tampering by anyone without '
        + 'write access to Firestore, and is NOT evidence against someone who '
        + 'holds the database credential. Set AUDIT_CHAIN_KEY before relying '
        + 'on it in a dispute.',
    verification,
  };
}

function badRequest(message) {
  const error = new Error(message);
  error.code = 'bad_request';
  return error;
}

module.exports = {
  viewAs,
  activityTimeline,
  verifiedTimeline,
  readMembers,
};
