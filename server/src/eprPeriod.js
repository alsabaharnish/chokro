/**
 * Chokro — reporting periods in Asia/Dhaka (EPR-23).
 *
 * The server's copy of `lib/core/epr_period.dart`. Duplicated across the
 * language boundary because there is no shared runtime, and pinned to the same
 * boundary cases in both test suites so a divergence shows up as a failing test
 * rather than as a disposal filed in the wrong month.
 *
 * THIS COPY IS THE AUTHORITY. Every stored `periodId` is derived here, from the
 * server's own clock, at the moment a disposal reaches a terminal decision. The
 * Dart copy exists so a screen can label and group what it is shown; it never
 * decides which period a stored figure belongs to.
 *
 * WHY A FIXED OFFSET IS CORRECT
 * Asia/Dhaka is UTC+6 with no daylight saving. Bangladesh has observed DST
 * exactly once, June to December 2009, at UTC+7. Every timestamp this system
 * will hold is 2026 or later, so the offset is constant for all data in scope.
 * If that changes, DHAKA_OFFSET_MS is the one thing to change, and historical
 * periods must be *recomputed* rather than reinterpreted — which is what
 * `recomputedAt` on `eprPeriods` is for.
 */

/** Asia/Dhaka's fixed offset from UTC, in milliseconds. */
const DHAKA_OFFSET_MS = 6 * 60 * 60 * 1000;

/**
 * The `periodId` a moment falls in, formatted `YYYY-MM`.
 *
 * A disposal decided at 02:00 on 1 October Dhaka time is 20:00 on 30 September
 * in UTC. Taking the period from the UTC month would file it in September, and
 * both months would then be reported to a regulator — one short, one long, with
 * nothing in either document that looks wrong.
 *
 * @param {Date|number|{toDate: function}} moment a Date, epoch millis, or a
 *   Firestore Timestamp
 * @returns {string|null} null when the input is not a usable instant, so a
 *   caller must decide rather than receiving a plausible wrong month
 */
function periodIdFor(moment) {
  const date =
    moment?.toDate?.() ??
    (moment instanceof Date ? moment : typeof moment === 'number' ? new Date(moment) : null);

  if (!date || Number.isNaN(date.getTime())) return null;

  const shifted = new Date(date.getTime() + DHAKA_OFFSET_MS);
  const year = shifted.getUTCFullYear();
  const month = String(shifted.getUTCMonth() + 1).padStart(2, '0');
  return `${year}-${month}`;
}

/** Whether a value is a well-formed `periodId` this system will accept. */
function isValidPeriodId(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}$/.test(value)) return false;

  const month = Number.parseInt(value.slice(5), 10);
  if (month < 1 || month > 12) return false;

  const year = Number.parseInt(value.slice(0, 4), 10);
  // The gazette was published in 2026; a period before it carries no
  // obligation, and one far ahead is a typo rather than a forecast.
  return year >= 2026 && year <= 2100;
}

/** The first instant of a period, as a UTC Date. Half-open: `[start, end)`. */
function periodStartUtc(periodId) {
  const year = Number.parseInt(periodId.slice(0, 4), 10);
  const month = Number.parseInt(periodId.slice(5), 10);
  return new Date(Date.UTC(year, month - 1, 1) - DHAKA_OFFSET_MS);
}

/** The first instant of the next period — the exclusive end. */
function periodEndUtc(periodId) {
  const year = Number.parseInt(periodId.slice(0, 4), 10);
  const month = Number.parseInt(periodId.slice(5), 10);
  return new Date(Date.UTC(year, month, 1) - DHAKA_OFFSET_MS);
}

function previousPeriodId(periodId) {
  const year = Number.parseInt(periodId.slice(0, 4), 10);
  const month = Number.parseInt(periodId.slice(5), 10);
  const priorYear = month === 1 ? year - 1 : year;
  const priorMonth = month === 1 ? 12 : month - 1;
  return `${priorYear}-${String(priorMonth).padStart(2, '0')}`;
}

function nextPeriodId(periodId) {
  const year = Number.parseInt(periodId.slice(0, 4), 10);
  const month = Number.parseInt(periodId.slice(5), 10);
  const laterYear = month === 12 ? year + 1 : year;
  const laterMonth = month === 12 ? 1 : month + 1;
  return `${laterYear}-${String(laterMonth).padStart(2, '0')}`;
}

/**
 * Makes a free-text value safe as a Firestore map key.
 *
 * ONE DEFINITION, BECAUSE THREE PLACES HAD TO AGREE AND DID NOT.
 *
 * District names come from the bin registry as free text. A key containing a
 * dot is read by `FieldValue.increment` as a nested field path, so
 * "St. Martin's" would create a map called `St` with a child called `Martin's`
 * rather than a single key.
 *
 * The attribution path sanitised on write. The recompute and the reversal did
 * not. The consequences of that disagreement, in order of severity:
 *
 *   A REVERSAL decremented a key that had never been written, creating a
 *   NEGATIVE district total in a compliance rollup.
 *
 *   A RECOMPUTE rebuilt the period under the raw name, so it never matched the
 *   incremented figure — every such period reported a reconciliation mismatch
 *   that was an artefact of two spellings rather than a real discrepancy, which
 *   is exactly the noise that makes a real mismatch easy to dismiss.
 *
 * So the function lives here, in the module all three already import, and each
 * of them calls it.
 */
function sanitizeMapKey(value) {
  return String(value)
    // A run of separators, with surrounding whitespace, collapses to one — so
    // two districts differing only in punctuation do not become two keys.
    // Whitespace alone is left, so "Cox's Bazar" stays readable when a screen
    // prints the key back.
    .replace(/\s*[.$[\]#/]+\s*/g, '_')
    .slice(0, 100);
}

/** The composite rollup document id: `{orgId}_{periodId}`. */
function eprPeriodDocumentId(orgId, periodId) {
  return `${orgId}_${periodId}`;
}

module.exports = {
  DHAKA_OFFSET_MS,
  sanitizeMapKey,
  periodIdFor,
  isValidPeriodId,
  periodStartUtc,
  periodEndUtc,
  previousPeriodId,
  nextPeriodId,
  eprPeriodDocumentId,
};
