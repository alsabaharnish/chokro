/**
 * Chokro — period rollups and their reconciliation (EPR-22, EPR-48).
 *
 * WHY A RECOMPUTE EXISTS AT ALL
 *
 * The rollup is incremented transactionally at attribution time, which makes it
 * a derived figure that can drift from its source. Firestore's
 * `FieldValue.increment` is atomic, so it cannot lose a write — but a document
 * edited by a migration, a reversal applied by hand, or a bug in a future
 * version of the attribution path all can, and none of them would announce
 * itself.
 *
 * §3.3's constraint is that nothing in this system can wake up and do work on a
 * timer. So there is no nightly reconciliation, and this is its substitute: an
 * Admin triggers a rebuild of a period from `attributions`, and the result
 * records **whether the rebuilt total matched the incremented one**. The
 * match/mismatch flag is itself a reportable control (EPR-22), which is why it
 * is stored on the period rather than only returned to whoever asked.
 *
 * A MISMATCH IS SURFACED, NEVER SILENTLY CORRECTED.
 * QA-3 asks for exactly this: "a recompute that disagrees with the incremented
 * total surfacing rather than silently correcting". A rollup quietly rewritten
 * to match its source destroys the only evidence that they ever disagreed —
 * and the disagreement is the finding. So the recomputed figure is stored
 * alongside the incremented one and both are readable.
 *
 * RESUMABLE, BECOUSE A YEAR OF ATTRIBUTIONS IS NOT ONE READ (NFR-E-3).
 * The walk pages through the period in bounded batches and returns a cursor, so
 * an Admin console can drive it to completion across several requests without
 * holding a connection open on a free instance that sleeps.
 */

const { db, admin, serverTimestamp } = require('./firebase');
const eprPeriod = require('./eprPeriod');

const ATTRIBUTIONS = 'attributions';
const PERIODS = 'eprPeriods';

/**
 * How many attribution rows one pass reads.
 *
 * Bounded (QA-10). Sized so a pass completes well inside the free instance's
 * request window rather than to minimise the number of passes — an Admin
 * clicking "continue" four times is a better failure mode than one request
 * timing out with nothing to show.
 */
const RECOMPUTE_BATCH = 500;

/**
 * Rebuilds one period from its attributions.
 *
 * @param {object} args
 * @param {string} args.orgId
 * @param {string} args.periodId
 * @param {string|null} args.cursor  the last attribution id from a prior pass
 * @param {object|null} args.carried the running totals from a prior pass
 * @returns {Promise<object>} `{ complete, cursor, totals, comparison? }`
 */
async function recomputePeriod({
  orgId,
  periodId,
  cursor = null,
  carried = null,
  adminUid = null,
}) {
  if (!eprPeriod.isValidPeriodId(periodId)) {
    throw badRequest('That is not a reporting period.');
  }
  if (typeof orgId !== 'string' || orgId.length === 0) {
    throw badRequest('Name the organisation to recompute.');
  }

  const firestore = db();

  let query = firestore
    .collection(ATTRIBUTIONS)
    .where('orgId', '==', orgId)
    .where('periodId', '==', periodId)
    // Ascending by the server clock, then paged by document id. Ordering by
    // `createdAt` alone would be unstable for rows written in the same
    // transaction, and an unstable order in a resumable walk either skips rows
    // or counts them twice.
    .orderBy('createdAt', 'asc')
    .orderBy(admin.firestore.FieldPath.documentId(), 'asc')
    .limit(RECOMPUTE_BATCH);

  if (cursor) {
    const cursorSnap = await firestore.collection(ATTRIBUTIONS).doc(cursor).get();
    if (cursorSnap.exists) {
      query = query.startAfter(cursorSnap.data().createdAt, cursor);
    }
  }

  const snap = await query.get();
  const totals = carried ? cloneTotals(carried) : emptyTotals();

  for (const doc of snap.docs) {
    accumulate(totals, doc.data());
  }

  const complete = snap.size < RECOMPUTE_BATCH;
  const nextCursor = snap.size > 0 ? snap.docs[snap.docs.length - 1].id : cursor;

  if (!complete) {
    // More to read. Nothing is written yet — a partial rebuild compared against
    // a complete increment would report a mismatch that is an artefact of
    // paging rather than a finding.
    return {
      orgId,
      periodId,
      complete: false,
      cursor: nextCursor,
      totals,
      rowsRead: snap.size,
    };
  }

  const comparison = await storeRecomputeResult({
    orgId,
    periodId,
    totals,
    adminUid,
  });

  return {
    orgId,
    periodId,
    complete: true,
    cursor: null,
    totals,
    ...comparison,
  };
}

/**
 * Writes the rebuilt figure beside the incremented one and records whether
 * they agree.
 *
 * Both are kept. The recomputed total does not replace the incremented one,
 * because the incremented one is what every report issued so far was built
 * from — overwriting it would make a past passport unreproducible in order to
 * tidy a discrepancy.
 */
async function storeRecomputeResult({ orgId, periodId, totals, adminUid }) {
  const firestore = db();
  const periodRef = firestore
    .collection(PERIODS)
    .doc(eprPeriod.eprPeriodDocumentId(orgId, periodId));

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(periodRef);
    const stored = snap.exists ? snap.data() : null;

    const incrementedMassMg = sumMap(stored?.massMgByCategory);
    const recomputedMassMg = sumMap(totals.massMgByCategory);
    const matched = incrementedMassMg === recomputedMassMg;

    txn.set(
      periodRef,
      {
        orgId,
        periodId,
        recomputedAt: serverTimestamp(),
        recomputedBy: adminUid,
        // Stored so the console can show both figures side by side. A flag
        // alone would say that something is wrong and not by how much.
        recomputedMassMg,
        recomputedAttributionCount: totals.attributionCount,
        recomputedDisposalCount: totals.disposalIds.length,
        // The distinct-product set, rebuilt exactly. `uniqueSkuCount` is
        // derived from `skuIds.length` rather than stored, so a recompute
        // repairs the set itself rather than a counter that describes it.
        skuIds: totals.skuIds,
        recomputeMatched: matched,
        recomputeVariance: recomputedMassMg - incrementedMassMg,
      },
      { merge: true },
    );

    return {
      matched,
      incrementedMassMg,
      recomputedMassMg,
      variance: recomputedMassMg - incrementedMassMg,
      incrementedAttributionCount: stored?.attributionCount ?? 0,
      recomputedAttributionCount: totals.attributionCount,
      recomputedDisposalCount: totals.disposalIds.length,
      recomputedUniqueSkuCount: totals.skuIds.length,
    };
  });
}

function emptyTotals() {
  return {
    massMgByCategory: {},
    unitsByCategory: {},
    massMgByPolymer: {},
    massMgByDistrict: {},
    attributionCount: 0,
    uncertainMassMg: 0,
    reversedCount: 0,
    reversedMassMg: 0,
    skuIds: [],
    disposalIds: [],
  };
}

function cloneTotals(totals) {
  return {
    massMgByCategory: { ...totals.massMgByCategory },
    unitsByCategory: { ...totals.unitsByCategory },
    massMgByPolymer: { ...totals.massMgByPolymer },
    massMgByDistrict: { ...totals.massMgByDistrict },
    attributionCount: totals.attributionCount,
    uncertainMassMg: totals.uncertainMassMg,
    reversedCount: totals.reversedCount,
    reversedMassMg: totals.reversedMassMg,
    skuIds: [...totals.skuIds],
    disposalIds: [...totals.disposalIds],
  };
}

/**
 * Adds one attribution row to a running total.
 *
 * A REVERSED ROW CONTRIBUTES NOTHING TO THE MASS AND IS STILL COUNTED.
 * EPR-21 reverses rather than deletes, so the row survives — and a rebuild that
 * added its mass would disagree with an incremented total that had it removed,
 * reporting a mismatch where the two actually agree. Counting reversals
 * separately keeps them visible without putting them in the figure.
 */
function accumulate(totals, row) {
  if (row.reversedAt) {
    totals.reversedCount += 1;
    totals.reversedMassMg += intOr0(row.massMg);
    return;
  }

  const massMg = intOr0(row.massMg);
  const units = intOr0(row.units);

  totals.attributionCount += 1;

  if (row.gazetteCategory) {
    totals.massMgByCategory[row.gazetteCategory] =
      (totals.massMgByCategory[row.gazetteCategory] || 0) + massMg;
    totals.unitsByCategory[row.gazetteCategory] =
      (totals.unitsByCategory[row.gazetteCategory] || 0) + units;
  }

  if (row.district) {
    // The SAME key the attribution path wrote. Rebuilding under the raw name
    // made every period with a punctuated district report a mismatch that was
    // two spellings rather than a discrepancy.
    const key = eprPeriod.sanitizeMapKey(row.district);
    totals.massMgByDistrict[key] = (totals.massMgByDistrict[key] || 0) + massMg;
  }

  if (row.massMgByPolymer && typeof row.massMgByPolymer === 'object') {
    for (const [polymer, mg] of Object.entries(row.massMgByPolymer)) {
      totals.massMgByPolymer[polymer] =
        (totals.massMgByPolymer[polymer] || 0) + intOr0(mg);
    }
  }

  if (row.confidenceTier === 'medium') {
    totals.uncertainMassMg += massMg;
  }

  // Distinct counts, kept as lists during the walk so a resumed pass does not
  // double-count an id it already saw. Bounded by the batch reads that produced
  // them.
  if (row.skuId && !totals.skuIds.includes(row.skuId)) {
    totals.skuIds.push(row.skuId);
  }
  if (row.disposalId && !totals.disposalIds.includes(row.disposalId)) {
    totals.disposalIds.push(row.disposalId);
  }
}

function sumMap(map) {
  if (!map || typeof map !== 'object') return 0;
  return Object.values(map).reduce((sum, value) => sum + intOr0(value), 0);
}

/** A stored counter, tolerating a malformed document. Negative reads as zero. */
function intOr0(value) {
  if (Number.isInteger(value)) return value > 0 ? value : 0;
  if (typeof value === 'number' && Number.isFinite(value)) {
    const rounded = Math.round(value);
    return rounded > 0 ? rounded : 0;
  }
  return 0;
}

/**
 * Reverses one attribution (EPR-21).
 *
 * Marked, never deleted: "an attribution that must be undone is reversed with a
 * reason, never deleted". The rollup is decremented in the same transaction, so
 * the two do not drift — and a later recompute agrees with the decremented
 * figure because `accumulate` skips reversed rows.
 */
async function reverseAttribution({ attributionId, reason, adminUid }) {
  if (typeof reason !== 'string' || reason.trim().length < 5) {
    throw badRequest('Give a reason for the reversal.');
  }

  const firestore = db();
  const attributionRef = firestore.collection(ATTRIBUTIONS).doc(attributionId);
  const increment = admin.firestore.FieldValue.increment;

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(attributionRef);
    if (!snap.exists) throw badRequest('That attribution no longer exists.');

    const row = snap.data();
    if (row.reversedAt) {
      throw badRequest('That attribution has already been reversed.');
    }

    const periodRef = firestore
      .collection(PERIODS)
      .doc(eprPeriod.eprPeriodDocumentId(row.orgId, row.periodId));

    const update = {
      attributionCount: increment(-1),
      reversedCount: increment(1),
      reversedMassMg: increment(intOr0(row.massMg)),
    };

    if (row.gazetteCategory) {
      update[`massMgByCategory.${row.gazetteCategory}`] = increment(
        -intOr0(row.massMg),
      );
      update[`unitsByCategory.${row.gazetteCategory}`] = increment(
        -intOr0(row.units),
      );
    }
    if (row.district) {
      // The same key again. Decrementing the raw name created a NEGATIVE total
      // under a key that had never been written.
      update[`massMgByDistrict.${eprPeriod.sanitizeMapKey(row.district)}`] =
        increment(-intOr0(row.massMg));
    }
    if (row.massMgByPolymer && typeof row.massMgByPolymer === 'object') {
      for (const [polymer, mg] of Object.entries(row.massMgByPolymer)) {
        update[`massMgByPolymer.${polymer}`] = increment(-intOr0(mg));
      }
    }
    if (row.confidenceTier === 'medium') {
      update.uncertainMassMg = increment(-intOr0(row.massMg));
    }

    txn.set(periodRef, update, { merge: true });

    // `skuIds` is deliberately NOT touched.
    //
    // Whether this product still belongs in the period's distinct set depends
    // on whether any other row for it survives, and one row cannot answer that.
    // `arrayRemove` would drop a product that is still attributed elsewhere in
    // the period; leaving it keeps a product that may no longer be. The second
    // error is the smaller one — it overstates variety, never mass — and a
    // recompute corrects it exactly. The reconciliation console is where that
    // is surfaced (EPR-48).
    txn.update(attributionRef, {
      reversedBy: adminUid,
      reversedAt: serverTimestamp(),
      reversedReason: reason.trim().slice(0, 500),
    });

    return {
      attributionId,
      orgId: row.orgId,
      periodId: row.periodId,
      massMg: intOr0(row.massMg),
    };
  });
}

/**
 * The fields a producer may see on its own period, and nothing else (SEC-3).
 *
 * AN EXPLICIT ALLOWLIST, NOT A DELETION LIST.
 *
 * `listPeriods` used to return the stored document verbatim — `{...d.data()}` —
 * which shipped two things a producer must never receive:
 *
 *   `lastAttributionAt`, a server timestamp at second precision. On a period
 *   with one disposal that is the exact moment one identifiable person threw
 *   something into a named district. The period is the resolution a producer
 *   reports at; an instant is never needed and cannot be un-disclosed.
 *
 *   `recomputedBy`, the Firebase uid of the Chokro employee who ran the
 *   reconciliation. The producer legitimately needs to know *whether* the
 *   period reconciled; it has no business knowing which member of staff
 *   touched its figures, and a staff identifier is a target.
 *
 * A deletion list would have missed both again the next time a field was added
 * to the rollup. An allowlist fails the other way: a new field is invisible to
 * producers until somebody decides it should not be.
 *
 * THE k FLOOR APPLIES TO GEOGRAPHY, AND ONLY TO GEOGRAPHY.
 *
 * SEC-3 names "a single bin, a single day" as the shape that isolates an
 * individual, and district is the identifying dimension here. Category and
 * polymer are properties of the *packaging* — knowing that 21 g of rigid PET
 * was collected tells you about a bottle, not about a person — so they survive
 * the floor. The total survives too: it is the figure the producer is certified
 * on, and suppressing it would make the workspace useless rather than private.
 *
 * Suppression is STATED, never silent. `districtSuppressed` and the floor
 * travel with the response so the screen can say why the breakdown is missing
 * — a quietly absent district list reads as "no geography recorded", which is a
 * different and false claim.
 */
function projectForProducer(period, policy) {
  if (!period) return null;

  const floor = policy?.kAnonymityFloor ?? 5;
  const disposalCount = intOr0(period.disposalCount);
  const suppressDistricts = disposalCount > 0 && disposalCount < floor;

  return {
    orgId: period.orgId,
    periodId: period.periodId,

    massMgByCategory: period.massMgByCategory ?? {},
    unitsByCategory: period.unitsByCategory ?? {},
    massMgByPolymer: period.massMgByPolymer ?? {},
    // Withheld entirely rather than partially: a "top districts" list with the
    // thin ones removed still discloses that the remaining ones are thicker,
    // and on a small period that is most of the information.
    massMgByDistrict: suppressDistricts ? {} : (period.massMgByDistrict ?? {}),
    districtSuppressed: suppressDistricts,
    kAnonymityFloor: floor,

    attributionCount: intOr0(period.attributionCount),
    disposalCount,
    skuIds: Array.isArray(period.skuIds) ? period.skuIds : [],
    uncertainMassMg: intOr0(period.uncertainMassMg),
    unattributedDisposalCount: intOr0(period.unattributedDisposalCount),
    reversedCount: intOr0(period.reversedCount),
    reversedMassMg: intOr0(period.reversedMassMg),

    // The reconciliation *result*, without the person who ran it. A producer is
    // entitled to know whether its figures reconciled and by how much they did
    // not (EPR-22); it is not entitled to the operator.
    recomputedAt: period.recomputedAt ?? null,
    recomputeMatched:
      typeof period.recomputeMatched === 'boolean'
        ? period.recomputeMatched
        : null,
    recomputeVariance: Number.isInteger(period.recomputeVariance)
      ? period.recomputeVariance
      : null,
    recomputedMassMg: Number.isInteger(period.recomputedMassMg)
      ? period.recomputedMassMg
      : null,

    // Deliberately absent: lastAttributionAt, recomputedBy, recomputedBy's
    // timestamps, and anything else the rollup gains later.
  };
}

/** One organisation's periods, newest first. Bounded (QA-10). */
async function listPeriods({ orgId, limit = 24 }) {
  const snap = await db()
    .collection(PERIODS)
    .where('orgId', '==', orgId)
    .orderBy('periodId', 'desc')
    .limit(limit)
    .get();

  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

async function getPeriod({ orgId, periodId }) {
  const snap = await db()
    .collection(PERIODS)
    .doc(eprPeriod.eprPeriodDocumentId(orgId, periodId))
    .get();

  return snap.exists ? { id: snap.id, ...snap.data() } : null;
}

function badRequest(message) {
  const error = new Error(message);
  error.code = 'bad_request';
  return error;
}

module.exports = {
  RECOMPUTE_BATCH,
  emptyTotals,
  accumulate,
  sumMap,
  intOr0,
  recomputePeriod,
  storeRecomputeResult,
  reverseAttribution,
  projectForProducer,
  listPeriods,
  getPeriod,
};
