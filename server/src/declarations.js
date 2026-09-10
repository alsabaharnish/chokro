/**
 * Chokro — put-on-market declarations (EPR-24, EPR-43, §6.5).
 *
 * THE DENOMINATOR, AND WHY IT IS THE PRODUCER'S TO STATE
 *
 * The gazette's targets are percentages of what a producer placed on the
 * market. Chokro measures the numerator — it photographs, geofences and screens
 * the collection — and it cannot measure the denominator, because only the
 * producer knows how many bottles it shipped.
 *
 * §6.2 names understating put-on-market as one of the two attacks on this
 * system: it shrinks the denominator and flatters the percentage, and it is
 * "false information" within the meaning of the gazette's enforcement clause.
 * Chokro cannot verify the figure, so everything here is about making a
 * declared number carry its own weight of evidence instead:
 *
 *   IT IS ATTESTED. A named person, a server clock, and the exact words agreed
 *   to — copied onto the document, so a filing keeps the wording its signatory
 *   actually saw even after Chokro revises it.
 *
 *   IT LOCKS. A denominator that could be edited after a percentage had been
 *   reported is not a denominator, it is a dial.
 *
 *   A CORRECTION SUPERSEDES. Both versions are retained, every passport issued
 *   against the superseded one is marked superseded (EPR-30), and the variance
 *   between them is what EPR-43's review queue reads.
 */

const { db, admin, serverTimestamp } = require('./firebase');
const audit = require('./producerAudit');
const eprPeriod = require('./eprPeriod');

const DECLARATIONS = 'putOnMarketDeclarations';
const VERSIONS = 'putOnMarketVersions';
const PASSPORTS = 'plasticPassports';

const GAZETTE_CATEGORIES = Object.freeze([
  'rigid',
  'flexible',
  'eps',
  'singleUse',
  'other',
]);

/** Mirrors `mass_math.dart`. */
const MG_PER_GRAM = 1000;
const MG_PER_KILOGRAM = 1000000;

/**
 * The upper bound on a declared category mass.
 *
 * One hundred thousand tonnes in a month. Bangladesh's entire annual plastic
 * consumption is on the order of a million tonnes, so a single producer
 * declaring more than this in one month is a unit error — almost always grams
 * entered as kilograms — and accepting it would put a denominator three orders
 * of magnitude too large under a percentage, driving the reported rate to
 * effectively zero and hiding a real collection programme.
 *
 * A bound rather than a rejection of the whole filing, and it is a *refusal*
 * rather than a clamp: a clamped denominator is a wrong figure that looks like
 * a right one.
 */
const MAX_CATEGORY_MASS_MG = 100000 * 1000 * MG_PER_KILOGRAM;

/** The same ceiling logic for units. */
const MAX_CATEGORY_UNITS = 10000000000;

/**
 * The words a producer attests to (EPR-24).
 *
 * Mirrors `putOnMarketAttestation` in `put_on_market_model.dart`. It names the
 * offence rather than gesturing at it: an attestation reading only "I confirm
 * this is accurate" would put the signatory on notice of nothing, and the
 * gazette's enforcement clause is the reason the declaration is worth having.
 */
const ATTESTATION_TEXT =
  'I confirm that the figures above are a true and complete statement of the ' +
  'plastic my company placed on the Bangladesh market in this period, to the ' +
  'best of my knowledge and from my company’s own records. I understand that ' +
  'providing false information under the Guidelines for Extended Producer ' +
  'Responsibility Implementation for Plastics may result in suspension or ' +
  'cancellation of my company’s registration and in legal action, and that ' +
  'the Department of Environment may audit and verify this data.';

function documentId(orgId, periodId) {
  return `${orgId}_${periodId}`;
}

/**
 * Normalises and validates the declared lines.
 *
 * Returns `{lines, problems}`. Every problem, not the first — a producer
 * correcting a filing should see the whole list rather than discovering the
 * next one after each save.
 */
function normalizeLines(raw) {
  const problems = [];

  if (!Array.isArray(raw) || raw.length === 0) {
    return {
      lines: null,
      problems: [
        'Declare at least one gazette category, even if the figure is nil.',
      ],
    };
  }

  const lines = [];
  const seen = new Set();

  for (const entry of raw) {
    if (!entry || typeof entry !== 'object') {
      problems.push('One of the lines could not be read.');
      continue;
    }

    const { category } = entry;
    if (!GAZETTE_CATEGORIES.includes(category)) {
      problems.push(`"${category}" is not one of ${GAZETTE_CATEGORIES.join(', ')}.`);
      continue;
    }

    if (seen.has(category)) {
      // Two lines for one category would double a denominator or, worse, let
      // one line be read and the other ignored depending on iteration order.
      problems.push(`There are two lines for ${category}. Combine them.`);
      continue;
    }

    const units = Number.isInteger(entry.units) ? entry.units : null;
    const massMg = Number.isInteger(entry.massMg)
      ? entry.massMg
      : massMgFromGrams(entry.massG);

    if (units === null || units < 0) {
      problems.push(`${category}: the unit count is not a whole number.`);
      continue;
    }
    if (massMg === null || massMg < 0) {
      problems.push(`${category}: the mass could not be read.`);
      continue;
    }
    if (units > MAX_CATEGORY_UNITS) {
      problems.push(`${category}: that unit count is implausibly large.`);
      continue;
    }
    if (massMg > MAX_CATEGORY_MASS_MG) {
      // Refused, not clamped. Almost always grams entered as kilograms, and a
      // denominator three orders of magnitude too large drives the reported
      // rate to effectively zero — hiding a real collection programme behind a
      // typo.
      problems.push(
        `${category}: ${Math.round(massMg / MG_PER_KILOGRAM)} kg in one month ` +
          'is implausible. Check whether the figure is in the right unit.',
      );
      continue;
    }
    if ((units === 0) !== (massMg === 0)) {
      // Half-entered. Both zero is a legitimate nil declaration, which is why
      // that case is not refused.
      problems.push(
        `${category}: give both a unit count and a mass, or nil for both.`,
      );
      continue;
    }

    seen.add(category);
    lines.push({
      category,
      units,
      massMg,
      // Alongside for a human reading the console; the milligram value is
      // authoritative.
      massG: massMg / MG_PER_GRAM,
    });
  }

  // Gazette order, so two periods' filings are directly comparable and an
  // export does not reshuffle.
  lines.sort(
    (a, b) =>
      GAZETTE_CATEGORIES.indexOf(a.category) -
      GAZETTE_CATEGORIES.indexOf(b.category),
  );

  return { lines: problems.length === 0 ? lines : null, problems };
}

/**
 * A gram figure to integer milligrams, strictly.
 *
 * The same whole-string parse as `producerSkus.js`, and for the same reason:
 * `parseFloat` prefix-parses, so '61,000' would become 61 — a denominator a
 * thousand times too small, which is exactly the direction that flatters a
 * producer's percentage.
 */
function massMgFromGrams(grams) {
  let value;
  if (typeof grams === 'number') {
    value = grams;
  } else if (typeof grams === 'string') {
    const trimmed = grams.trim();
    value = /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/.test(trimmed)
      ? Number(trimmed)
      : NaN;
  } else {
    return null;
  }

  if (!Number.isFinite(value) || value < 0) return null;
  return Math.round(value * MG_PER_GRAM);
}

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

/**
 * Saves a draft declaration.
 *
 * A draft is not a denominator: `isUsable` on the model gates on `submitted`,
 * and every read path here returns the status so nothing can mistake one.
 */
async function saveDraft({ orgId, periodId, lines, attestedByName, note, actorUid, actorName = '' }) {
  if (!eprPeriod.isValidPeriodId(periodId)) {
    throw badRequest('That is not a reporting period.');
  }

  const { lines: normalized, problems } = normalizeLines(lines);
  if (problems.length > 0) {
    const error = new Error(problems.join(' '));
    error.problems = problems;
    error.code = 'invalid_declaration';
    throw error;
  }

  const firestore = db();
  const ref = firestore.collection(DECLARATIONS).doc(documentId(orgId, periodId));

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(ref);
    const existing = snap.exists ? snap.data() : null;

    if (existing && existing.status === 'submitted') {
      // Locked. A correction is an explicit act with its own route, because
      // superseding a filed figure has consequences a save must not have:
      // it supersedes every passport issued against it (EPR-30).
      throw conflict(
        'This declaration has been filed and is locked. Submit a correction if '
          + 'the figures have changed.',
      );
    }

    await audit.appendInTransaction(txn, {
      orgId,
      action: audit.ACTIONS.DECLARATION_SAVED,
      actorUid,
      actorName,
      actorRole: 'producer',
      targetType: 'declaration',
      targetId: documentId(orgId, periodId),
      summary: `Put-on-market draft saved for ${periodId}.`,
      after: { periodId, lineCount: normalized.length },
    });

    const record = {
      orgId,
      periodId,
      lines: normalized,
      attestedByName: String(attestedByName || '').slice(0, 120),
      note: note ? String(note).slice(0, 1000) : null,
      status: 'draft',
      updatedAt: serverTimestamp(),
      updatedBy: actorUid,
    };

    if (!existing) {
      record.version = 0;
      record.createdAt = serverTimestamp();
      record.createdBy = actorUid;
      txn.set(ref, record);
    } else {
      txn.update(ref, record);
    }

    return { orgId, periodId, status: 'draft' };
  });
}

/**
 * Attests and locks a declaration (EPR-24).
 *
 * ## What submission does that a save does not
 *
 * It records the attestation — the name, the server clock, the uid, and the
 * exact words — and it writes an immutable version row. From this moment the
 * figures are a denominator, and they cannot be edited: only superseded.
 *
 * ## Why the attestation is recorded here rather than sent by the client
 *
 * The client sends a name. It does not send `attestedAt`, and it does not send
 * the attestation text. Both are written by the party that witnessed the act:
 * a timestamp from a device clock is not evidence of when something was
 * attested, and attestation text supplied by the attester is not evidence of
 * what they were shown.
 */
async function submitDeclaration({ orgId, periodId, attestedByName, actorUid, actorName = '' }) {
  if (!eprPeriod.isValidPeriodId(periodId)) {
    throw badRequest('That is not a reporting period.');
  }
  if (typeof attestedByName !== 'string' || attestedByName.trim().length < 2) {
    throw badRequest('Name the person attesting to these figures.');
  }

  const firestore = db();
  const ref = firestore.collection(DECLARATIONS).doc(documentId(orgId, periodId));

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(ref);
    if (!snap.exists) throw badRequest('There is no draft to file.');

    const existing = snap.data();
    if (existing.orgId !== orgId) throw badRequest('There is no draft to file.');
    if (existing.status === 'submitted') {
      throw conflict('This declaration has already been filed.');
    }

    const { lines, problems } = normalizeLines(existing.lines);
    if (problems.length > 0) {
      const error = new Error(problems.join(' '));
      error.problems = problems;
      error.code = 'invalid_declaration';
      throw error;
    }

    const version = (Number.isInteger(existing.version) ? existing.version : 0) + 1;
    const now = admin.firestore.Timestamp.now();
    const totalMassMg = lines.reduce((sum, l) => sum + l.massMg, 0);

    await audit.appendInTransaction(txn, {
      orgId,
      action: audit.ACTIONS.DECLARATION_SUBMITTED,
      actorUid,
      actorName,
      actorRole: 'producer',
      targetType: 'declaration',
      targetId: documentId(orgId, periodId),
      summary:
        `Put-on-market declaration filed for ${periodId}, version ${version}: ` +
        `${Math.round(totalMassMg / MG_PER_KILOGRAM)} kg across ` +
        `${lines.length} ${lines.length === 1 ? 'category' : 'categories'}, ` +
        `attested by ${attestedByName.trim()}.`,
      after: { periodId, version, totalMassMg },
    });

    // The immutable version row. `putOnMarketDeclarations` holds the current
    // statement; this holds every statement ever made, so a report issued last
    // quarter stays reproducible after a correction this quarter — the same
    // reasoning as `skuRevisions` (EPR-12).
    txn.set(firestore.collection(VERSIONS).doc(`${documentId(orgId, periodId)}_${version}`), {
      orgId,
      periodId,
      version,
      lines,
      totalMassMg,
      attestedByName: attestedByName.trim(),
      attestedByUid: actorUid,
      attestedAt: now,
      attestationText: ATTESTATION_TEXT,
      note: existing.note ?? null,
      createdAt: serverTimestamp(),
    });

    txn.update(ref, {
      status: 'submitted',
      version,
      lines,
      totalMassMg,
      attestedByName: attestedByName.trim(),
      attestedByUid: actorUid,
      attestedAt: now,
      // Copied onto the document, not referenced. If Chokro revises its
      // wording, this filing keeps the words its signatory actually saw.
      attestationText: ATTESTATION_TEXT,
      submittedAt: serverTimestamp(),
    });

    return { orgId, periodId, version, status: 'submitted', totalMassMg };
  });
}

/**
 * Opens a correction to a filed declaration (EPR-24, EPR-30).
 *
 * ## Why this is its own route and not a save
 *
 * Superseding a filed figure has consequences a save must not have. Every
 * passport issued against the old version is marked superseded, because a
 * certificate stating a percentage computed from a withdrawn denominator is a
 * certificate that is no longer true — and a third party holding it must be
 * able to discover that from the verification endpoint.
 *
 * So a correction reopens the declaration as a draft, marks the superseded
 * version, and supersedes the affected passports in the same transaction. The
 * producer then edits and files again, which writes version n+1.
 */
async function openCorrection({ orgId, periodId, reason, actorUid, actorName = '' }) {
  if (typeof reason !== 'string' || reason.trim().length < 5) {
    // A correction with no stated reason is indistinguishable from a
    // manipulation, and EPR-43's variance review has nothing to read.
    throw badRequest('Say why the figures are being corrected.');
  }

  const firestore = db();
  const ref = firestore.collection(DECLARATIONS).doc(documentId(orgId, periodId));

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(ref);
    if (!snap.exists) throw badRequest('There is no filed declaration to correct.');

    const existing = snap.data();
    if (existing.orgId !== orgId) {
      throw badRequest('There is no filed declaration to correct.');
    }
    if (existing.status !== 'submitted') {
      throw conflict('Only a filed declaration can be corrected.');
    }

    // Every passport issued for this organisation and period. Read before any
    // write, as Firestore requires.
    const affected = await txn.get(
      firestore
        .collection(PASSPORTS)
        .where('orgId', '==', orgId)
        .where('periodId', '==', periodId)
        .where('status', '==', 'issued')
        .limit(50),
    );

    await audit.appendInTransaction(txn, {
      orgId,
      action: audit.ACTIONS.DECLARATION_CORRECTED,
      actorUid,
      actorName,
      actorRole: 'producer',
      targetType: 'declaration',
      targetId: documentId(orgId, periodId),
      summary:
        `Put-on-market declaration for ${periodId} reopened for correction ` +
        `(version ${existing.version} superseded): ${reason.trim()}` +
        (affected.size > 0
          ? ` ${affected.size} issued ${affected.size === 1 ? 'passport' : 'passports'} superseded.`
          : ''),
      before: { version: existing.version, totalMassMg: existing.totalMassMg },
    });

    // Mark the version row superseded. Kept, never deleted.
    if (Number.isInteger(existing.version) && existing.version > 0) {
      txn.set(
        firestore
          .collection(VERSIONS)
          .doc(`${documentId(orgId, periodId)}_${existing.version}`),
        {
          supersededAt: serverTimestamp(),
          supersededReason: reason.trim().slice(0, 500),
          supersededBy: actorUid,
        },
        { merge: true },
      );
    }

    // EPR-30: a passport issued against a superseded declaration is marked
    // superseded, and the verification endpoint says so.
    for (const doc of affected.docs) {
      txn.update(doc.ref, {
        status: 'superseded',
        supersededAt: serverTimestamp(),
        supersededReason:
          'The put-on-market declaration this certificate was computed against ' +
          'has been corrected.',
      });
    }

    txn.update(ref, {
      status: 'draft',
      correctionReason: reason.trim().slice(0, 500),
      correctionOpenedAt: serverTimestamp(),
      correctionOpenedBy: actorUid,
      // The attestation of the superseded version does not carry forward. The
      // new figures need their own.
      attestedAt: null,
      attestedByUid: null,
      attestationText: null,
      submittedAt: null,
    });

    return {
      orgId,
      periodId,
      status: 'draft',
      supersededVersion: existing.version,
      passportsSuperseded: affected.size,
    };
  });
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

async function getDeclaration({ orgId, periodId }) {
  const snap = await db()
    .collection(DECLARATIONS)
    .doc(documentId(orgId, periodId))
    .get();
  return snap.exists ? { id: snap.id, ...snap.data() } : null;
}

/** One organisation's declarations, newest period first. Bounded (QA-10). */
async function listDeclarations({ orgId, limit = 24 }) {
  const snap = await db()
    .collection(DECLARATIONS)
    .where('orgId', '==', orgId)
    .orderBy('periodId', 'desc')
    .limit(limit)
    .get();
  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

/** Every version ever filed for one period, oldest first. */
async function listVersions({ orgId, periodId, limit = 20 }) {
  const snap = await db()
    .collection(VERSIONS)
    .where('orgId', '==', orgId)
    .where('periodId', '==', periodId)
    .orderBy('version', 'asc')
    .limit(limit)
    .get();
  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

/**
 * The declared mass per category for a period, or null if none is usable.
 *
 * THE ONE FUNCTION A REPORT MAY ASK FOR A DENOMINATOR.
 *
 * Null when no declaration exists, when it is still a draft, or when it has
 * been reopened for correction. A caller that receives null must state the
 * absence rather than substitute a figure (EPR-24), and there is no variant of
 * this function that returns a fallback.
 */
async function declaredMassByCategory({ orgId, periodId }) {
  const declaration = await getDeclaration({ orgId, periodId });
  if (!declaration || declaration.status !== 'submitted') return null;
  if (!Array.isArray(declaration.lines)) return null;

  const byCategory = {};
  for (const line of declaration.lines) {
    if (!GAZETTE_CATEGORIES.includes(line.category)) continue;
    if (!Number.isInteger(line.massMg) || line.massMg < 0) continue;
    byCategory[line.category] = line.massMg;
  }
  return byCategory;
}

/**
 * The review queue for Chokro (EPR-43).
 *
 * Filed declarations with their period-over-period variance, so an Admin sees
 * "a declaration that moves 60% against the previous period without a note"
 * without having to compute it.
 */
async function listForReview({ limit = 50 }) {
  const snap = await db()
    .collection(DECLARATIONS)
    .where('status', '==', 'submitted')
    .orderBy('submittedAt', 'desc')
    .limit(limit)
    .get();

  const filed = snap.docs.map((d) => ({ id: d.id, ...d.data() }));

  return Promise.all(
    filed.map(async (declaration) => {
      const previousPeriod = eprPeriod.previousPeriodId(declaration.periodId);
      const previous = await getDeclaration({
        orgId: declaration.orgId,
        periodId: previousPeriod,
      });

      const previousMassMg =
        previous && previous.status === 'submitted'
          ? previous.totalMassMg ?? null
          : null;

      const currentMassMg = declaration.totalMassMg ?? null;

      // Null rather than zero for a first filing: reporting no comparison as
      // no change would hide the fact that there is nothing to compare against.
      const variance =
        Number.isInteger(currentMassMg) &&
        Number.isInteger(previousMassMg) &&
        previousMassMg > 0
          ? (currentMassMg - previousMassMg) / previousMassMg
          : null;

      // The same period's superseded version, where there is one.
      //
      // EPR-43 asks for period-over-period variance, and that is `variance`
      // above. This is a second signal, and for the threat §16 names —
      // "producer understates put-on-market" for "a flattering percentage" —
      // it is the sharper of the two.
      //
      // A producer that files 18,000 kg, sees 28% against it, and then
      // "corrects" the figure to 7,000 kg to show 72% is not caught by
      // period-over-period variance at all: if the previous month is similar,
      // the corrected figure may look no stranger than the original did. What
      // is unmistakable is the withdrawal itself. §16 lists retained versions
      // as part of the control for that threat, so this reads them.
      const priorVersionMassMg = await previousVersionMass(declaration);
      const correctionVariance =
        Number.isInteger(currentMassMg) &&
        Number.isInteger(priorVersionMassMg) &&
        priorVersionMassMg > 0
          ? (currentMassMg - priorVersionMassMg) / priorVersionMassMg
          : null;

      return {
        ...declaration,
        previousPeriod,
        previousMassMg,
        variance,
        priorVersionMassMg,
        correctionVariance,
      };
    }),
  );
}

/**
 * The declared total from the version this one superseded, or null.
 *
 * Version rows are immutable and never deleted, which is what makes this
 * readable at all — and is why EPR-30 supersedes a corrected declaration's
 * passports rather than editing them.
 */
async function previousVersionMass(declaration) {
  const version = declaration.version;
  if (!Number.isInteger(version) || version < 2) return null;

  const snap = await db()
    .collection(VERSIONS)
    .doc(`${documentId(declaration.orgId, declaration.periodId)}_${version - 1}`)
    .get();

  if (!snap.exists) return null;
  const total = snap.data().totalMassMg;
  return Number.isInteger(total) ? total : null;
}

function badRequest(message) {
  const error = new Error(message);
  error.code = 'bad_request';
  return error;
}

function conflict(message) {
  const error = new Error(message);
  error.code = 'conflict';
  return error;
}

module.exports = {
  DECLARATIONS,
  VERSIONS,
  GAZETTE_CATEGORIES,
  MAX_CATEGORY_MASS_MG,
  MAX_CATEGORY_UNITS,
  ATTESTATION_TEXT,
  documentId,
  normalizeLines,
  massMgFromGrams,
  saveDraft,
  submitDeclaration,
  openCorrection,
  getDeclaration,
  listDeclarations,
  listVersions,
  declaredMassByCategory,
  listForReview,
};
