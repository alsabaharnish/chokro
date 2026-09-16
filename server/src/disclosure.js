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
 * **A declaration, not just a reference.** The regulator's request number says
 * WHICH request this answers. It does not say why this Admin is resolving this
 * reference, and six months later that is the thing nobody will remember. So a
 * written justification is required alongside it, long enough to be a sentence
 * rather than a keystroke.
 *
 * **Recent proof of the credential.** These routes carry `requireFreshAuth`
 * (SEC-9): an Admin who signed in this morning and left the tab open must
 * prove possession of their password again before de-identifying anybody.
 *
 * NOTE ON WHERE THE PASSWORD GOES: nowhere near this service. The client
 * re-authenticates against Firebase directly, which refreshes `auth_time` in
 * the token; the server reads that claim and refuses a stale one. Chokro never
 * receives, forwards or stores the password, and there is no code path here
 * that could.
 *
 * **Where the Admin was.** Recorded when the browser grants it and recorded as
 * REFUSED when it does not — never left blank. A blank reads as "not
 * collected"; a refusal is a fact about the access and belongs in its record.
 *
 * **This module holds the key that makes the data personal.** Chokro can
 * reverse the pseudonym, therefore the exported rows are pseudonymised and not
 * anonymised, therefore they remain personal data in most readings of the
 * PDPA. That is counsel question Q5 and this module is the reason it matters.
 * See `docs/DATA_FLOW_MAP.md` §5.
 */

const crypto = require('crypto');

const { db, serverTimestamp } = require('./firebase');
const audit = require('./producerAudit');
const reportJobs = require('./reportJobs');
const eprPeriod = require('./eprPeriod');

const ATTRIBUTIONS = 'attributions';
const DISPOSALS = 'disposals';
const USERS = 'users';
/**
 * The readable register of every disclosure.
 *
 * The audit chain already records these and is tamper-evident, which is what
 * makes it EVIDENCE. It is also a hash-linked list of summary strings, which
 * makes it a poor thing to read. This collection is the other half: structured,
 * queryable, and answering "who resolved what, when, from where, and why"
 * without walking a chain.
 *
 * Both are written. Neither replaces the other — the chain proves the register
 * has not been edited, and the register is the one a person actually reads.
 */
const REGISTER = 'disclosureLog';

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

/**
 * The Admin's written reason. A sentence, not a keystroke.
 *
 * Twenty characters is deliberately low as a bar and deliberately non-zero as a
 * principle: it stops 'x' and 'test' without pretending a length check is a
 * quality check. What actually makes this field work is that it is read back on
 * the register, by somebody who was not there.
 */
function normaliseDeclaration(value) {
  if (typeof value !== 'string') return null;
  const trimmed = value.trim().replace(/\s+/g, ' ');
  if (trimmed.length < 20) return null;
  return trimmed.slice(0, 1000);
}

/**
 * Where the Admin was, or why that is not known.
 *
 * Never null and never absent. `status` is always one of granted / denied /
 * unavailable, so a record with no coordinates still says which of the three
 * happened — and "the Admin refused to share their location" is a fact about
 * the access, not a gap in it.
 */
function normaliseLocation(value) {
  const unavailable = { status: 'unavailable', latitude: null, longitude: null, accuracyM: null };
  if (!value || typeof value !== 'object') return unavailable;

  const status = ['granted', 'denied', 'unavailable'].includes(value.status)
    ? value.status
    : 'unavailable';

  if (status !== 'granted') {
    return { status, latitude: null, longitude: null, accuracyM: null };
  }

  const lat = Number(value.latitude);
  const lon = Number(value.longitude);
  // A "granted" location that is not a coordinate is not granted. Downgraded
  // rather than stored, because a malformed pair would render as a pin in the
  // Gulf of Guinea and read as a real place.
  if (!Number.isFinite(lat) || !Number.isFinite(lon)
      || lat < -90 || lat > 90 || lon < -180 || lon > 180) {
    return unavailable;
  }

  const accuracy = Number(value.accuracyM);
  return {
    status: 'granted',
    latitude: lat,
    longitude: lon,
    accuracyM: Number.isFinite(accuracy) ? Math.round(accuracy) : null,
  };
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
  declaration,
  location = null,
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

  const why = normaliseDeclaration(declaration);
  if (why === null) {
    throw badRequest(
      'A disclosure requires a written reason — at least a sentence saying '
      + 'why this reference is being resolved. It is read back on the '
      + 'register by somebody who was not there.',
    );
  }

  const where = normaliseLocation(location);

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
      + `Stated reason: "${why}". `
      + `Location: ${describeLocation(where)}. `
      + 'Collection evidence only; the Champion was not named by this action.',
    ip,
    userAgent,
  });

  // The readable half. After the chain entry, deliberately: if the register
  // write fails the disclosure is still recorded in the tamper-evident log,
  // which is the one that matters. The reverse would leave a readable entry
  // with nothing proving it was not edited.
  const registerId = await writeRegister({
    kind: 'resolve',
    orgId,
    subject: disposalRef,
    doeReference: reference,
    declaration: why,
    location: where,
    adminUid,
    adminName,
    ip,
    userAgent,
  });

  const match = await findAttributionsForRef({ orgId, disposalRef, periodId });

  if (!match.disposalId) {
    return {
      found: false,
      registerId,
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
    registerId,
    doeReference: reference,
    declaration: why,
    location: where,
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
  declaration,
  location = null,
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

  const why = normaliseDeclaration(declaration);
  if (why === null) {
    throw badRequest(
      'Naming a person requires a written reason — at least a sentence. This '
      + 'is the strongest disclosure Chokro performs and the record of it has '
      + 'to stand on its own.',
    );
  }

  const where = normaliseLocation(location);

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
      + `${disposalId} under regulator request ${reference}. `
      + `Stated reason: "${why}". `
      + `Location: ${describeLocation(where)}. `
      + 'This names a person and is the strongest disclosure Chokro performs.',
    ip,
    userAgent,
  });

  const registerId = await writeRegister({
    kind: 'identity',
    orgId,
    subject: disposalId,
    doeReference: reference,
    declaration: why,
    location: where,
    adminUid,
    adminName,
    ip,
    userAgent,
  });

  const disposalSnap = await db().collection(DISPOSALS).doc(disposalId).get();
  if (!disposalSnap.exists) {
    return {
      released: false,
      registerId,
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
      registerId,
      doeReference: reference,
      note: 'That disposal carries no account reference.',
    };
  }

  const userSnap = await db().collection(USERS).doc(uid).get();
  const user = userSnap.exists ? userSnap.data() : null;

  return {
    released: true,
    registerId,
    doeReference: reference,
    declaration: why,
    location: where,
    disposalId,
    champion: {
      uid,
      name: user?.name ?? null,
      email: user?.email ?? null,
      accountExists: userSnap.exists,
    },
  };
}

/** A one-line rendering of a location for the chain's summary string. */
function describeLocation(where) {
  if (where.status === 'granted') {
    const accuracy = where.accuracyM === null ? '' : ` ±${where.accuracyM}m`;
    return `${where.latitude.toFixed(5)}, ${where.longitude.toFixed(5)}${accuracy}`;
  }
  if (where.status === 'denied') return 'refused by the Admin’s device';
  return 'not available';
}

/**
 * Writes the readable register entry. Never throws.
 *
 * A failure here must not fail the disclosure: the chain entry has already
 * committed, so the access IS recorded, and refusing at this point would leave
 * an audit entry for a resolution that never ran. Logged loudly instead, and
 * the caller gets a null id, which the register screen renders as a gap rather
 * than hiding.
 */
async function writeRegister(entry) {
  try {
    const ref = await db().collection(REGISTER).add({
      ...entry,
      userAgent: typeof entry.userAgent === 'string'
        ? entry.userAgent.slice(0, 300)
        : null,
      at: new Date().toISOString(),
      createdAt: serverTimestamp(),
    });
    return ref.id;
  } catch (err) {
    console.error('[disclosure] register write failed:', err.message);
    return null;
  }
}

/**
 * The register, newest first.
 *
 * Bounded (QA-10), and `complete` says whether the bound was reached — a
 * register of privileged accesses that silently truncated would be the one
 * document where a missing row matters most.
 */
async function disclosureRegister({ limit = 100, orgId = null } = {}) {
  const capped = Math.min(Math.max(Number(limit) || 100, 1), 500);

  let query = db().collection(REGISTER);
  if (orgId) query = query.where('orgId', '==', orgId);
  query = query.orderBy('at', 'desc').limit(capped + 1);

  const snap = await query.get();
  const docs = snap.docs.slice(0, capped);

  return {
    complete: snap.size <= capped,
    limit: capped,
    entries: docs.map((doc) => {
      const d = doc.data();
      return {
        id: doc.id,
        kind: d.kind ?? null,
        orgId: d.orgId ?? null,
        subject: d.subject ?? null,
        doeReference: d.doeReference ?? null,
        declaration: d.declaration ?? null,
        location: d.location ?? { status: 'unavailable', latitude: null, longitude: null, accuracyM: null },
        adminUid: d.adminUid ?? null,
        adminName: d.adminName ?? null,
        ip: d.ip ?? null,
        userAgent: d.userAgent ?? null,
        at: d.at ?? null,
      };
    }),
  };
}

module.exports = {
  resolveDisposalRef,
  disclosureRegister,
  normaliseDeclaration,
  normaliseLocation,
  describeLocation,
  releaseIdentity,
  // Exported for the drift test: the keyed candidate MUST equal the pseudonym
  // `reportJobs` mints, or a real row resolves as not found.
  candidateRefs,
  unkeyedPseudonym,
  isValidRef,
  SCAN_CAP,
};
