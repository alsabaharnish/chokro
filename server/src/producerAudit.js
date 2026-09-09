/**
 * Chokro - the producer activity trail (EPR-44, SEC-12).
 *
 * Append-only, hash-chained per organisation. Every membership change, mass
 * verification, declaration submission, passport issuance and revocation, and
 * every report export, lands here.
 *
 * WHY A CHAIN AND NOT JUST APPEND-ONLY RULES
 * `firestore.rules` can refuse an update and a delete, and it does - for every
 * principal, administrators included. What it cannot do is refuse *this*
 * service: the Admin SDK bypasses rules by definition, which is the entire
 * reason this process exists. So the strongest control the rules can offer
 * stops at the client boundary, and the adversary SEC-12 actually names is an
 * insider on this side of it.
 *
 * A chain changes what a removal costs. Each entry carries a digest computed
 * over the previous entry's digest and its own content, so deleting entry 7
 * leaves entry 8 pointing at a digest that no longer exists, and rewriting
 * entry 7 changes its digest and breaks the same link. Neither is prevented.
 * Both become *detectable*, by anyone holding the log - including the producer
 * whose history it is, and including a Department of Environment inspector
 * reading the audit pack. That is the difference between a trail you are asked
 * to trust and one you can check.
 *
 * WHY THE SEQUENCE NUMBER TOO
 * A digest chain detects modification and deletion in the middle. It does not
 * detect truncation: lop off the last three entries and what remains is a
 * perfectly valid chain. The monotonic per-organisation sequence closes that -
 * a head at 41 when the chain has 38 links is missing three.
 *
 * WRITES THROW, AND ARE MEANT TO. An action that could not be logged has not
 * happened as far as this system is concerned, so the transaction that would
 * have recorded it rolls back with it. That is the opposite of the screening
 * path's discipline, and deliberately: a missing screen degrades a payout
 * decision to human review, while a missing audit entry silently destroys the
 * evidence for an action that did take place.
 */

const crypto = require('crypto');
const { db, serverTimestamp } = require('./firebase');

const COLLECTION = 'producerAuditLog';
const HEAD_COLLECTION = 'producerAuditHeads';

/**
 * Separates the fields inside a digest input.
 *
 * ASCII unit separator (U+001F). It cannot occur in any of the values being
 * joined - they are uids, enum values, document ids and a summary sentence - so
 * no combination of field contents can be made to hash the same as a different
 * combination by shifting a boundary. A comma or a colon could: an actor uid of
 * "a" with a target of "b,c" would otherwise digest identically to "a,b" with
 * "c".
 */
const FIELD_SEPARATOR = '\u001f';

/**
 * The key that makes the chain a control rather than a checksum (SEC-12).
 *
 * WHY A KEY IS NECESSARY, AND WHY IT MUST NOT COME FROM THE SERVICE ACCOUNT
 *
 * A bare SHA-256 over stored fields is recomputable by anyone who can read
 * those fields. The adversary SEC-12 names is an insider with Admin SDK access
 * — so an unkeyed chain lets them rewrite entry 12, recompute its digest with
 * the same public function, then recompute 13, 14, 15 in order, and
 * `verifyChain` reports the result intact. The chain detects accident and
 * outside tampering; it detects nothing about the person it was written for.
 *
 * An HMAC fixes that only if the key is independent of the Firestore
 * credential. Deriving it from `FIREBASE_SERVICE_ACCOUNT` would be worthless:
 * whoever can write these documents already holds that credential, so the
 * "secret" would be in the same hands as the ability to forge. The key
 * therefore comes from its own environment variable, and in a real deployment
 * belongs somewhere the database operator cannot read.
 *
 * WHEN IT IS UNSET the chain still works and is still useful — it remains
 * tamper-evident against anything that does not hold write access — but it is
 * NOT evidence against an insider, and `verifyChain` says so in its `keyed`
 * field rather than letting a console print "intact" as though it were.
 * Setting it is release-blocking before the first real producer, alongside App
 * Check (NFR-E-9).
 */
function chainKey() {
  return process.env.AUDIT_CHAIN_KEY || null;
}

/** Whether the chain is keyed. Surfaced in every verification result. */
function isKeyed() {
  return chainKey() !== null;
}

/**
 * The action vocabulary. Mirrors `ProducerAuditAction` in Dart; the two are
 * stored strings and neither is renamed once written (QA-6).
 */
const ACTIONS = Object.freeze({
  ORG_APPLIED: 'org.applied',
  ORG_APPROVED: 'org.approved',
  ORG_REJECTED: 'org.rejected',
  ORG_INFO_REQUESTED: 'org.infoRequested',
  ORG_SUSPENDED: 'org.suspended',
  ORG_REINSTATED: 'org.reinstated',
  ORG_UPDATED: 'org.updated',
  MEMBER_INVITED: 'member.invited',
  MEMBER_INVITATION_REVOKED: 'member.invitationRevoked',
  MEMBER_ACTIVATED: 'member.activated',
  MEMBER_ROLE_CHANGED: 'member.roleChanged',
  MEMBER_REMOVED: 'member.removed',

  // Phase B — the mass chain (EPR-9 to EPR-14).
  //
  // `SKU_MASS_VERIFIED` is the single most consequential entry in this log:
  // it records the moment a number that will appear on a regulatory filing was
  // accepted. Its before/after digests cover the previous and new verified
  // mass, so a change to the figure a report uses is never invisible.
  SKU_SAVED: 'sku.saved',
  SKU_SUBMITTED: 'sku.submitted',
  SKU_MASS_VERIFIED: 'sku.massVerified',
  SKU_MASS_REJECTED: 'sku.massRejected',
  SKU_RETIRED: 'sku.retired',

  ADMIN_VIEWED_AS_ORG: 'admin.viewedAsOrg',
});

const ACTION_VALUES = Object.freeze(Object.values(ACTIONS));

function isValidAction(value) {
  return ACTION_VALUES.includes(value);
}

/**
 * The digest of one entry, over the previous digest and this entry's content.
 *
 * The canonical form is deliberately an explicit field list rather than
 * `JSON.stringify` of the whole object: key order in a stringified object is
 * insertion order, so a later refactor that reordered two assignments would
 * silently invalidate every chain ever written. Naming the fields in a fixed
 * order means the digest depends on the values and nothing else.
 *
 * `timestampIso` is the service's own reading of the clock, not a Firestore
 * sentinel - a sentinel has no value to hash at write time. The stored
 * `timestamp` field is the server clock, so the two can be compared afterwards.
 */
function computeDigest({
  previousDigest,
  orgId,
  sequence,
  action,
  actorUid,
  actorName,
  actorRole,
  targetType,
  targetId,
  summary,
  beforeDigest,
  afterDigest,
  timestampIso,
  ip,
  userAgent,
}) {
  // EVERY STORED FIELD THAT A READER WOULD BELIEVE.
  //
  // `actorName`, `actorRole`, `ip` and `userAgent` were stored and not hashed,
  // which meant an insider could rewrite them and the chain would still verify:
  // an entry reading "Admin One / admin" became "System (automated)" with no
  // finding. A field displayed on the EPR-44 timeline and in the audit pack but
  // absent from the digest is a field the log asserts and cannot defend.
  //
  // The Firestore `timestamp` sentinel is deliberately absent — it has no value
  // at write time, so it cannot be hashed. `timestampIso` is the service's own
  // reading of the same clock and IS hashed, and `verifyChain` compares the two.
  // Ordering for display is by `sequence`, which is hashed, precisely so a
  // rewritten `timestamp` cannot reorder a timeline.
  const canonical = [
    previousDigest || '',
    orgId || '',
    String(sequence),
    action || '',
    actorUid || '',
    actorName || '',
    actorRole || '',
    targetType || '',
    targetId || '',
    summary || '',
    beforeDigest || '',
    afterDigest || '',
    timestampIso || '',
    ip || '',
    userAgent || '',
  ].join(FIELD_SEPARATOR);

  const key = chainKey();
  return key
    ? crypto.createHmac('sha256', key).update(canonical, 'utf8').digest('hex')
    : crypto.createHash('sha256').update(canonical, 'utf8').digest('hex');
}

/**
 * A digest of a document state, for the before/after columns.
 *
 * A digest rather than the state itself, because the log is readable by the
 * organisation's own members and a "before" image of a membership document
 * would carry another person's details into a screen that has no business
 * showing them. The digest proves that something changed without disclosing
 * what, and the full before/after stays reconstructible from the collections.
 */
function digestState(value) {
  if (value === null || value === undefined) return null;
  return crypto
    .createHash('sha256')
    .update(JSON.stringify(value), 'utf8')
    .digest('hex');
}

/**
 * Reads an organisation's chain head.
 *
 * SPLIT OUT FROM THE APPEND, AND THE REASON IS A BUG THIS SHAPE PREVENTS.
 *
 * Firestore transactions require every read to precede every write, and the
 * Admin SDK enforces it unconditionally — `transaction.js` throws
 * "Firestore transactions require all reads to be executed before all writes."
 * the moment a `get` follows a `set`.
 *
 * When appending was a single function that read the head *and* wrote the
 * entry, every caller had to remember to call it before its own first write.
 * Three of them did not, and the failure was invisible in tests because a
 * hand-written fake transaction does not enforce the rule — so `createOrganization`
 * and every mass verification would have thrown on the first real request while
 * the suite stayed green.
 *
 * Splitting the read from the write makes the ordering a property of the call
 * sites rather than a convention: a caller that needs to write first reads the
 * head here, at the top, and passes it to [appendWithHead] later.
 *
 * @param {FirebaseFirestore.Transaction} txn
 * @param {string} orgId
 * @returns {Promise<{previousDigest: string|null, sequence: number}>}
 */
async function readChainHead(txn, orgId) {
  if (typeof orgId !== 'string' || orgId.length === 0) {
    throw new Error('An audit entry must name an organisation.');
  }

  const headSnap = await txn.get(db().collection(HEAD_COLLECTION).doc(orgId));
  const previous = headSnap.exists ? headSnap.data() : null;

  return {
    previousDigest: previous?.digest || null,
    // The sequence this organisation's next entry will carry.
    sequence: (previous?.sequence || 0) + 1,
  };
}

/**
 * Appends one entry using an already-read chain head. Writes only.
 *
 * ALWAYS TAKES A TRANSACTION, never opens its own. The entry and the action it
 * records commit together or not at all - an audit log that can disagree with
 * the state it describes is worse than none, because it will be believed.
 *
 * @param {FirebaseFirestore.Transaction} txn
 * @param {{previousDigest: string|null, sequence: number}} head from [readChainHead]
 * @returns {{entryId: string, sequence: number, digest: string}}
 */
function appendWithHead(txn, head, entry) {
  const {
    orgId,
    action,
    actorUid,
    actorName = '',
    actorRole = '',
    targetType = '',
    targetId = '',
    summary = '',
    before = null,
    after = null,
    ip = null,
    userAgent = null,
  } = entry || {};

  if (typeof orgId !== 'string' || orgId.length === 0) {
    throw new Error('An audit entry must name an organisation.');
  }
  if (!isValidAction(action)) {
    // An action this build does not know about is a programming error, not a
    // runtime condition. Refusing it here keeps the log's action column a
    // closed set that a query and a screen can rely on.
    throw new Error(`Unknown audit action: ${action}`);
  }
  if (typeof actorUid !== 'string' || actorUid.length === 0) {
    throw new Error('An audit entry must name an actor.');
  }

  const firestore = db();
  const headRef = firestore.collection(HEAD_COLLECTION).doc(orgId);

  const { previousDigest, sequence } = head || {};
  if (!Number.isInteger(sequence) || sequence < 1) {
    // A caller that reached here without reading the head has skipped the one
    // step that makes the chain a chain. Refusing is better than writing an
    // unlinked entry that `verifyChain` would later report as a broken link
    // with no explanation.
    throw new Error(
      'appendWithHead needs a chain head from readChainHead(txn, orgId).',
    );
  }

  const timestampIso = new Date().toISOString();
  const beforeDigest = digestState(before);
  const afterDigest = digestState(after);

  const safeUserAgent =
    typeof userAgent === 'string' ? userAgent.slice(0, 300) : null;

  const digest = computeDigest({
    previousDigest,
    orgId,
    sequence,
    action,
    actorUid,
    actorName,
    actorRole,
    targetType,
    targetId,
    summary,
    beforeDigest,
    afterDigest,
    timestampIso,
    ip: ip || null,
    // The truncated value, because that is what is stored — hashing the full
    // string would make every entry with a long user agent fail its own check.
    userAgent: safeUserAgent,
  });

  const entryRef = firestore.collection(COLLECTION).doc();

  txn.set(entryRef, {
    orgId,
    action,
    actorUid,
    actorName,
    actorRole,
    targetType,
    targetId,
    summary,
    beforeDigest,
    afterDigest,
    previousDigest,
    digest,
    sequence,
    timestamp: serverTimestamp(),
    timestampIso,
    ip: ip || null,
    userAgent: safeUserAgent,
  });

  // The head is a mutable pointer and is NOT itself evidence. Rewriting it
  // cannot forge a chain - the digests live in the entries - it can only make
  // the next entry link to the wrong place, which `verifyChain` then reports.
  txn.set(headRef, {
    orgId,
    sequence,
    digest,
    updatedAt: serverTimestamp(),
  });

  return { entryId: entryRef.id, sequence, digest };
}

/**
 * Reads the head and appends, in one call.
 *
 * Safe ONLY when no write has yet been issued on this transaction, because it
 * performs a read. Callers that must write first use [readChainHead] at the top
 * and [appendWithHead] afterwards.
 */
async function appendInTransaction(txn, entry) {
  const head = await readChainHead(txn, entry?.orgId);
  return appendWithHead(txn, head, entry);
}

/**
 * Appends one entry in its own transaction.
 *
 * For actions that are not themselves transactional - an Admin opening a
 * read-only view of an organisation (EPR-46), a report download. Anything that
 * changes state uses [appendInTransaction] or the read/write pair instead, so
 * the entry and the change share a commit.
 */
async function append(entry) {
  return db().runTransaction((txn) => appendInTransaction(txn, entry));
}

/**
 * Walks one organisation's chain and reports whether it is intact.
 *
 * Re-derives each digest from the stored fields in ascending sequence order, so
 * a modified entry, a deleted one and a truncated tail are three
 * distinguishable findings rather than one vague "invalid".
 *
 * Bounded like every other read in this codebase (QA-10). A log longer than the
 * limit reports `complete: false` and never `intact: true`, because "the first
 * 500 entries are intact" is not the same claim as "the log is intact" and must
 * not be allowed to look like one.
 */
async function verifyChain({ orgId, limit = 500 }) {
  const firestore = db();

  const snap = await firestore
    .collection(COLLECTION)
    .where('orgId', '==', orgId)
    .orderBy('sequence', 'asc')
    .limit(limit)
    .get();

  const entries = snap.docs.map((d) => ({ id: d.id, ...d.data() }));

  const findings = [];
  let previousDigest = null;
  let expectedSequence = 1;

  for (const e of entries) {
    if (e.sequence !== expectedSequence) {
      findings.push({
        entryId: e.id,
        problem: 'sequenceGap',
        expected: expectedSequence,
        found: e.sequence,
      });
      // Continue from what is actually there, so one gap does not report every
      // entry after it as broken too.
      expectedSequence = e.sequence;
    }

    if ((e.previousDigest || null) !== previousDigest) {
      findings.push({
        entryId: e.id,
        problem: 'brokenLink',
        expected: previousDigest,
        found: e.previousDigest || null,
      });
    }

    const recomputed = computeDigest({
      previousDigest: e.previousDigest || null,
      orgId: e.orgId,
      sequence: e.sequence,
      action: e.action,
      actorUid: e.actorUid,
      actorName: e.actorName,
      actorRole: e.actorRole,
      targetType: e.targetType,
      targetId: e.targetId,
      summary: e.summary,
      beforeDigest: e.beforeDigest,
      afterDigest: e.afterDigest,
      timestampIso: e.timestampIso,
      ip: e.ip,
      userAgent: e.userAgent,
    });

    if (recomputed !== e.digest) {
      findings.push({ entryId: e.id, problem: 'digestMismatch' });
    }

    // The two clocks. `timestampIso` is inside the digest; the Firestore
    // `timestamp` is not, because a sentinel has no value to hash. Comparing
    // them is what makes a rewritten `timestamp` detectable.
    const stored = e.timestamp?.toDate?.() ?? null;
    if (stored && e.timestampIso) {
      const drift = Math.abs(stored.getTime() - Date.parse(e.timestampIso));
      // Generous: these are two readings of the same moment, one by this
      // process and one by Firestore, and a few seconds of skew is ordinary.
      if (Number.isFinite(drift) && drift > 5 * 60 * 1000) {
        findings.push({
          entryId: e.id,
          problem: 'timestampDrift',
          expected: e.timestampIso,
          found: stored.toISOString(),
        });
      }
    }

    previousDigest = e.digest || null;
    expectedSequence += 1;
  }

  const headSnap = await firestore.collection(HEAD_COLLECTION).doc(orgId).get();
  const head = headSnap.exists ? headSnap.data() : null;

  const complete = entries.length < limit;
  const lastSeen = entries.length > 0 ? entries[entries.length - 1].sequence : 0;

  // Truncation: the head remembers a sequence the surviving entries no longer
  // reach. Only checkable over a log this pass saw all of.
  if (complete && head && (head.sequence || 0) !== lastSeen) {
    findings.push({
      problem: 'truncated',
      expected: head.sequence || 0,
      found: lastSeen,
    });
  }

  // A MISSING HEAD IS ITSELF A FINDING.
  //
  // Without this, the most complete attack available scored best: delete every
  // entry for an organisation AND delete its head, and the truncation check
  // above — guarded on `head` being present — was skipped, so the result read
  // `intact: true` over an empty log.
  //
  // Every organisation that exists has a head, because `createOrganization`
  // writes its first audit entry in the same transaction as the organisation
  // record. So an absent head is never the innocent state it looks like.
  if (!head) {
    findings.push({ problem: 'headMissing' });
  }

  return {
    orgId,
    entriesChecked: entries.length,
    intact: complete && findings.length === 0,
    complete,
    // Whether the chain is an HMAC under an operator-held key or a bare hash
    // anyone with read access can recompute. A console that printed "intact"
    // without saying which would be overstating the control.
    keyed: isKeyed(),
    headPresent: head !== null,
    findings,
  };
}

/**
 * One organisation's recent history, newest first.
 *
 * Bounded (QA-10). The whole log is an audit-pack job (EPR-35), not a screen.
 */
async function listForOrg({ orgId, limit = 100 }) {
  // Ordered by `sequence`, not `timestamp`.
  //
  // `sequence` is inside the digest and `timestamp` is not, so ordering by the
  // clock would let an insider reorder the visible timeline — placing a mass
  // verification before the declaration it was based on — without breaking the
  // chain. Ordering by the hashed monotonic counter cannot be rewritten
  // silently, and it is also the true order of events, which a server clock
  // read across retries is not quite.
  const snap = await db()
    .collection(COLLECTION)
    .where('orgId', '==', orgId)
    .orderBy('sequence', 'desc')
    .limit(limit)
    .get();

  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

module.exports = {
  ACTIONS,
  ACTION_VALUES,
  COLLECTION,
  HEAD_COLLECTION,
  FIELD_SEPARATOR,
  isValidAction,
  isKeyed,
  computeDigest,
  digestState,
  readChainHead,
  appendWithHead,
  appendInTransaction,
  append,
  verifyChain,
  listForOrg,
};
