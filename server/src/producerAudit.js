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
 * The organisations collection, named here rather than imported.
 *
 * `organizations.js` requires this module, so importing it back would be a
 * cycle. `verifyChain` needs exactly one field from one document — the
 * organisation's `createdAt` — and a string constant is the cheaper price than
 * restructuring two modules around a single read.
 */
const ORGS_COLLECTION = 'organizations';

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
 * The instant the operator asserts the audit log has been in force from
 * (`AUDIT_LOG_EPOCH`, an ISO 8601 date-time).
 *
 * ===========================================================================
 * WHY THIS CANNOT BE DERIVED FROM THE LOG
 * ===========================================================================
 *
 * An organisation older than the log has no chain, and that is a different
 * statement from a broken one. Telling the two apart needs a trustworthy date
 * for when the log started — and the obvious source, the earliest entry in the
 * log, is the one source that must not be used: it is derived from the very
 * data whose integrity is in question. An insider who deleted an organisation's
 * entries would move the apparent start date later and thereby manufacture the
 * excuse for the deletion they just performed.
 *
 * So the date is asserted by the operator, who is stating a fact about
 * deployment history that no query can establish, and is deliberately UNSET by
 * default. Unset means `verifyChain` cannot excuse an empty chain and reports
 * it as broken — the safe direction, and the one that makes the missing
 * configuration visible instead of silently widening what counts as innocent.
 *
 * A LATER epoch is more permissive, not less: it excuses every organisation
 * created before it. Set it to the earliest date the log can be shown to have
 * been running, never to a convenient round number after the fact.
 */
function logEpoch() {
  const raw = String(process.env.AUDIT_LOG_EPOCH || '').trim();
  if (!raw) return { configured: false, at: null, malformed: false };

  const ms = Date.parse(raw);
  // A typo must not read as "unset and therefore strict" without saying so —
  // that is a misconfiguration silently changing what the log claims. It is
  // reported as a finding so it surfaces on the screen that depends on it.
  if (!Number.isFinite(ms)) return { configured: false, at: null, malformed: true };

  return { configured: true, at: new Date(ms), malformed: false };
}

/**
 * Whether the organisation demonstrably predates the audit log.
 *
 * Every branch that cannot PROVE it answers false. No asserted epoch, no
 * organisation record, no usable `createdAt` — each of those is an absence of
 * evidence, and an absence of evidence is not a reason to excuse a missing
 * chain. Only a recorded creation date strictly earlier than the operator's
 * asserted start date earns the benefit of the doubt.
 */
async function organisationPredatesLog(firestore, orgId, epoch) {
  if (!epoch.configured) return false;

  const snap = await firestore.collection(ORGS_COLLECTION).doc(orgId).get();
  if (!snap.exists) return false;

  const created = snap.data()?.createdAt;
  const at = created?.toDate?.()
    ?? (typeof created === 'string' ? new Date(Date.parse(created)) : null);
  if (!at || !Number.isFinite(at.getTime())) return false;

  return at.getTime() < epoch.at.getTime();
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

  // Phase D — the denominator (EPR-24) and the certificate (EPR-28).
  //
  // `DECLARATION_SUBMITTED` is the entry a regulator would ask about: it is the
  // moment a producer attested to the figure every percentage in its reports
  // divides by, and its summary carries the attester's name.
  DECLARATION_SAVED: 'declaration.saved',
  DECLARATION_SUBMITTED: 'declaration.submitted',
  DECLARATION_CORRECTED: 'declaration.corrected',
  PASSPORT_ISSUED: 'passport.issued',
  PASSPORT_SUPERSEDED: 'passport.superseded',
  PASSPORT_REVOKED: 'passport.revoked',
  REPORT_GENERATED: 'report.generated',
  REPORT_DOWNLOADED: 'report.downloaded',
  ANOMALY_SCAN: 'anomaly.scan',
  ANOMALY_DISMISSED: 'anomaly.dismissed',
  ACCURACY_REVIEWED: 'accuracy.reviewed',

  ADMIN_VIEWED_AS_ORG: 'admin.viewedAsOrg',

  // Lawful disclosure to the regulator (SEC-13).
  //
  // Resolving a pseudonymous disposal reference back to the disposal behind it
  // is the one operation that deliberately undoes SEC-3's de-identification.
  // It is therefore the operation that most needs a record: a disclosure path
  // nobody can audit is indistinguishable from a backdoor, and the difference
  // between the two is entirely whether it was written down.
  DISCLOSURE_RESOLVED: 'disclosure.resolved',
  // A second, separate action, because naming the person is a bigger step than
  // producing the evidence and must not be inferable from the first entry.
  DISCLOSURE_IDENTITY_RELEASED: 'disclosure.identityReleased',
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

  // THE HEAD CARRIES A DIGEST TOO, AND IT WAS NEVER READ.
  //
  // Only `head.sequence` was compared. The head stores a digest alongside it,
  // written in the same transaction as the entry it points at, and a head
  // whose digest contradicts the last surviving entry passed verification
  // silently.
  //
  // It is the cheap half of a partial cover-up. Deleting the tail and winding
  // `sequence` back defeats the truncation check above — but the attacker has
  // to remember to rewrite the digest as well, and a head still pointing at an
  // entry that is no longer there is exactly the trace this catches. Two
  // fields to keep consistent is strictly harder than one.
  //
  // Guarded on there being a last entry: with none, `truncated` above has
  // already fired on the sequence, and comparing against nothing would report
  // the same fault twice under a name that does not describe it.
  if (complete && head && entries.length > 0) {
    const lastDigest = entries[entries.length - 1].digest || null;
    if ((head.digest || null) !== lastDigest) {
      findings.push({
        problem: 'headDigestMismatch',
        expected: head.digest || null,
        found: lastDigest,
      });
    }
  }

  // A MISSING HEAD IS ITSELF A FINDING.
  //
  // Without this, the most complete attack available scored best: delete every
  // entry for an organisation AND delete its head, and the truncation check
  // above — guarded on `head` being present — was skipped, so the result read
  // `intact: true` over an empty log.
  //
  // `createOrganization` writes the first audit entry in the same transaction
  // as the organisation record, so for anything created since the log existed
  // an absent head is never the innocent state it looks like. The exception is
  // an organisation OLDER than the log — see below.
  const epoch = logEpoch();
  let predatesLog = false;

  if (!head) {
    // AN ORGANISATION OLDER THAN THE LOG HAS NO CHAIN, WHICH IS NOT A BROKEN
    // ONE.
    //
    // The two look identical from here — no entries, no head — and reporting
    // both as "BROKEN, treat this history as unreliable and escalate" made the
    // console cry wolf over a non-event on every record that predates the
    // feature. An auditor who is escalated to twice over nothing stops reading
    // the third one, which is the actual cost.
    //
    // The excuse is granted only against an operator-asserted start date, and
    // only on a recorded creation date strictly earlier than it. Deleting the
    // entries and the head of an organisation created SINCE that date still
    // reports broken, which is the attack this check must not reopen.
    predatesLog = await organisationPredatesLog(firestore, orgId, epoch);

    if (predatesLog) {
      findings.push({ problem: 'predatesAuditLog' });
    } else {
      findings.push({ problem: 'headMissing' });
      // Said out loud rather than inferred from silence: with no asserted
      // start date, an organisation that genuinely predates the log cannot be
      // told apart from one whose chain was deleted, and this result is the
      // strict reading of that ambiguity.
      if (epoch.malformed) {
        findings.push({ problem: 'auditLogEpochMalformed' });
      } else if (!epoch.configured) {
        findings.push({ problem: 'auditLogEpochUnset' });
      }
    }
  }

  // `predatesAuditLog` is an explanation, not a defect, and the other two ride
  // with it rather than standing on their own. Separating them keeps a missing
  // configuration from being counted as tampering.
  const defects = findings.filter(
    (f) => f.problem !== 'predatesAuditLog'
      && f.problem !== 'auditLogEpochUnset'
      && f.problem !== 'auditLogEpochMalformed',
  );

  // FOUR ANSWERS, BECAUSE THERE ARE FOUR SITUATIONS.
  //
  // `intact` alone had to carry all of them, so everything that was not a
  // clean bill rendered as tampering: an organisation older than the log, and
  // a log longer than one pass, both arrived on screen as "BROKEN". Neither is
  // evidence of anything, and a control that reports non-events at the same
  // severity as an attack teaches its reader to ignore it.
  let state;
  if (predatesLog && defects.length === 0) state = 'noChain';
  else if (defects.length > 0) state = 'broken';
  else if (!complete) state = 'partial';
  else state = 'intact';

  return {
    orgId,
    entriesChecked: entries.length,
    // Unchanged in meaning: true only for a chain checked end to end with
    // nothing wrong. Every existing caller reads this and keeps its behaviour;
    // `state` is what tells the three non-intact cases apart.
    intact: state === 'intact',
    state,
    complete,
    // Whether the log has an asserted start date at all. A `noChain` result is
    // only as good as this, so it travels with it rather than being looked up
    // separately by whatever renders the answer.
    epochAsserted: epoch.configured,
    // Whether the chain is an HMAC under an operator-held key or a bare hash
    // anyone with read access can recompute. A console that printed "intact"
    // without saying which would be overstating the control.
    keyed: isKeyed(),
    headPresent: head !== null,
    findings,
  };
}

/**
 * A verification result as a producer may see it (SEC-12).
 *
 * An explicit allowlist, like every other client-facing projection in this
 * service — fields are named IN, so a field added to `verifyChain` later does
 * not reach a producer because nobody remembered to exclude it.
 *
 * Everything here is already the producer's own: it reads its entries through
 * `/epr/audit` and the rules, and each entry carries the sequence and digest
 * these findings refer to. What is withheld is nothing, because there is
 * nothing in a verification of your own chain that belongs to anyone else.
 *
 * `keyed` travels with the verdict deliberately. An unkeyed chain is
 * tamper-evident against anyone WITHOUT write access and is not evidence
 * against the operator — and the operator is the party a producer would be
 * disputing with. Reporting "intact" to them without saying which would be
 * overstating the control to the one reader it is least fair to overstate it
 * to.
 */
function projectVerification(result) {
  return {
    orgId: result.orgId,
    entriesChecked: result.entriesChecked,
    intact: result.intact,
    state: result.state,
    complete: result.complete,
    keyed: result.keyed,
    headPresent: result.headPresent,
    epochAsserted: result.epochAsserted,
    // The problem names only. `expected`/`found` carry digests and sequence
    // numbers the producer can already read off its own entries, but the name
    // is what a screen renders and what a dispute cites, and a narrower
    // payload is the easier one to keep honest.
    findings: (result.findings || []).map((f) => ({
      problem: f.problem,
      entryId: f.entryId ?? null,
    })),
    verificationCaveat: result.keyed
      ? null
      : 'This chain is an unkeyed hash. It detects tampering by anyone without '
        + 'write access to the database, and is NOT evidence against whoever '
        + 'holds the database credential.',
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
  projectVerification,
  listForOrg,
};
