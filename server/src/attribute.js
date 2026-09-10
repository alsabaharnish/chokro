/**
 * Chokro — recognition to attribution to rollup (EPR-17 to EPR-23, EPR-27).
 *
 * ===========================================================================
 * THE TWO RULES THIS MODULE IS BUILT AROUND
 * ===========================================================================
 *
 * 1. ATTRIBUTION NEVER AFFECTS A DISPOSAL OUTCOME.
 *
 * This runs AFTER the decision has committed, in its own transaction, and every
 * failure is swallowed and logged. `award.js` already establishes the pattern
 * and the reason for the push notification: "AFTER the commit, never inside it.
 * Firestore retries a transaction body on contention, so a send inside one
 * fires once per attempt."
 *
 * The same reasoning applies with more force here. If attribution shared the
 * decision transaction, a registry read failing or a mass being unverifiable
 * would roll back a Champion's points — a payout undone because a producer's
 * paperwork was incomplete. EPR-16's sentence is that a screening outage must
 * degrade attribution, not disposal, and this is where that is enforced.
 *
 * 2. ATTRIBUTION NEVER AFFECTS POINTS.
 *
 * EPR-27, and §6.8 asks the architect to read it twice. Nothing in this file
 * touches a wallet, a ledger entry, `dailyCaps`, `lockouts`, or the disposal's
 * `pointsAwarded`. `decide.js` is not imported and is not consulted.
 *
 * The reason is worth restating: coupling the reward economy to the compliance
 * economy would turn the recognition model into a payout oracle, so every
 * weakness in brand recognition becomes a way to mint points — print a
 * wordmark, photograph it, repeat. It would also give Champions an incentive to
 * misstate what they are disposing of, polluting the very dataset a regulator
 * will audit. `server/test/attributePointsIsolation.test.js` pins this.
 *
 * ===========================================================================
 * WHY THERE IS NO SECOND MODEL CALL
 * ===========================================================================
 *
 * The recognition question is asked as part of the screening call that already
 * happens during verification (EPR-15, NFR-E-7), and the answer is stored on
 * the disposal as server-only evidence. This module reads that stored answer.
 *
 * That ordering also makes manual approval work for free: a disposal routed to
 * review already carries its recognition evidence, so an Admin pressing approve
 * three days later attributes against what was screened at the time rather than
 * re-screening a photograph of a bin that has since been emptied.
 */

const crypto = require('crypto');
const { db, admin, serverTimestamp } = require('./firebase');
const eprPolicy = require('./eprPolicy');
const eprPeriod = require('./eprPeriod');
const producerSkus = require('./producerSkus');
const skuShortlist = require('./skuShortlist');

const ATTRIBUTIONS = 'attributions';
const PERIODS = 'eprPeriods';
const DISPOSALS = 'disposals';
const BIN_FREQUENCY = 'binSkuFrequency';
const CONFIRMATION_QUEUE = 'attributionConfirmations';

/** The disposal states attribution may act on (EPR-21). */
const TERMINAL_APPROVED = Object.freeze(['autoApproved', 'manualApproved']);

/**
 * Whether attribution runs at all.
 *
 * A flag, because the specification's own sequencing note asks for one: "Phase
 * C is the only phase that touches the existing disposal decision path, which
 * is the most safety-critical and most-tested code in the repository. It should
 * be built behind a flag, with attribution failure proven never to affect a
 * disposal outcome."
 *
 * Off means the disposal path behaves exactly as it did before this phase.
 */
function isEnabled() {
  return process.env.EPR_ATTRIBUTION_ENABLED === 'true';
}

/**
 * Which tier a confidence falls in (EPR-17).
 *
 * Pure, so the thresholds can be tested at their boundaries without a database.
 * Fails closed: anything unreadable is `low`, and `low` attributes nothing.
 */
function tierFor(confidence, policy) {
  if (typeof confidence !== 'number' || !Number.isFinite(confidence)) {
    return 'low';
  }
  if (confidence >= policy.highConfidenceThreshold) return 'high';
  if (confidence >= policy.lowConfidenceThreshold) return 'medium';
  return 'low';
}

/**
 * The per-unit polymer split for a revision, scaled to `units`.
 *
 * Integer arithmetic throughout (EPR-20). Returns an empty map when the
 * revision declared no components — deliberately empty rather than assigning
 * the whole mass to the dominant polymer, because that would be a guess and
 * §6.7 forbids a figure whose provenance cannot be traced field by field.
 *
 * The component masses are the *declared* ones and the unit mass is the
 * *verified* one, so the two need not sum identically. The split is therefore
 * applied as a proportion of the verified mass rather than by adding component
 * masses directly — otherwise a product verified 2% light would report polymer
 * lines that add up to more than its own total.
 */
function polymerSplitFor({ revision, units, massMg }) {
  const components = Array.isArray(revision.components) ? revision.components : [];
  if (components.length === 0) return {};

  const declaredTotal = components.reduce(
    (sum, c) => sum + (Number.isInteger(c.massMg) ? c.massMg : 0),
    0,
  );
  if (declaredTotal <= 0) return {};

  const split = {};
  let assigned = 0;
  let heaviest = null;

  for (const component of components) {
    if (!Number.isInteger(component.massMg) || component.massMg <= 0) continue;
    if (typeof component.polymer !== 'string') continue;

    // Proportional, floored, on integers.
    const share = Math.floor((massMg * component.massMg) / declaredTotal);
    split[component.polymer] = (split[component.polymer] || 0) + share;
    assigned += share;

    if (!heaviest || component.massMg > heaviest.massMg) heaviest = component;
  }

  // Flooring loses up to one milligram per component. The remainder goes to the
  // heaviest part, so the polymer lines sum EXACTLY to the attributed mass.
  // Two figures in one report that do not add up is precisely what a regulator
  // notices, and "rounding" is not an answer when both are integers.
  const remainder = massMg - assigned;
  if (remainder > 0 && heaviest) {
    split[heaviest.polymer] = (split[heaviest.polymer] || 0) + remainder;
  }

  return split;
}

/**
 * Attributes one approved disposal.
 *
 * NEVER THROWS. Returns a summary describing what happened, including the
 * reasons it did nothing. The caller is the disposal decision path, and its
 * only correct response to any of these outcomes is to carry on.
 *
 * @param {object} args
 * @param {string} args.disposalId
 * @param {string|null} args.actorUid  the Admin, for a manual attribution
 * @returns {Promise<object>} `{ outcome, ... }`
 */
async function attributeDisposal({ disposalId, actorUid = null }) {
  if (!isEnabled()) return { outcome: 'disabled' };

  try {
    const firestore = db();
    const disposalRef = firestore.collection(DISPOSALS).doc(disposalId);
    const disposalSnap = await disposalRef.get();

    if (!disposalSnap.exists) return { outcome: 'noSuchDisposal' };
    const disposal = disposalSnap.data();

    // EPR-21: only a terminal approved state attributes. A rejected disposal
    // never attributes; an appeal that overturns a rejection re-enters here on
    // approval, because the appeal path calls `approveDisposal` like everything
    // else.
    if (!TERMINAL_APPROVED.includes(disposal.status)) {
      return { outcome: 'notApproved', status: disposal.status };
    }

    // Idempotence on disposalId, in the manner of the existing award path.
    // Two Admins pressing approve, a retry after a timeout, or a backfill
    // sweeping the same document must not attribute twice.
    if (
      disposal.attributionStatus === 'attributed' ||
      disposal.attributionStatus === 'unattributable'
    ) {
      return { outcome: 'alreadyAttributed' };
    }

    const policy = await eprPolicy.readPolicy();

    // The decision timestamp, from the server's clock, is what fixes both the
    // period and which mass revision applies (EPR-23, EPR-12). `reviewedAt`
    // for a manual approval; `verifiedAt`/`createdAt` for an automatic one.
    const decidedAt =
      disposal.reviewedAt?.toDate?.() ??
      disposal.verifiedAt?.toDate?.() ??
      disposal.createdAt?.toDate?.() ??
      null;

    if (!decidedAt) {
      // Without a decision time there is no period and no revision, so there is
      // no defensible figure. Left pending rather than guessed.
      return { outcome: 'noDecisionTime' };
    }

    const periodId = eprPeriod.periodIdFor(decidedAt);
    if (!periodId) return { outcome: 'noPeriod' };

    // Recognition evidence, stored at screening time. Null and empty are
    // different facts — see `parseSkuMatches` in screen.js.
    const rawMatches = disposal.skuMatches;

    // The barcode path is tried first and wins outright (EPR-18). Where a
    // Champion scanned, accuracy stops being probabilistic, so there is no
    // reason to prefer a model's opinion over a read barcode.
    const barcodeMatch = await resolveBarcodeMatch(disposal);

    let candidates;
    if (barcodeMatch) {
      candidates = [barcodeMatch];
    } else if (Array.isArray(rawMatches)) {
      candidates = rawMatches.map((m) => ({
        skuId: m.skuId,
        units: m.units,
        confidence: m.confidence,
        method: 'aiSku',
      }));
    } else {
      // Recognition did not run, or could not be read. NOT unattributable:
      // that would count this disposal into the reported unattributed pool as
      // though it had been checked and found empty. Left pending so a backfill
      // can attribute it once recognition is available again (EPR-16, EPR-19).
      return { outcome: 'recognitionUnavailable' };
    }

    const bin = await readBin(disposal.binId);

    const resolved = [];
    const deferred = [];

    for (const candidate of candidates) {
      const tier =
        candidate.method === 'barcode'
          ? 'high'
          : tierFor(candidate.confidence, policy);

      if (tier === 'low') {
        // EPR-17: not attributed, queued for human confirmation. Recorded
        // rather than discarded, because a low-confidence match is the most
        // likely place a real attribution is being missed.
        deferred.push({ ...candidate, tier });
        continue;
      }

      // The mass that applied on the day of the disposal, not today's.
      const revision = await producerSkus.revisionActiveAt({
        skuId: candidate.skuId,
        moment: decidedAt,
      });

      if (!revision) {
        // Recognised, but Chokro had no verified mass for it at that moment.
        // Not an error and not a mass: a defensible kilogram needs a verified
        // figure that was in force at the time (EPR-11, EPR-12).
        deferred.push({ ...candidate, tier, reason: 'noVerifiedMassAtTheTime' });
        continue;
      }

      const unitMassMgUsed = revision.verifiedUnitMassMg;
      const massMg = candidate.units * unitMassMgUsed;

      // Bounds, on the product rather than on the inputs. Each input was
      // already bounded, and this catches the case where their product is not
      // a plausible mass for one photograph of one bin.
      if (!Number.isInteger(massMg) || massMg <= 0 || massMg > 500 * 1000000) {
        deferred.push({ ...candidate, tier, reason: 'implausibleMass' });
        continue;
      }

      resolved.push({
        ...candidate,
        tier,
        revision,
        unitMassMgUsed,
        massMg,
        polymerSplit: polymerSplitFor({
          revision,
          units: candidate.units,
          massMg,
        }),
      });
    }

    if (resolved.length === 0) {
      // Checked, and nothing usable. THIS is `unattributable`, and it counts
      // into the visible unattributed pool reported as its own line (EPR-19).
      // Mass is never invented for it.
      await markUnattributable({
        disposalRef,
        disposal,
        periodId,
        deferred,
        actorUid,
      });

      // Queued HERE too, not only on the attributed path.
      //
      // This branch is where human confirmation matters most: nothing was
      // attributed, so a deferred low-confidence match is the only remaining
      // chance of a real attribution. An earlier version returned before
      // queueing and reported a `deferredCount` with nothing behind it —
      // EPR-17's "queued for human confirmation" satisfied on paper and
      // nowhere else.
      await queueForConfirmation({ disposalId, deferred, periodId });

      return {
        outcome: 'unattributable',
        periodId,
        deferredCount: deferred.length,
      };
    }

    const written = await commitAttributions({
      disposalRef,
      disposalId,
      disposal,
      decidedAt,
      periodId,
      bin,
      resolved,
      policy,
    });

    // Queued after the commit, for the same reason the push hook is: these are
    // secondary records and a failure in one must not undo an attribution.
    await queueForConfirmation({ disposalId, deferred, periodId });
    await recordAccuracySample({ disposalId, resolved, policy });
    await bumpBinFrequency({ binId: disposal.binId, resolved });

    return {
      outcome: 'attributed',
      periodId,
      attributions: written.length,
      totalMassMg: written.reduce((sum, a) => sum + a.massMg, 0),
      deferredCount: deferred.length,
    };
  } catch (err) {
    // The whole point of this catch. A disposal has already been approved and
    // credited by the time this runs; nothing here may undo that, and nothing
    // here may surface as a failed submission to the person who made it.
    //
    // The disposal keeps `attributionStatus: 'pending'`, which is what a
    // backfill looks for.
    console.error(`[attribute] ${disposalId} failed:`, err.message);
    return { outcome: 'failed', error: err.message };
  }
}

/**
 * Writes the attributions and increments the rollup, in one transaction
 * (EPR-22).
 *
 * One transaction for both, because a rollup that can disagree with its own
 * source is a figure nobody can defend — and the recompute job exists to
 * detect exactly that drift, so it must not be created here on purpose.
 */
async function commitAttributions({
  disposalRef,
  disposalId,
  disposal,
  decidedAt,
  periodId,
  bin,
  resolved,
  policy,
}) {
  const firestore = db();
  const increment = admin.firestore.FieldValue.increment;

  return firestore.runTransaction(async (txn) => {
    // Re-read inside the transaction. Between the read at the top of
    // `attributeDisposal` and here, another request may have attributed this
    // disposal — the idempotence check has to happen where it can win.
    const fresh = await txn.get(disposalRef);
    if (!fresh.exists) throw new Error('That disposal no longer exists.');

    const current = fresh.data();
    if (
      current.attributionStatus === 'attributed' ||
      current.attributionStatus === 'unattributable'
    ) {
      // Not an error. Another writer got there first, and its result stands.
      return [];
    }

    const written = [];
    const byOrg = new Map();

    for (const match of resolved) {
      const orgId = match.revision.orgId;
      const attributionRef = firestore.collection(ATTRIBUTIONS).doc();

      const row = {
        disposalId,
        orgId,
        skuId: match.skuId,
        skuRevision: match.revision.revision,
        binId: disposal.binId || '',
        district: bin?.district || '',
        city: bin?.city || '',
        gazetteCategory: match.revision.gazetteCategory || '',
        polymer: match.revision.polymer || '',
        units: match.units,
        // Stored, not referenced. Reading the product later would give
        // whatever it weighs then (EPR-12).
        unitMassMgUsed: match.unitMassMgUsed,
        massMg: match.massMg,
        massMgByPolymer: match.polymerSplit,
        method: match.method,
        confidence: typeof match.confidence === 'number' ? match.confidence : null,
        confidenceTier: match.tier,
        periodId,
        disposalDecidedAt: admin.firestore.Timestamp.fromDate(decidedAt),
        createdAt: serverTimestamp(),
        reversedBy: null,
        reversedAt: null,
        reversedReason: null,
      };

      txn.set(attributionRef, row);
      written.push({ id: attributionRef.id, ...row });

      if (!byOrg.has(orgId)) byOrg.set(orgId, []);
      byOrg.get(orgId).push(match);
    }

    // One rollup document per organisation touched. A single photograph can
    // contain two producers' packaging, and each gets its own period totals.
    for (const [orgId, matches] of byOrg) {
      const periodRef = firestore
        .collection(PERIODS)
        .doc(eprPeriod.eprPeriodDocumentId(orgId, periodId));

      const update = {
        orgId,
        periodId,
        attributionCount: increment(matches.length),
        // DISTINCT products, as a set rather than a counter.
        //
        // `uniqueSkuCount` was declared on the model, recomputed by the
        // reconciliation, and never incremented anywhere — so it read 0 for
        // every period, and a passport would have stated "0 distinct products"
        // beside a real mass.
        //
        // A counter cannot fix it: `increment(1)` on every attribution counts
        // rows, not products, and there is no way to ask "have I seen this
        // skuId before" from inside an increment. `arrayUnion` adds only what
        // is absent, so it is exactly a set — and idempotent, which matters
        // because attribution can be retried.
        //
        // The count is derived from the array's length rather than stored
        // alongside it, so the two cannot drift.
        skuIds: admin.firestore.FieldValue.arrayUnion(
          ...matches.map((m) => m.skuId),
        ),
        // One per disposal per organisation, however many products of theirs
        // were in the photograph — otherwise "distinct disposal events" on a
        // passport would overcount.
        disposalCount: increment(1),
        lastAttributionAt: serverTimestamp(),
      };

      for (const match of matches) {
        const category = match.revision.gazetteCategory;
        if (category) {
          update[`massMgByCategory.${category}`] = increment(match.massMg);
          update[`unitsByCategory.${category}`] = increment(match.units);
        }

        const district = bin?.district;
        if (district) {
          update[`massMgByDistrict.${sanitizeKey(district)}`] = increment(
            match.massMg,
          );
        }

        for (const [polymer, mg] of Object.entries(match.polymerSplit)) {
          update[`massMgByPolymer.${polymer}`] = increment(mg);
        }

        // EPR-17/EPR-37: a producer that cannot see how much of its number is
        // uncertain will publish the number as if it were certain.
        if (match.tier === 'medium') {
          update.uncertainMassMg = increment(match.massMg);
        }
      }

      txn.set(periodRef, update, { merge: true });
    }

    // EPR-6: server-only fields on the disposal, and nothing else. The client
    // create allowlist in firestore.rules does not grow by a single key.
    txn.update(disposalRef, {
      attributionStatus: 'attributed',
      skuMatchCount: written.length,
      attributedMassGrams: written.reduce((sum, a) => sum + a.massMg, 0),
      gazetteCategoryResolved: written[0]?.gazetteCategory || null,
      attributedAt: serverTimestamp(),
      attributionPeriodId: periodId,
      // Deliberately absent: pointsAwarded, and every wallet or ledger field.
      // See EPR-27 at the top of this file.
    });

    return written;
  });
}

/**
 * Records that a disposal was checked and yielded nothing (EPR-19).
 *
 * The unattributed pool is reported as its own line, so the count has to exist.
 * An absent count would render as an empty pool, which is a claim that
 * everything was attributed.
 */
async function markUnattributable({
  disposalRef,
  disposal,
  periodId,
  deferred,
  actorUid,
}) {
  const firestore = db();

  await firestore.runTransaction(async (txn) => {
    const fresh = await txn.get(disposalRef);
    if (!fresh.exists) return;

    const current = fresh.data();
    if (
      current.attributionStatus === 'attributed' ||
      current.attributionStatus === 'unattributable'
    ) {
      return;
    }

    txn.update(disposalRef, {
      attributionStatus: 'unattributable',
      skuMatchCount: 0,
      attributedMassGrams: 0,
      gazetteCategoryResolved: null,
      attributedAt: serverTimestamp(),
      attributionPeriodId: periodId,
      attributionDeferredCount: deferred.length,
    });
  });

  // The pool is counted per period, and it is NOT counted per organisation:
  // an unrecognised item belongs to nobody by definition, so attributing its
  // absence to a producer would be inventing the very thing EPR-19 forbids.
  await firestore
    .collection(PERIODS)
    .doc(eprPeriod.eprPeriodDocumentId('__platform', periodId))
    .set(
      {
        orgId: '__platform',
        periodId,
        unattributedDisposalCount: admin.firestore.FieldValue.increment(1),
        lastAttributionAt: serverTimestamp(),
      },
      { merge: true },
    );
}

/**
 * Resolves a scanned GTIN into a match (EPR-18).
 *
 * NFR-E-6: the barcode must not make the disposal flow require another live
 * round trip — "a disposal that fails at the bin because a barcode lookup timed
 * out is a worse product than no barcode path at all". So the client stores the
 * scanned digits with the submission and the resolution happens here, later,
 * server-side.
 */
async function resolveBarcodeMatch(disposal) {
  const gtin = disposal.scannedGtin;
  if (typeof gtin !== 'string' || gtin.length === 0) return null;

  const sku = await skuShortlist.resolveGtin(gtin);
  if (!sku) return null;

  // The declared count, because a scan identifies the product and the person
  // states the quantity. Bounded to what a single submission can plausibly be.
  const units = Number.isInteger(disposal.declaredItemCount)
    ? disposal.declaredItemCount
    : 1;
  if (units < 1 || units > 100) return null;

  return {
    skuId: sku.skuId,
    units,
    // Null, honestly. A read barcode is not a probabilistic judgement, and
    // storing 1.0 would put a fabricated certainty into the accuracy statistics
    // that EPR-17 requires be published.
    confidence: null,
    method: 'barcode',
  };
}

/** Low-confidence and unresolvable matches, for a person to confirm (EPR-17). */
async function queueForConfirmation({ disposalId, deferred, periodId }) {
  if (deferred.length === 0) return;

  try {
    const firestore = db();
    const batch = firestore.batch();

    for (const match of deferred) {
      batch.set(
        firestore.collection(CONFIRMATION_QUEUE).doc(`${disposalId}_${match.skuId}`),
        {
          disposalId,
          skuId: match.skuId,
          units: match.units,
          confidence: typeof match.confidence === 'number' ? match.confidence : null,
          confidenceTier: match.tier,
          reason: match.reason || 'lowConfidence',
          periodId,
          status: 'pending',
          createdAt: serverTimestamp(),
        },
      );
    }

    await batch.commit();
  } catch (err) {
    // A queue write failing must not undo an attribution that already
    // committed. The match is lost from the queue, not from the evidence.
    console.error(`[attribute] confirmation queue for ${disposalId}:`, err.message);
  }
}

/**
 * Samples high-confidence matches for human review regardless (EPR-17).
 *
 * "A recognition system whose accuracy is unmeasured cannot support a
 * regulatory claim, and the DoE's data verification power means someone will
 * eventually ask." The measured precision is published in every report's
 * methodology section, which is only possible if something is measuring it.
 *
 * Sampled deterministically from the disposal id rather than randomly, so the
 * same disposal is always either in the sample or out of it. A random draw
 * would make a re-run of a backfill sample a different set, and the resulting
 * accuracy figure would depend on how many times the backfill had run.
 */
async function recordAccuracySample({ disposalId, resolved, policy }) {
  const fraction = policy.accuracyAuditSampleFraction;
  if (!(fraction > 0)) return;

  const highConfidence = resolved.filter((m) => m.tier === 'high');
  if (highConfidence.length === 0) return;

  if (!isSampled(disposalId, fraction)) return;

  try {
    const firestore = db();
    const batch = firestore.batch();

    for (const match of highConfidence) {
      batch.set(
        firestore.collection(CONFIRMATION_QUEUE).doc(`${disposalId}_${match.skuId}`),
        {
          disposalId,
          skuId: match.skuId,
          units: match.units,
          confidence: typeof match.confidence === 'number' ? match.confidence : null,
          confidenceTier: match.tier,
          // A different reason from a low-confidence queue entry, because the
          // two answer different questions. This one measures whether the
          // model was right when it was confident; the other decides whether
          // an uncertain match becomes a figure at all.
          reason: 'accuracyAudit',
          status: 'pending',
          createdAt: serverTimestamp(),
        },
      );
    }

    await batch.commit();
  } catch (err) {
    console.error(`[attribute] accuracy sample for ${disposalId}:`, err.message);
  }
}

/**
 * Whether a disposal is in the accuracy sample.
 *
 * SHA-256 of the id, and the first four bytes read as a fraction.
 *
 * A cheap polynomial hash was not good enough here, and the way it failed is
 * worth recording. `hash = hash * 31 + charCode` maps a family of ids sharing a
 * long prefix — `disposal_0` through `disposal_3999` — into a narrow contiguous
 * band, so a threshold comparison selects either all of them or none. Across
 * four thousand sequential ids it sampled zero at a 2% fraction. Firestore's
 * real auto-ids are random, which would have hidden that in production and
 * left the published accuracy figure resting on a sample of whatever ids
 * happened to fall in the band.
 *
 * A cryptographic digest is uniform over any input family, which is the only
 * property this needs. It is deterministic, so the same disposal always lands
 * the same way — a random draw would make the measured accuracy depend on how
 * many times a backfill had run.
 */
function isSampled(disposalId, fraction) {
  if (!(fraction > 0)) return false;
  if (fraction >= 1) return true;

  const digest = crypto.createHash('sha256').update(String(disposalId)).digest();
  // The first four bytes as an unsigned integer, divided by 2^32.
  return digest.readUInt32BE(0) / 0x100000000 < fraction;
}

/** Keeps the shortlist's local-history signal current (EPR-15). */
async function bumpBinFrequency({ binId, resolved }) {
  if (!binId) return;

  try {
    const increment = admin.firestore.FieldValue.increment;
    const update = { binId };
    for (const match of resolved) {
      update[`counts.${match.skuId}`] = increment(1);
    }

    await db().collection(BIN_FREQUENCY).doc(binId).set(update, { merge: true });
  } catch (err) {
    // A ranking signal, not evidence. Losing an increment costs a little
    // accuracy on a future shortlist and nothing else.
    console.error(`[attribute] bin frequency for ${binId}:`, err.message);
  }
}

async function readBin(binId) {
  if (!binId) return null;
  try {
    const snap = await db().collection('bins').doc(binId).get();
    return snap.exists ? snap.data() : null;
  } catch (err) {
    // A missing district costs a geographic breakdown line, not an attribution.
    console.error(`[attribute] bin read for ${binId}:`, err.message);
    return null;
  }
}

/**
 * Makes a district safe as a Firestore map key.
 *
 * DELEGATED, NOT DUPLICATED. This module, the recompute and the reversal all
 * key the same map, and when only this one sanitised, a reversal decremented a
 * key that had never been written — a negative district total in a compliance
 * rollup — while every recompute reported a mismatch that was two spellings
 * rather than a discrepancy. See `sanitizeMapKey` in `eprPeriod.js`.
 */
const sanitizeKey = eprPeriod.sanitizeMapKey;

module.exports = {
  ATTRIBUTIONS,
  PERIODS,
  CONFIRMATION_QUEUE,
  TERMINAL_APPROVED,
  isEnabled,
  tierFor,
  polymerSplitFor,
  isSampled,
  sanitizeKey,
  attributeDisposal,
};
