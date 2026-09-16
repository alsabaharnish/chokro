/**
 * Chokro — lawful disclosure to the regulator (SEC-13, EPR-33, SEC-3).
 *
 * ## THE ONE OPERATION THAT UNDOES DE-IDENTIFICATION ON PURPOSE
 *
 * A chain-of-custody export gives a producer one row per attribution, and the
 * disposal behind each row appears as `disposalRef` — an HMAC keyed per
 * organisation. That pseudonym is what makes the export releasable at all: two
 * producers who each received a fragment of the same bag cannot compare their
 * exports and reconstruct one Champion's activity.
 *
 * But a pseudonym Chokro cannot reverse is a pseudonym that makes the export
 * unauditable. If the Department of Environment points at a row and asks to
 * see the evidence behind it, somebody has to be able to answer. This module
 * is that answer, and nothing else in the codebase can do it.
 *
 * ## WHY IT IS SHAPED THE WAY IT IS
 *
 * **A lawful basis is required, not optional.** `doeReference` has no default.
 * A disclosure without a recorded reason is not a disclosure, it is a lookup —
 * and a lookup tool over pseudonymised data is the thing SEC-3 exists to
 * prevent somebody building.
 *
 * **The audit entry is written BEFORE the resolution runs**, the way `viewAs`
 * records a view before assembling one. Logging on success would mean a
 * resolution that crashed midway leaves no trace, and that is exactly the
 * resolution somebody would want to leave no trace.
 *
 * **Naming the person is a second, separate act.** Most audits ask "did this
 * collection happen", not "who did it". So the evidence and the identity are
 * two calls with two audit actions, and an Admin who only needed the first
 * cannot acquire the second by accident.
 *
 * **This module holds the key that makes the data personal.** Chokro can
 * reverse the pseudonym, therefore the exported rows are pseudonymised and not
 * anonymised, therefore they remain personal data in most readings of the
 * PDPA. That is counsel question Q5 and this module is the reason it matters.
 * See `docs/DATA_FLOW_MAP.md` §5.
 */

const crypto = require('crypto');

const { db } = require('./firebase');
const audit = require('./producerAudit');
const reportJobs = require('./reportJobs');
const eprPeriod = require('./eprPeriod');

const ATTRIBUTIONS = 'attributions';
const DISPOSALS = 'disposals';
const USERS = 'users';

/**
 * The most attributions one resolution will read.
 *
 * Bounded like every other read here (QA-10). The cap matters more than usual:
 * a resolution that stopped early and reported "not found" would tell a
 * regulator a genuine row is fabricated, which is the worst answer this module
 * could give. So an exhausted scan and a capped one are different results and
 * `exhaustive` says which.
 */
const SCAN_CAP = 20000;

/** A page size that keeps each read modest without making the scan chatty. */
const PAGE = 500;

/**
 * The unkeyed form of the pseudonym, for references minted before the key.
 *
 * `AUDIT_CHAIN_KEY` was unset for part of this service's life, and
 * `reportJobs.pseudonym` silently produces a plain SHA-256 digest in that
 * state. Exports generated then carry unkeyed references that the keyed
 * computation will never match.
 *
 * Trying both is not a weakening of the control — it is the only way to answer
 * honestly about a row that genuinely exists. Which one matched is reported,
 * because a reference that resolves only unkeyed is evidence the export
 * predates keying, and that is worth knowing about an exhibit.
 */
function unkeyedPseudonym(orgId, disposalId) {
  if (!disposalId) return '';
  // Still an HMAC, not a plain hash. `reportJobs.pseudonym` falls back to an
  // EMPTY STRING key rather than to a different algorithm, so the unkeyed form
  // is `createHmac(sha256, ':<orgId>')` — the same construction with a
  // degenerate key. Getting this wrong produces a digest that never matches
  // anything, and the symptom would be Chokro telling a regulator that a
  // genuine row is unknown.
  return crypto
    .createHmac('sha256', `:${orgId}`)
    .update(String(disposalId), 'utf8')
    .digest('hex')
    .slice(0, 24);
}

/**
 * Both forms a stored disposal id could have been exported as.
 *
 * The keyed form comes from `reportJobs.pseudonym` rather than being
 * recomputed here, deliberately: two implementations of the same HMAC are two
 * things that can drift, and the failure mode of drift is a resolution that
 * reports a real row as not found.
 */
function candidateRefs(orgId, disposalId) {
  return {
    keyed: reportJobs.pseudonym(orgId, disposalId),
    unkeyed: unkeyedPseudonym(orgId, disposalId),
  };
}

function badRequest(message) {
  const error = new Error(message);
  error.code = 'bad_request';
  return error;
}

/** A 24-character lowercase hex digest, the shape `pseudonym` produces. */
function isValidRef(value) {
  return typeof value === 'string' && /^[0-9a-f]{24}$/.test(value);
}

/**
 * Resolves one pseudonymous disposal reference back to its evidence.
 *
 * Returns the collection evidence — the disposal, its photograph, the bin and
 * the attributions that cite it. **Never the Champion's identity**; that is
 * `releaseIdentity`, which is a separate act with its own record.
 */
async function resolveDisposalRef({
  orgId,
  disposalRef,
  doeReference,
  periodId = null,
  adminUid,
  adminName = '',
  ip,
  userAgent,
}) {
  if (typeof orgId !== 'string' || orgId.length === 0) {
    throw badRequest('A disclosure must name the organisation whose export the reference came from.');
  }
  if (!isValidRef(disposalRef)) {
    throw badRequest('That is not a disposal reference from a chain-of-custody export.');
  }
  // The lawful basis. Refused rather than defaulted — see the header.
  if (typeof doeReference !== 'string' || doeReference.trim().length < 3) {
    throw badRequest(
      'A disclosure requires the regulator’s reference for the request it '
      + 'answers. Chokro does not resolve a pseudonym without one.',
    );
  }
  if (periodId !== null && !eprPeriod.isValidPeriodId(periodId)) {
    throw badRequest('That is not a reporting period.');
  }
  if (typeof adminUid !== 'string' || adminUid.length === 0) {
    throw badRequest('A disclosure must name the Admin making it.');
  }

  const reference = doeReference.trim();

  // FIRST, and allowed to fail the request.
  await audit.append({
    orgId,
    action: audit.ACTIONS.DISCLOSURE_RESOLVED,
    actorUid: adminUid,
    actorName: adminName,
    actorRole: 'admin',
    targetType: 'disposalRef',
    targetId: disposalRef,
    summary:
      `Admin resolved a pseudonymous disposal reference under regulator `
      + `request ${reference}${periodId ? ` for ${periodId}` : ''}. `
      + 'Collection evidence only; the Champion was not named by this action.',
    ip,
    userAgent,
  });

  const match = await findAttributionsForRef({ orgId, disposalRef, periodId });

  if (!match.disposalId) {
    return {
      found: false,
      // The distinction a regulator's conclusion turns on. "We scanned
      // everything and this row is not ours" and "we stopped early" must never
      // render the same.
      exhaustive: match.exhaustive,
      scanned: match.scanned,
      doeReference: reference,
      note: match.exhaustive
        ? 'No attribution in this organisation produces that reference. Check '
          + 'the organisation — a reference is only meaningful against the '
          + 'export it came from.'
        : `Stopped after ${match.scanned} attributions without a match. This is `
          + 'NOT a finding that the reference is unknown. Narrow by period and '
          + 'try again.',
    };
  }

  const disposalSnap = await db().collection(DISPOSALS).doc(match.disposalId).get();
  const disposal = disposalSnap.exists ? disposalSnap.data() : null;

  return {
    found: true,
    exhaustive: true,
    doeReference: reference,
    // Which key minted the reference. A reference that resolves only unkeyed
    // came from an export generated before AUDIT_CHAIN_KEY was set.
    referenceKeyed: match.keyed,
    disposalId: match.disposalId,

    evidence: disposal === null
      // The attributions survive their disposal — that is the whole point of
      // severing — so a missing disposal is a real state, not an error, and it
      // is reported rather than thrown.
      ? { disposalPresent: false, note: 'The disposal record no longer exists. The attributions below are retained compliance records and remain valid.' }
      : {
          disposalPresent: true,
          photoUrl: disposal.photoUrl ?? null,
          binId: disposal.binId ?? null,
          status: disposal.status ?? null,
          createdAt: disposal.createdAt ?? null,
          // Deliberately absent: userId. See `releaseIdentity`.
        },

    attributions: match.rows,
  };
}

/**
 * Scans one organisation's attributions for the row behind a reference.
 *
 * Attributions rather than disposals, because the reference can only have come
 * from this organisation's export and the organisation's attributions are a far
 * smaller set than every disposal on the platform.
 */
async function findAttributionsForRef({ orgId, disposalRef, periodId }) {
  let query = db().collection(ATTRIBUTIONS).where('orgId', '==', orgId);
  if (periodId) query = query.where('periodId', '==', periodId);
  query = query.orderBy('__name__').limit(PAGE);

  let scanned = 0;
  let cursor = null;
  let disposalId = null;
  let keyed = null;

  while (scanned < SCAN_CAP) {
    const snap = await (cursor ? query.startAfter(cursor) : query).get();
    if (snap.empty) return { disposalId: null, exhaustive: true, scanned, rows: [] };

    for (const doc of snap.docs) {
      scanned += 1;
      const row = doc.data();
      if (!row.disposalId) continue;

      const refs = candidateRefs(orgId, row.disposalId);
      if (refs.keyed === disposalRef) {
        disposalId = row.disposalId;
        keyed = true;
        break;
      }
      if (refs.unkeyed === disposalRef) {
        disposalId = row.disposalId;
        keyed = false;
        break;
      }
    }

    if (disposalId) break;
    if (snap.size < PAGE) return { disposalId: null, exhaustive: true, scanned, rows: [] };
    cursor = snap.docs[snap.docs.length - 1];
  }

  if (!disposalId) return { disposalId: null, exhaustive: false, scanned, rows: [] };

  // Every attribution citing that disposal, not just the one that matched: one
  // disposal can carry several of a producer's SKUs.
  const rowsSnap = await db()
    .collection(ATTRIBUTIONS)
    .where('orgId', '==', orgId)
    .where('disposalId', '==', disposalId)
    .get();

  return {
    disposalId,
    keyed,
    exhaustive: true,
    scanned,
    rows: rowsSnap.docs.map((doc) => {
      const row = doc.data();
      return {
        attributionId: doc.id,
        periodId: row.periodId ?? null,
        skuId: row.skuId ?? null,
        skuRevision: row.skuRevision ?? null,
        units: row.units ?? 0,
        massMg: row.massMg ?? 0,
        gazetteCategory: row.gazetteCategory ?? null,
        method: row.method ?? null,
        confidenceTier: row.confidenceTier ?? null,
        binId: row.binId ?? null,
        district: row.district ?? null,
        createdAt: row.createdAt ?? null,
      };
    }),
  };
}

/**
 * Names the Champion behind a resolved disposal. A separate, separately
 * recorded act.
 *
 * Split from `resolveDisposalRef` because most regulator questions are about
 * whether a collection happened, and answering those should not hand over a
 * person. An Admin who needs only the evidence never touches this function,
 * and the audit log distinguishes the two requests permanently.
 */
async function releaseIdentity({
  orgId,
  disposalId,
  doeReference,
  adminUid,
  adminName = '',
  ip,
  userAgent,
}) {
  if (typeof disposalId !== 'string' || disposalId.length === 0) {
    throw badRequest('An identity release must name the disposal.');
  }
  if (typeof doeReference !== 'string' || doeReference.trim().length < 3) {
    throw badRequest(
      'An identity release requires the regulator’s reference for the request '
      + 'it answers.',
    );
  }
  if (typeof adminUid !== 'string' || adminUid.length === 0) {
    throw badRequest('An identity release must name the Admin making it.');
  }

  const reference = doeReference.trim();

  await audit.append({
    orgId,
    action: audit.ACTIONS.DISCLOSURE_IDENTITY_RELEASED,
    actorUid: adminUid,
    actorName: adminName,
    actorRole: 'admin',
    targetType: 'disposal',
    targetId: disposalId,
    summary:
      `Admin released the identity of the Champion behind disposal `
      + `${disposalId} under regulator request ${reference}. This names a `
      + 'person and is the strongest disclosure Chokro performs.',
    ip,
    userAgent,
  });

  const disposalSnap = await db().collection(DISPOSALS).doc(disposalId).get();
  if (!disposalSnap.exists) {
    return {
      released: false,
      doeReference: reference,
      note:
        'The disposal record no longer exists, so there is no identity to '
        + 'release. Any retained attribution is a record about packaging.',
    };
  }

  const uid = disposalSnap.data().userId ?? null;
  if (!uid) {
    return {
      released: false,
      doeReference: reference,
      note: 'That disposal carries no account reference.',
    };
  }

  const userSnap = await db().collection(USERS).doc(uid).get();
  const user = userSnap.exists ? userSnap.data() : null;

  return {
    released: true,
    doeReference: reference,
    disposalId,
    champion: {
      uid,
      name: user?.name ?? null,
      email: user?.email ?? null,
      accountExists: userSnap.exists,
    },
  };
}

module.exports = {
  resolveDisposalRef,
  releaseIdentity,
  // Exported for the drift test: the keyed candidate MUST equal the pseudonym
  // `reportJobs` mints, or a real row resolves as not found.
  candidateRefs,
  unkeyedPseudonym,
  isValidRef,
  SCAN_CAP,
};
