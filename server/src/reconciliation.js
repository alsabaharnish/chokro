/**
 * Chokro — reconciliation and the standing accuracy audit (EPR-17, EPR-48).
 *
 * ===========================================================================
 * TWO QUESTIONS, BOTH ABOUT WHETHER CHOKRO'S OWN NUMBERS ARE DEFENSIBLE
 * ===========================================================================
 *
 * **Do the counters agree with the evidence?** Collected mass is counted twice
 * by design: incremented as each attribution commits, and recomputed from the
 * raw rows on demand. A disagreement means a lost write, a double count, or a
 * bug — and QA-3 requires it surfaced rather than silently corrected, which is
 * why `storeRecomputeResult` never overwrites the incremented figure. This file
 * is what finally READS those flags: a recorded mismatch nobody looks at is the
 * same as no check at all.
 *
 * **How often is the recognition right?** EPR-17 requires a standing accuracy
 * audit — a random sample of high-confidence matches reviewed by a human
 * regardless — and says the measured precision is published in report
 * methodology. `attribute.js` has been writing that sample into
 * `attributionConfirmations` since Phase C.
 *
 * Nothing has ever resolved one. The queue fills, and the accuracy figure the
 * methodology statement is supposed to carry has never been measurable. That is
 * the gap this file closes.
 *
 * ===========================================================================
 * WHAT CAN HONESTLY BE MEASURED, AND WHAT CANNOT
 * ===========================================================================
 *
 * EPR-17 says "precision/recall". Only one of those is observable from this
 * sample, and saying so matters more than producing two numbers:
 *
 *   PRECISION IS MEASURABLE. Of the high-confidence matches Chokro attributed
 *   and a human then reviewed, what share were right? The sample is drawn from
 *   what the model claimed, so the denominator is known.
 *
 *   RECALL IS NOT. Recall asks what share of the packaging that WAS in a
 *   photograph the model found — and nothing in this system knows what was in a
 *   photograph that the model did not report. Measuring it would need every
 *   sampled disposal exhaustively labelled by a human, which is a different and
 *   much larger exercise.
 *
 * So `accuracySnapshot` reports precision, reports the size of the sample it
 * rests on, and states the recall limit in the same breath. A methodology
 * section that published a recall figure derived from this queue would be
 * publishing a number nobody could defend — which is the one thing this whole
 * feature exists to avoid.
 */

const { db, admin, serverTimestamp } = require('./firebase');
const audit = require('./producerAudit');
const eprPeriod = require('./eprPeriod');
const eprPeriods = require('./eprPeriods');

const CONFIRMATIONS = 'attributionConfirmations';
const PERIODS = 'eprPeriods';
const ORGS = 'organizations';

/** Why a match reached the queue. Written by `attribute.js`. */
const REASONS = Object.freeze({
  /// Below the attribution threshold: never attributed, awaiting a human.
  LOW_CONFIDENCE: 'lowConfidence',
  /// Attributed automatically, then sampled anyway — EPR-17's standing audit.
  ACCURACY_AUDIT: 'accuracyAudit',
});

const VERDICTS = Object.freeze(['correct', 'incorrect', 'unclear']);

/**
 * How many periods an accuracy snapshot looks back over.
 *
 * Twelve, matching the annual report's span. Long enough that a month with few
 * samples does not swing the figure, short enough that a model improvement is
 * visible within a year rather than diluted forever.
 */
const ACCURACY_WINDOW_PERIODS = 12;

// ---------------------------------------------------------------------------
// The accuracy audit (EPR-17)
// ---------------------------------------------------------------------------

/**
 * Records a human verdict on a sampled match.
 *
 * ## Why a verdict is not a correction
 *
 * Marking a high-confidence match `incorrect` does NOT reverse the attribution.
 * It is evidence about the model, and reversing on the strength of one
 * reviewer's read would make the accuracy audit a second, unaccountable
 * attribution path — with no reason recorded against the mass it removed.
 *
 * Reversal is its own act, through `reverseAttribution`, with its own reason
 * and its own audit entry. This records what the reviewer saw; an Admin who
 * then wants the mass removed does that deliberately.
 *
 * ## Why `unclear` is a verdict rather than a skip
 *
 * A photograph too dark to judge is a real outcome, and folding it into either
 * `correct` or `incorrect` would bias precision in whichever direction the
 * reviewer felt generous. Counted separately and excluded from the ratio, with
 * its share reported so a reader can see how much of the sample was unusable.
 */
async function resolveConfirmation({
  confirmationId,
  verdict,
  note = '',
  adminUid,
  adminName = '',
}) {
  if (!VERDICTS.includes(verdict)) {
    throw badRequest(`A verdict is ${VERDICTS.join(', ')} — not "${verdict}".`);
  }

  const ref = db().collection(CONFIRMATIONS).doc(confirmationId);
  const snap = await ref.get();
  if (!snap.exists) throw badRequest('That sampled match does not exist.');

  const row = snap.data();
  if (row.status !== 'pending') {
    throw conflict('That sampled match has already been reviewed.');
  }

  await audit.append({
    orgId: row.orgId || '__platform',
    action: audit.ACTIONS.ACCURACY_REVIEWED,
    actorUid: adminUid,
    actorName: adminName,
    actorRole: 'admin',
    targetType: 'confirmation',
    targetId: confirmationId,
    summary:
      `Sampled ${row.confidenceTier || 'unknown'}-confidence match on `
      + `${row.skuId || 'an unregistered product'} reviewed as ${verdict}`
      + (note ? `: ${note.trim()}` : '.'),
  });

  await ref.update({
    status: 'reviewed',
    verdict,
    reviewedBy: adminUid,
    reviewedByName: adminName,
    reviewedAt: serverTimestamp(),
    reviewNote: String(note || '').slice(0, 500),
  });

  return { confirmationId, verdict };
}

/** The pending sample, oldest first — a queue is worked from the front. */
async function listPendingSample({ reason = null, limit = 50 }) {
  let query = db().collection(CONFIRMATIONS).where('status', '==', 'pending');
  if (reason) {
    if (!Object.values(REASONS).includes(reason)) {
      throw badRequest(`"${reason}" is not a sampling reason.`);
    }
    query = query.where('reason', '==', reason);
  }

  const snap = await query.orderBy('createdAt', 'asc').limit(limit).get();
  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

/**
 * The measured precision of high-confidence recognition, and its trend
 * (EPR-17, EPR-48).
 *
 * Returns nulls rather than figures when the sample is too small to support
 * one. A precision of "100%" over three reviewed matches is not a measurement,
 * and publishing it in a methodology section would be the overstatement this
 * whole system is built to avoid.
 */
async function accuracySnapshot({ endPeriodId, minSample = 30 }) {
  const periods = eprPeriod.isValidPeriodId(endPeriodId)
    ? periodsEndingAt(endPeriodId, ACCURACY_WINDOW_PERIODS)
    : [];

  if (periods.length === 0) {
    throw badRequest('That is not a reporting period.');
  }

  const snap = await db()
    .collection(CONFIRMATIONS)
    .where('status', '==', 'reviewed')
    .where('reason', '==', REASONS.ACCURACY_AUDIT)
    .orderBy('reviewedAt', 'desc')
    .limit(2000)
    .get();

  const inWindow = snap.docs
    .map((d) => d.data())
    .filter((row) => periods.includes(row.periodId));

  const byPeriod = new Map(periods.map((p) => [p, { correct: 0, incorrect: 0, unclear: 0 }]));
  for (const row of inWindow) {
    const bucket = byPeriod.get(row.periodId);
    if (!bucket) continue;
    if (row.verdict === 'correct') bucket.correct += 1;
    else if (row.verdict === 'incorrect') bucket.incorrect += 1;
    else bucket.unclear += 1;
  }

  const totals = { correct: 0, incorrect: 0, unclear: 0 };
  for (const bucket of byPeriod.values()) {
    totals.correct += bucket.correct;
    totals.incorrect += bucket.incorrect;
    totals.unclear += bucket.unclear;
  }

  const judged = totals.correct + totals.incorrect;
  const reviewed = judged + totals.unclear;

  return {
    windowPeriods: periods,
    reviewed,
    judged,
    correct: totals.correct,
    incorrect: totals.incorrect,
    unclear: totals.unclear,

    // Null below the floor. A figure over a handful of reviews is not a
    // measurement, and a methodology section is exactly where an unsupported
    // number does the most damage.
    precision: judged >= minSample ? totals.correct / judged : null,
    minSample,
    precisionAbsenceReason:
      judged >= minSample
        ? null
        : `Only ${judged} sampled matches have been reviewed with a clear `
          + `verdict; ${minSample} are needed before a precision figure means `
          + 'anything.',

    // The share of the sample a reviewer could not judge. Reported rather than
    // hidden: a high figure here says the photographs are the problem, not the
    // model, and that is a different fix.
    unclearShare: reviewed > 0 ? totals.unclear / reviewed : null,

    // EPR-17 names "precision/recall". Only precision is observable from a
    // sample drawn from what the model CLAIMED — nothing here knows what was in
    // a photograph that the model did not report.
    recall: null,
    recallAbsenceReason:
      'Recall is not measurable from this sample. The audit draws from matches '
      + 'Chokro made, so it can say how often those were right; it cannot say '
      + 'what Chokro missed. Measuring recall would require every sampled '
      + 'disposal exhaustively labelled by a human.',

    trend: periods.map((periodId) => {
      const bucket = byPeriod.get(periodId);
      const periodJudged = bucket.correct + bucket.incorrect;
      return {
        periodId,
        reviewed: periodJudged + bucket.unclear,
        judged: periodJudged,
        // Per-period precision is reported without the sample floor, because
        // the trend is read as a shape rather than as a set of published
        // figures — but the count is beside it so a spike on two reviews is
        // visible for what it is.
        precision: periodJudged > 0 ? bucket.correct / periodJudged : null,
      };
    }),
  };
}

// ---------------------------------------------------------------------------
// Reconciliation (EPR-48, QA-3)
// ---------------------------------------------------------------------------

/**
 * Every period that has been recomputed, with its variance.
 *
 * ## Why mismatches are listed separately rather than sorted to the top
 *
 * A console that merely ordered by variance would put the worst first and let
 * the rest scroll away. The count of NEVER-RECOMPUTED periods is the figure an
 * auditor actually asks about — "how much of this has anyone checked?" — and it
 * cannot be read off a sorted list at all.
 */
async function reconciliationOverview({ limit = 200 }) {
  const snap = await db().collection(PERIODS).limit(limit).get();

  const rows = snap.docs
    .map((d) => ({ id: d.id, ...d.data() }))
    // The platform's unattributed pool is not an organisation's period and has
    // no declaration or certificate behind it (EPR-19).
    .filter((row) => row.orgId && row.orgId !== '__platform');

  const reconciled = [];
  const mismatched = [];
  const unchecked = [];

  for (const row of rows) {
    const incrementedMassMg = sumMap(row.massMgByCategory);

    if (!row.recomputedAt) {
      unchecked.push({
        orgId: row.orgId,
        periodId: row.periodId,
        incrementedMassMg,
        attributionCount: intOr0(row.attributionCount),
      });
      continue;
    }

    const entry = {
      orgId: row.orgId,
      periodId: row.periodId,
      incrementedMassMg,
      recomputedMassMg: intOr0(row.recomputedMassMg),
      variance: intOr0(row.recomputedMassMg) - incrementedMassMg,
      recomputedAt: row.recomputedAt ?? null,
      recomputedBy: row.recomputedBy ?? null,
      matched: row.recomputeMatched === true,
    };

    if (entry.matched) reconciled.push(entry);
    else mismatched.push(entry);
  }

  // Worst variance first within the mismatched list, by absolute magnitude: a
  // period short by 40 kg and one long by 40 kg are equally wrong.
  mismatched.sort((a, b) => Math.abs(b.variance) - Math.abs(a.variance));
  unchecked.sort((a, b) => b.incrementedMassMg - a.incrementedMassMg);

  return {
    periodsExamined: rows.length,
    reconciled: reconciled.length,
    mismatched,
    // Bounded in the response for the same reason every list here is, but the
    // COUNT is the honest total.
    uncheckedCount: unchecked.length,
    unchecked: unchecked.slice(0, 50),
    uncheckedMassMg: unchecked.reduce((sum, p) => sum + p.incrementedMassMg, 0),
  };
}

/**
 * One organisation's reconciliation history.
 *
 * Reads the stored rollups rather than recomputing, so opening the console does
 * not trigger a year of reads per producer.
 */
async function organizationReconciliation({ orgId, limit = 24 }) {
  const [periods, orgSnap] = await Promise.all([
    eprPeriods.listPeriods({ orgId, limit }),
    db().collection(ORGS).doc(orgId).get(),
  ]);

  return {
    orgId,
    tradeName: orgSnap.exists ? orgSnap.data().tradeName ?? '' : '',
    periods: periods.map((row) => {
      const incrementedMassMg = sumMap(row.massMgByCategory);
      return {
        periodId: row.periodId,
        incrementedMassMg,
        recomputedMassMg: row.recomputedAt ? intOr0(row.recomputedMassMg) : null,
        variance: row.recomputedAt
          ? intOr0(row.recomputedMassMg) - incrementedMassMg
          : null,
        matched: row.recomputedAt ? row.recomputeMatched === true : null,
        recomputedAt: row.recomputedAt ?? null,
        reversedCount: intOr0(row.reversedCount),
        attributionCount: intOr0(row.attributionCount),
      };
    }),
  };
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** The `count` periods ending at and including `endPeriodId`. */
function periodsEndingAt(endPeriodId, count) {
  const out = [endPeriodId];
  let cursor = endPeriodId;
  for (let i = 1; i < count; i += 1) {
    cursor = eprPeriod.previousPeriodId(cursor);
    out.push(cursor);
  }
  return out;
}

function sumMap(map) {
  if (!map) return 0;
  return Object.values(map).reduce((sum, mg) => sum + intOr0(mg), 0);
}

function intOr0(value) {
  if (Number.isInteger(value)) return value > 0 ? value : 0;
  if (typeof value === 'number' && Number.isFinite(value)) {
    const rounded = Math.round(value);
    return rounded > 0 ? rounded : 0;
  }
  return 0;
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
  CONFIRMATIONS,
  REASONS,
  VERDICTS,
  ACCURACY_WINDOW_PERIODS,
  resolveConfirmation,
  listPendingSample,
  accuracySnapshot,
  reconciliationOverview,
  organizationReconciliation,
  periodsEndingAt,
};
