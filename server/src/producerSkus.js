/**
 * Chokro — the product registry and the verified-mass chain
 * (EPR-9 to EPR-14, §6.1, §6.2).
 *
 * THE INTEGRITY CRUX OF THE WHOLE SYSTEM
 * The producer declares the number that multiplies into every kilogram Chokro
 * will ever report on its behalf. Its incentives are not neutral: overstating a
 * unit mass inflates collected kilograms — the numerator — and inflates any
 * plastic credit; understating put-on-market shrinks the denominator, with the
 * same effect. Both are "false information" within the meaning of the gazette's
 * enforcement clause, which puts Chokro in the middle of a legal exposure if
 * its certificates simply repeat what a producer typed.
 *
 * So a declared mass is never used for reporting (EPR-11). Only
 * `verifiedUnitMassMg` is, and it is set here, by this service, through one of
 * three routes: physical sampling, documentary verification, or an Admin
 * override with a stated reason. All three are logged and all three write a
 * revision.
 *
 * AND A VERIFIED MASS IS NEVER EDITED IN PLACE (EPR-12)
 * A change closes the standing revision with an `activeTo` and opens the next
 * with an `activeFrom`. Every attribution stores the revision and the unit mass
 * it actually used. This is what keeps last quarter's passport true after this
 * quarter's re-weighing — and it is the difference between a reproducible
 * report and one that quietly rewrites history.
 *
 * MASS IS INTEGER MILLIGRAMS EVERYWHERE (EPR-20). No float enters the chain.
 */

const { db, admin, serverTimestamp } = require('./firebase');
const audit = require('./producerAudit');
const eprPolicy = require('./eprPolicy');

const SKUS = 'producerSkus';
const REVISIONS = 'skuRevisions';
const AUDITS = 'skuMassAudits';

const MASS_STATUSES = Object.freeze([
  'draft',
  'submitted',
  'verified',
  'rejected',
  'superseded',
]);
const SKU_STATUSES = Object.freeze(['draft', 'submitted', 'active', 'retired']);
const GAZETTE_CATEGORIES = Object.freeze([
  'rigid',
  'flexible',
  'eps',
  'singleUse',
  'other',
]);
const POLYMERS = Object.freeze([
  'pet',
  'hdpe',
  'pvc',
  'ldpe',
  'pp',
  'ps',
  'multilayer',
  'other',
]);
const REVISION_REASONS = Object.freeze([
  'initialVerification',
  'reweighed',
  'declarationChanged',
  'adminOverride',
  'documentary',
]);

/** Mirrors `mass_math.dart`. The two must agree, and both are tested. */
const MIN_UNIT_MASS_MG = 100;
const MAX_UNIT_MASS_MG = 5000000;

/**
 * The floor for a single component, as opposed to a whole unit.
 *
 * One milligram. Mirrors `minComponentMassMg` in `mass_math.dart` — a tamper
 * ring or a foil seal legitimately weighs 0.05 g, and applying the unit floor
 * to each part made such a product unregisterable. The unit floor exists
 * because a whole unit below 0.1 g could not be verified by physical sampling;
 * parts are not weighed individually, they are declared, and the figure the
 * scale checks is their sum.
 */
const MIN_COMPONENT_MASS_MG = 1;
const MG_PER_GRAM = 1000;

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

/**
 * A strictly numeric string, matching what Dart's `double.tryParse` accepts.
 *
 * WHY THIS EXISTS RATHER THAN `parseFloat`
 *
 * `Number.parseFloat` *prefix-parses*: it reads as far as it can and returns
 * what it got, discarding the rest. Dart's `double.tryParse` returns null
 * unless the whole string is a number. That difference is not cosmetic here —
 * the server is the authority on a declared mass, and the two copies of this
 * function disagreed on inputs a real client sends:
 *
 *   '1,250'  parseFloat -> 1      (1 g stored against a 1250 g declaration)
 *   '8.2g'   parseFloat -> 8.2    (accepted silently)
 *   '8.2.5'  parseFloat -> 8.2    (accepted silently)
 *
 * The first is the dangerous one. A thousands separator is exactly what a
 * spreadsheet export or a hand-typed figure carries, and a 1250x understatement
 * of a unit mass becomes the baseline that every later verification and every
 * attributed kilogram is measured against — with nothing about the stored
 * document that looks wrong.
 *
 * Hex is excluded for the same parity reason: `Number('0x10')` is 16 while Dart
 * rejects it.
 */
const STRICT_NUMBER = /^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$/;

/**
 * Parses a declared gram figure into integer milligrams.
 *
 * The server's copy of `milligramsFromGrams`. Duplicated across the language
 * boundary rather than shared, because there is no shared runtime — and both
 * copies are tested against the same worked example so a divergence shows up as
 * a failing test rather than as a disagreeing kilogram.
 */
function milligramsFromGrams(grams) {
  let value;

  if (typeof grams === 'number') {
    value = grams;
  } else if (typeof grams === 'string') {
    // STRICT, not `parseFloat`. See STRICT_NUMBER above.
    const trimmed = grams.trim();
    value = STRICT_NUMBER.test(trimmed) ? Number(trimmed) : NaN;
  } else {
    value = NaN;
  }

  if (!Number.isFinite(value) || value <= 0) return null;

  const mg = Math.round(value * MG_PER_GRAM);
  if (mg < MIN_UNIT_MASS_MG || mg > MAX_UNIT_MASS_MG) return null;
  return mg;
}

/**
 * A component mass in milligrams, using the component floor.
 *
 * Same strict string parsing as [milligramsFromGrams] — see STRICT_NUMBER — and
 * a different lower bound.
 */
function componentMilligramsFromGrams(grams) {
  let value;

  if (typeof grams === 'number') {
    value = grams;
  } else if (typeof grams === 'string') {
    const trimmed = grams.trim();
    value = STRICT_NUMBER.test(trimmed) ? Number(trimmed) : NaN;
  } else {
    value = NaN;
  }

  if (!Number.isFinite(value) || value <= 0) return null;

  const mg = Math.round(value * MG_PER_GRAM);
  if (mg < MIN_COMPONENT_MASS_MG || mg > MAX_UNIT_MASS_MG) return null;
  return mg;
}

function normalizeComponents(raw) {
  if (!Array.isArray(raw)) return null;

  const components = [];
  for (const entry of raw) {
    if (!entry || typeof entry !== 'object') return null;

    const part = typeof entry.part === 'string' ? entry.part.trim() : '';
    const polymer = entry.polymer;
    // Not `milligramsFromGrams`: that applies the *unit* floor of 0.1 g, which
    // a legitimate 0.05 g tamper ring is below.
    const massMg = Number.isInteger(entry.massMg)
      ? entry.massMg
      : componentMilligramsFromGrams(entry.massGrams);

    if (part.length === 0 || part.length > 60) return null;
    if (!POLYMERS.includes(polymer)) return null;
    if (
      massMg === null ||
      massMg < MIN_COMPONENT_MASS_MG ||
      massMg > MAX_UNIT_MASS_MG
    ) {
      return null;
    }

    components.push({ part, polymer, massMg });
  }

  return components.length > 0 && components.length <= 12 ? components : null;
}

/**
 * Whether an edit changes what was physically weighed.
 *
 * Only the fields that describe the object on the scale count: its mass, its
 * parts, its polymer, its gazette category, its volume and its barcode. A typo
 * fix in the name or a new sample photograph does not invalidate a weighing,
 * and forcing a re-weigh for one would churn revisions for no integrity gain.
 *
 * Comparison is on integers and on a canonical component ordering, so a
 * reordered parts array is not mistaken for a changed product.
 */
function physicalDeclarationChanged(current, { declaredMg, components, draft }) {
  if (current.declaredUnitMassMg !== declaredMg) return true;
  if (current.gazetteCategory !== draft.gazetteCategory) return true;
  if (current.polymer !== draft.polymer) return true;

  const currentVolume = Number.isInteger(current.volumeMl) ? current.volumeMl : null;
  const nextVolume = Number.isInteger(draft.volumeMl) ? draft.volumeMl : null;
  if (currentVolume !== nextVolume) return true;

  if ((current.gtin || null) !== (draft.gtin || null)) return true;

  return canonicalComponents(current.components) !== canonicalComponents(components);
}

/** A stable string for a component list, order-independent. */
function canonicalComponents(components) {
  if (!Array.isArray(components)) return '';
  return components
    .map((c) => `${c.part}:${c.polymer}:${c.massMg}`)
    .sort()
    .join('|');
}

/**
 * Validates a client-proposed SKU draft.
 *
 * Returns every problem, not the first. Anything that fails here is refused
 * with a sentence rather than written and repaired later — a half-valid product
 * in the registry is a product whose mass verification will waste an Admin's
 * bench time.
 */
function validateSkuDraft(draft, { requireSubmittable = false } = {}) {
  const problems = [];
  const d = draft || {};

  if (typeof d.name !== 'string' || d.name.trim().length < 3) {
    problems.push('Give the product a name.');
  } else if (d.name.length > 140) {
    problems.push('The product name is too long.');
  }

  if (typeof d.brand !== 'string' || d.brand.trim().length < 2) {
    problems.push('Name the brand.');
  } else if (d.brand.length > 120) {
    problems.push('The brand name is too long.');
  }

  if (!GAZETTE_CATEGORIES.includes(d.gazetteCategory)) {
    problems.push('Choose a gazette category.');
  }
  if (!POLYMERS.includes(d.polymer)) {
    problems.push('Choose the main polymer.');
  }

  const declaredMg = Number.isInteger(d.declaredUnitMassMg)
    ? d.declaredUnitMassMg
    : milligramsFromGrams(d.declaredUnitMassG);

  if (
    declaredMg === null ||
    declaredMg < MIN_UNIT_MASS_MG ||
    declaredMg > MAX_UNIT_MASS_MG
  ) {
    problems.push(
      `The unit mass must be between ${MIN_UNIT_MASS_MG / MG_PER_GRAM} g and ` +
        `${MAX_UNIT_MASS_MG / MG_PER_GRAM} g.`,
    );
  }

  const components = normalizeComponents(d.components);
  if (components === null) {
    problems.push(
      'Break the product down into parts, each with a known polymer and a mass.',
    );
  } else if (declaredMg !== null) {
    const sum = components.reduce((total, c) => total + c.massMg, 0);
    if (sum !== declaredMg) {
      // Exact equality on integers. Both sides are figures the producer typed,
      // so a mismatch is an arithmetic error in the declaration — not the
      // measurement disagreement EPR-11's tolerance is for.
      // Exact division of integers by 1000, so a one-milligram discrepancy
      // reads as 10.001 g against 10 g rather than as two equal numbers.
      problems.push(
        `The parts add up to ${sum / MG_PER_GRAM} g but the unit mass is ` +
          `${declaredMg / MG_PER_GRAM} g — a difference of ` +
          `${Math.abs(sum - declaredMg) / MG_PER_GRAM} g.`,
      );
    }
  }

  if (d.gtin !== undefined && d.gtin !== null && d.gtin !== '') {
    if (typeof d.gtin !== 'string' || !/^\d{8,14}$/.test(d.gtin)) {
      problems.push('A GTIN is 8 to 14 digits.');
    }
  }

  const images = Array.isArray(d.sampleImageUrls) ? d.sampleImageUrls : [];
  if (requireSubmittable) {
    if (images.length < 2) {
      problems.push(
        'At least two sample photographs against a plain background are needed.',
      );
    }
    if (images.length > 6) {
      problems.push('Six sample photographs is the maximum.');
    }
  } else if (images.length > 6) {
    problems.push('Six sample photographs is the maximum.');
  }

  return { problems, declaredMg, components };
}

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

/**
 * Creates or replaces a draft SKU.
 *
 * The client-writable surface, and it stops at the declaration. Nothing here
 * can set `massStatus`, `verifiedUnitMassMg`, `revision` or the effective
 * dates: those are assembled from the stored document, not from the request.
 */
async function saveSkuDraft({
  skuId = null,
  orgId,
  draft,
  actorUid,
  actorName = '',
}) {
  const { problems, declaredMg, components } = validateSkuDraft(draft);
  if (problems.length > 0) {
    const error = new Error(problems.join(' '));
    error.problems = problems;
    error.code = 'invalid_sku';
    throw error;
  }

  const firestore = db();
  const ref = skuId
    ? firestore.collection(SKUS).doc(skuId)
    : firestore.collection(SKUS).doc();

  return firestore.runTransaction(async (txn) => {
    const existing = skuId ? await txn.get(ref) : null;

    /**
     * Set when this edit invalidates an existing verification. Assembled during
     * the read phase and applied during the write phase, because Firestore
     * requires every read to precede every write.
     */
    let invalidation = null;

    if (skuId) {
      if (!existing.exists) throw notFound();
      const current = existing.data();
      // Tenant check inside the transaction, on the stored document. The route
      // already resolved membership, and this is the second place that has to
      // agree — a skuId from another organisation must not be editable with
      // this session's authority (SEC-1).
      if (current.orgId !== orgId) throw notFound();

      if (current.massStatus === 'submitted') {
        throw conflict(
          'This product is with Chokro for verification. Wait for the decision, '
            + 'or ask for it to be returned.',
        );
      }
      if (current.status === 'retired') {
        throw conflict('A retired product cannot be edited.');
      }

      // EDITING WHAT WAS WEIGHED INVALIDATES THE WEIGHING.
      //
      // The hole this closes: a reporter registers a 500 ml bottle, Chokro
      // weighs it and verifies 19.5 g, and the reporter then edits the same
      // document into a bottle cap — new name, new GTIN, new components, new
      // declared mass — while `massStatus: 'verified'` and
      // `verifiedUnitMassMg: 19500` stay attached. The document is now a cap
      // carrying a bottle's verified mass, and every future attribution would
      // multiply recognised caps by 19.5 g. No Admin is involved at any point.
      //
      // `firestore.rules` refuses this from a client (the update branch requires
      // the stored `massStatus` to be draft or rejected), but this route runs on
      // the Admin SDK and bypasses rules by definition — which is precisely why
      // the check has to exist on both sides.
      //
      // Refusing the edit outright would be the wrong remedy: packaging really
      // does change, and `RevisionReason.declarationChanged` exists for exactly
      // this. So the edit is allowed and the verification is *invalidated* —
      // back to a draft, with the standing revision closed rather than deleted,
      // so reports already issued against it stay reproducible (EPR-12).
      if (
        current.massStatus === 'verified' &&
        physicalDeclarationChanged(current, { declaredMg, components, draft })
      ) {
        invalidation = {
          previousRevision: Number.isInteger(current.revision)
            ? current.revision
            : 0,
          previousVerifiedMassMg: current.verifiedUnitMassMg ?? null,
        };
      }
    }

    const record = {
      orgId,
      name: draft.name.trim(),
      brand: draft.brand.trim(),
      // Normalised for the brand-collision check EPR-14 makes blocking, the
      // same way `organizations` stores its own keys.
      brandKey: brandKey(draft.brand),
      gtin: draft.gtin || null,
      volumeMl: Number.isInteger(draft.volumeMl) ? draft.volumeMl : null,
      gazetteCategory: draft.gazetteCategory,
      polymer: draft.polymer,
      components,
      declaredUnitMassMg: declaredMg,
      // Kept alongside for a human reading the document in the console. The
      // milligram figure is authoritative and is what every computation uses.
      declaredUnitMassG: declaredMg / MG_PER_GRAM,
      sampleImageUrls: Array.isArray(draft.sampleImageUrls)
        ? draft.sampleImageUrls.slice(0, 6)
        : [],
      sampleImagePublicIds: Array.isArray(draft.sampleImagePublicIds)
        ? draft.sampleImagePublicIds.slice(0, 6)
        : [],
      recognitionHints: Array.isArray(draft.recognitionHints)
        ? draft.recognitionHints.filter((h) => typeof h === 'string').slice(0, 12)
        : [],
      updatedAt: serverTimestamp(),
      updatedBy: actorUid,
    };

    if (!skuId) {
      record.massStatus = 'draft';
      record.status = 'draft';
      record.verifiedUnitMassMg = null;
      record.verifiedBy = null;
      record.verifiedAt = null;
      record.activeFrom = null;
      record.activeTo = null;
      record.revision = 0;
      record.createdAt = serverTimestamp();
      record.createdBy = actorUid;
    }

    await audit.appendInTransaction(txn, {
      orgId,
      action: audit.ACTIONS.SKU_SAVED,
      actorUid,
      actorName,
      actorRole: 'producer',
      targetType: 'sku',
      targetId: ref.id,
      summary: skuId
        ? invalidation
          ? `Product "${record.name}" edited after verification — the verified `
            + `mass of ${(invalidation.previousVerifiedMassMg ?? 0) / MG_PER_GRAM} g `
            + `no longer applies and revision `
            + `${invalidation.previousRevision} was closed.`
          : `Product "${record.name}" edited.`
        : `Product "${record.name}" registered at ${record.declaredUnitMassG} g.`,
      after: { name: record.name, declaredUnitMassMg: declaredMg },
    });

    if (invalidation) {
      // Close the standing revision. Never deleted: a passport or report issued
      // against it must remain reproducible, and every attribution already
      // stored the revision and the unit mass it used (EPR-12).
      if (invalidation.previousRevision > 0) {
        txn.set(
          firestore
            .collection(REVISIONS)
            .doc(`${skuId}_${invalidation.previousRevision}`),
          {
            activeTo: admin.firestore.Timestamp.now(),
            closedReason: 'declarationChanged',
          },
          { merge: true },
        );
      }

      record.massStatus = 'draft';
      record.verifiedUnitMassMg = null;
      record.verifiedUnitMassG = null;
      record.verifiedBy = null;
      record.verifiedAt = null;
      record.activeFrom = null;
      record.activeTo = null;
      // `status` leaves 'active': a product whose mass is no longer verified
      // must not be recognised at a bin as though it were.
      record.status = 'draft';
      record.invalidatedAt = serverTimestamp();
      record.invalidatedReason =
        'The declaration changed after verification, so the verified mass no '
        + 'longer describes this product. Send it to Chokro again.';
    }

    if (skuId) {
      txn.update(ref, record);
    } else {
      txn.set(ref, record);
    }

    return {
      skuId: ref.id,
      declaredUnitMassMg: declaredMg,
      // Surfaced so the caller can tell the producer plainly that its verified
      // mass is gone, rather than letting them discover it on the next report.
      verificationInvalidated: invalidation !== null,
    };
  });
}

/**
 * Offers a declared mass to Chokro for verification (EPR-9).
 *
 * The stricter validation runs here rather than on save, so a producer can
 * write a half-finished draft over several sittings and only meets the full
 * requirement when they ask Chokro to weigh something.
 */
async function submitForVerification({ skuId, orgId, actorUid, actorName = '' }) {
  const firestore = db();
  const ref = firestore.collection(SKUS).doc(skuId);

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(ref);
    if (!snap.exists) throw notFound();

    const sku = snap.data();
    if (sku.orgId !== orgId) throw notFound();

    if (sku.massStatus === 'submitted') {
      throw conflict('This product is already with Chokro.');
    }

    const { problems } = validateSkuDraft(
      { ...sku, declaredUnitMassMg: sku.declaredUnitMassMg },
      { requireSubmittable: true },
    );
    if (problems.length > 0) {
      const error = new Error(problems.join(' '));
      error.problems = problems;
      error.code = 'not_submittable';
      throw error;
    }

    await audit.appendInTransaction(txn, {
      orgId,
      action: audit.ACTIONS.SKU_SUBMITTED,
      actorUid,
      actorName,
      actorRole: 'producer',
      targetType: 'sku',
      targetId: skuId,
      summary: `"${sku.name}" submitted for mass verification at ${
        sku.declaredUnitMassMg / MG_PER_GRAM
      } g.`,
      before: { massStatus: sku.massStatus },
      after: { massStatus: 'submitted' },
    });

    txn.update(ref, {
      massStatus: 'submitted',
      status: sku.status === 'draft' ? 'submitted' : sku.status,
      submittedAt: serverTimestamp(),
      submittedBy: actorUid,
      rejectionReason: null,
    });

    return { skuId, massStatus: 'submitted' };
  });
}

/**
 * Records a physical re-weighing and, with it, a verified mass
 * (EPR-11 case 1, §5.1 `skuMassAudits`).
 *
 * The audit is the artefact; the verified mass is its consequence. A weighing
 * that leaves no record of the sample size, the spread, the scale photograph
 * and the operator is not evidence a DoE inspector can check — it is a claim
 * that a weighing happened.
 *
 * THE MEASURED MEAN IS ALWAYS ADOPTED. The tolerance judges the *declaration*,
 * not which number is used.
 *
 * The specification is ambiguous here and this resolves it deliberately.
 * EPR-11's wording — "± 10% of declared, with the measured mean adopted as
 * verified when it falls outside" — reads as though a declaration inside the
 * tolerance is kept. Appendix A step 3 does the opposite: a five-unit mean of
 * 9.8 g against a declared 10.0 g is "within the ± 10% tolerance", and the
 * example still records `verifiedUnitMassG: 9.8` and states in bold that
 * "Reporting uses 9.8, not the declared 10.0."
 *
 * Appendix A is right, and the reason is the incentive structure §6.2 opens
 * with. Keeping the declaration whenever it sits inside the tolerance makes the
 * tolerance a licence: a producer declares 10.0 g, the true mass has been
 * light-weighted to 9.1 g, Chokro weighs 9.1 g, finds it within ±10%, and
 * certifies 10.0 g. That is a systematic 9% overstatement of collected
 * kilograms, in the producer's favour, sanctioned by the control meant to
 * prevent it — and repeatable across a whole catalogue. A five-unit mean
 * carries sampling error, but that error is unbiased; "adopt the declaration
 * when it is close enough" is biased in exactly one direction.
 *
 * So the verdict is a finding about the declaration, recorded for the audit
 * pack and for the anomaly queue (EPR-45), and the verified mass is what the
 * scale said.
 */
async function recordMassAudit({
  skuId,
  sampleSize,
  measuredMeanMg,
  measuredStdDevMg = null,
  weighingLocation = '',
  scalePhotoUrl = null,
  note = '',
  adminUid,
  adminName = '',
}) {
  if (!Number.isInteger(sampleSize) || sampleSize < 1) {
    throw badRequest('Record how many units were weighed.');
  }
  if (
    !Number.isInteger(measuredMeanMg) ||
    measuredMeanMg < MIN_UNIT_MASS_MG ||
    measuredMeanMg > MAX_UNIT_MASS_MG
  ) {
    throw badRequest('Record the measured mean mass.');
  }

  const policy = await eprPolicy.readPolicy();
  if (sampleSize < policy.massAuditSampleSize) {
    throw badRequest(
      `Policy requires at least ${policy.massAuditSampleSize} units. `
        + `This sample is ${sampleSize}.`,
    );
  }

  const firestore = db();
  const skuRef = firestore.collection(SKUS).doc(skuId);

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(skuRef);
    if (!snap.exists) throw notFound();

    const sku = snap.data();
    const declaredMg = sku.declaredUnitMassMg;
    if (!Number.isInteger(declaredMg) || declaredMg <= 0) {
      throw conflict('This product has no usable declared mass to check.');
    }

    const withinTolerance = eprPolicy.isWithinTolerance({
      declaredMg,
      measuredMeanMg,
      toleranceFraction: policy.massToleranceFraction,
    });

    const verdict = withinTolerance ? 'withinTolerance' : 'outsideTolerance';
    // Always the measurement. See the note above this function.
    const establishedMg = measuredMeanMg;

    // Every read in this transaction, before any write (see
    // `openRevisionInTransaction`). `doc()` allocates an id without writing, so
    // the audit reference can be named here and filled in below.
    const chainHead = await audit.readChainHead(txn, sku.orgId);
    const auditRef = firestore.collection(AUDITS).doc();

    txn.set(auditRef, {
      skuId,
      orgId: sku.orgId,
      sampleSize,
      measuredMeanMg,
      measuredStdDevMg: Number.isInteger(measuredStdDevMg)
        ? measuredStdDevMg
        : null,
      declaredUnitMassMg: declaredMg,
      verdict,
      weighingLocation: String(weighingLocation || '').slice(0, 200),
      operatorUid: adminUid,
      scalePhotoUrl: scalePhotoUrl || null,
      resultingAction: withinTolerance
        ? 'Measured mean adopted. The declaration was within tolerance.'
        : 'Measured mean adopted. The declaration was outside tolerance and is '
          + 'flagged for review.',
      // The tolerance in force *now*, stored on the record. An Admin tightening
      // it later must not retrospectively change whether this audit passed —
      // the same reason a disposal snapshots its points award.
      toleranceFraction: policy.massToleranceFraction,
      note: String(note || '').slice(0, 500),
      createdAt: serverTimestamp(),
    });

    const result = openRevisionInTransaction(txn, {
      skuRef,
      sku,
      skuId,
      chainHead,
      verifiedUnitMassMg: establishedMg,
      // The first verification of an SKU is `initialVerification`; every later
      // one is a re-weighing, whatever the verdict. The reason describes what
      // happened, not whether the producer's number survived.
      reason: (sku.revision || 0) === 0 ? 'initialVerification' : 'reweighed',
      note: note || null,
      auditId: auditRef.id,
      actorUid: adminUid,
      actorName: adminName,
      actorRole: 'admin',
      summary:
        `Mass verified at ${establishedMg / MG_PER_GRAM} g from a sample of ` +
        `${sampleSize} (declared ${declaredMg / MG_PER_GRAM} g, ${verdict}).`,
    });

    return { skuId, auditId: auditRef.id, verdict, ...result };
  });
}

/**
 * Sets a verified mass without a physical sample.
 *
 * EPR-11 cases 2 and 3: a manufacturer's technical data sheet for an SKU Chokro
 * cannot obtain, or an Admin override. Both require a stated reason, and the
 * reason is mandatory in code rather than by convention — a figure set by hand
 * with no recorded basis is exactly what a DoE data verification asks about.
 */
async function setVerifiedMass({
  skuId,
  verifiedUnitMassMg,
  reason,
  note,
  adminUid,
  adminName = '',
}) {
  if (!['documentary', 'adminOverride'].includes(reason)) {
    throw badRequest('Say whether this is documentary verification or an override.');
  }
  if (typeof note !== 'string' || note.trim().length < 10) {
    throw badRequest(
      'Record the basis for this figure — a data sheet reference, or why the '
        + 'override was made.',
    );
  }
  if (
    !Number.isInteger(verifiedUnitMassMg) ||
    verifiedUnitMassMg < MIN_UNIT_MASS_MG ||
    verifiedUnitMassMg > MAX_UNIT_MASS_MG
  ) {
    throw badRequest('The verified mass is outside the allowed range.');
  }

  const firestore = db();
  const skuRef = firestore.collection(SKUS).doc(skuId);

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(skuRef);
    if (!snap.exists) throw notFound();

    const sku = snap.data();
    // The last read, before the first write.
    const chainHead = await audit.readChainHead(txn, sku.orgId);

    return openRevisionInTransaction(txn, {
      skuRef,
      sku,
      skuId,
      chainHead,
      verifiedUnitMassMg,
      reason,
      note: note.trim(),
      auditId: null,
      actorUid: adminUid,
      actorName: adminName,
      actorRole: 'admin',
      summary:
        `Mass set to ${verifiedUnitMassMg / MG_PER_GRAM} g by ` +
        `${reason === 'documentary' ? 'documentary verification' : 'Admin override'}.`,
    });
  });
}

/**
 * Opens the next revision and closes the standing one (EPR-12).
 *
 * The single place a verified mass changes. Everything that sets one goes
 * through here, so there is exactly one implementation of "never edited in
 * place" to read and to test.
 *
 * WRITE-ONLY, AND THAT IS ENFORCED BY ITS SIGNATURE.
 *
 * It takes `chainHead` — already read by the caller through
 * `audit.readChainHead` — rather than reading it itself. Firestore requires
 * every read in a transaction to precede every write, and the Admin SDK throws
 * unconditionally otherwise. This function issues writes, so it must not read,
 * and demanding the head as a parameter is what makes that impossible to
 * forget: there is no version of this call that works without the caller having
 * done its reads first.
 */
function openRevisionInTransaction(
  txn,
  {
    skuRef,
    sku,
    skuId,
    chainHead,
    verifiedUnitMassMg,
    reason,
    note,
    auditId,
    actorUid,
    actorName,
    actorRole,
    summary,
  },
) {
  if (!REVISION_REASONS.includes(reason)) {
    throw badRequest('Unknown revision reason.');
  }

  const firestore = db();
  const nextRevision = (Number.isInteger(sku.revision) ? sku.revision : 0) + 1;
  const now = admin.firestore.Timestamp.now();

  audit.appendWithHead(txn, chainHead, {
    orgId: sku.orgId,
    action: audit.ACTIONS.SKU_MASS_VERIFIED,
    actorUid,
    actorName,
    actorRole,
    targetType: 'sku',
    targetId: skuId,
    summary,
    before: {
      verifiedUnitMassMg: sku.verifiedUnitMassMg ?? null,
      revision: sku.revision ?? 0,
    },
    after: { verifiedUnitMassMg, revision: nextRevision },
  });

  // Close the standing revision. Not deleted, not overwritten: a report issued
  // against it must remain reproducible (EPR-12).
  if (nextRevision > 1) {
    const previousRef = firestore
      .collection(REVISIONS)
      .doc(`${skuId}_${nextRevision - 1}`);
    txn.set(previousRef, { activeTo: now }, { merge: true });
  }

  const revisionRef = firestore
    .collection(REVISIONS)
    .doc(`${skuId}_${nextRevision}`);

  txn.set(revisionRef, {
    skuId,
    orgId: sku.orgId,
    revision: nextRevision,
    declaredUnitMassMg: sku.declaredUnitMassMg,
    verifiedUnitMassMg,
    // THE COMPONENT BREAKDOWN IS FROZEN ONTO THE REVISION.
    //
    // Per-polymer reporting is the whole reason components exist (EPR-9): one
    // recognised bottle contributes grams to a PET line and a PP line in the
    // same report. That split is computed from these masses, so reproducing a
    // past period needs the breakdown *as it was*, not as it is now.
    //
    // Editing components already invalidates a verification and opens a new
    // revision (EPR-12), so a live revision's breakdown cannot drift. What this
    // protects is a *closed* revision: September's polymer split must stay
    // September's after November's re-weighing, and reading the product would
    // give November's.
    components: Array.isArray(sku.components) ? sku.components : [],
    gazetteCategory: sku.gazetteCategory,
    polymer: sku.polymer,
    reason,
    note: note || null,
    changedBy: actorUid,
    auditId: auditId || null,
    activeFrom: now,
    activeTo: null,
    createdAt: serverTimestamp(),
  });

  txn.update(skuRef, {
    massStatus: 'verified',
    verifiedUnitMassMg,
    verifiedUnitMassG: verifiedUnitMassMg / MG_PER_GRAM,
    verifiedBy: actorUid,
    verifiedAt: now,
    activeFrom: now,
    activeTo: null,
    revision: nextRevision,
    rejectionReason: null,
    // A verified product is one that may be recognised at a bin. The lifecycle
    // status moves with the mass status here and only here.
    status: sku.status === 'retired' ? 'retired' : 'active',
  });

  // The organisation, so the caller can supersede the certificates this change
  // invalidates (EPR-30). A certificate's mass is units multiplied by the unit
  // mass Chokro established, so establishing a different one makes every
  // already-certified period state a figure Chokro no longer stands behind.
  return { revision: nextRevision, verifiedUnitMassMg, orgId: sku.orgId, skuId };
}

/** Refuses a submitted declaration, with a reason the producer will read. */
async function rejectSku({ skuId, reason, adminUid, adminName = '' }) {
  if (typeof reason !== 'string' || reason.trim().length < 5) {
    throw badRequest('Give a reason the producer can act on.');
  }

  const firestore = db();
  const ref = firestore.collection(SKUS).doc(skuId);

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(ref);
    if (!snap.exists) throw notFound();

    const sku = snap.data();
    if (sku.massStatus !== 'submitted') {
      throw conflict(`That product is not awaiting a decision (${sku.massStatus}).`);
    }

    await audit.appendInTransaction(txn, {
      orgId: sku.orgId,
      action: audit.ACTIONS.SKU_MASS_REJECTED,
      actorUid: adminUid,
      actorName: adminName,
      actorRole: 'admin',
      targetType: 'sku',
      targetId: skuId,
      summary: `Mass declaration rejected: ${reason.trim()}`,
      before: { massStatus: 'submitted' },
      after: { massStatus: 'rejected' },
    });

    txn.update(ref, {
      massStatus: 'rejected',
      rejectionReason: reason.trim().slice(0, 500),
      reviewedBy: adminUid,
      reviewedAt: serverTimestamp(),
    });

    return { skuId, massStatus: 'rejected' };
  });
}

// ---------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------

/** One organisation's registry. Bounded (QA-10). */
async function listSkus({ orgId, status = null, limit = 200 }) {
  let q = db().collection(SKUS).where('orgId', '==', orgId);
  if (status) q = q.where('status', '==', status);

  const snap = await q.orderBy('createdAt', 'desc').limit(limit).get();
  return snap.docs.map((d) => ({ skuId: d.id, ...d.data() }));
}

/**
 * The Admin mass-verification queue, oldest first (EPR-42).
 *
 * Oldest first for the same reason the existing review queues are: a cap keeps
 * the items that have waited longest, so the queue degrades by showing the most
 * overdue rather than the most recent.
 */
async function listVerificationQueue({ limit = 50 }) {
  const snap = await db()
    .collection(SKUS)
    .where('massStatus', '==', 'submitted')
    .orderBy('submittedAt', 'asc')
    .limit(limit)
    .get();

  return snap.docs.map((d) => ({ skuId: d.id, ...d.data() }));
}

/**
 * The revision that was in force at a given moment (EPR-12).
 *
 * THE FUNCTION THAT MAKES A PAST PERIOD REPRODUCIBLE.
 *
 * An attribution must multiply by the verified mass that applied on the day the
 * disposal was decided, not by the current one. Appendix A step 11 is the case:
 * a November re-weighing finds the bottle light-weighted to 9.1 g, and
 * September's passport stays correct because September's attributions used
 * revision 1 at 9.8 g. Reading `producerSkus.verifiedUnitMassMg` instead would
 * silently rewrite every past report every time a product was re-weighed.
 *
 * Returns null when no revision covers the moment — which is the honest answer
 * for a disposal that happened before the product's mass was ever verified, and
 * means "not attributable" rather than "use whatever is current".
 */
async function revisionActiveAt({ skuId, moment }) {
  if (!skuId || !(moment instanceof Date) || Number.isNaN(moment.getTime())) {
    return null;
  }

  try {
    // Revisions are few per product and effective-dated in sequence, so the
    // window test runs in memory over a bounded read rather than as two
    // inequality filters, which Firestore cannot combine on separate fields.
    const snap = await db()
      .collection(REVISIONS)
      .where('skuId', '==', skuId)
      .orderBy('revision', 'desc')
      .limit(50)
      .get();

    for (const doc of snap.docs) {
      const revision = doc.data();
      const from = revision.activeFrom?.toDate?.() ?? null;
      if (!from || moment < from) continue;

      const to = revision.activeTo?.toDate?.() ?? null;
      if (to && moment >= to) continue;

      if (!Number.isInteger(revision.verifiedUnitMassMg)) return null;
      return { id: doc.id, ...revision };
    }

    return null;
  } catch (err) {
    // Null, never a fallback to the current mass. A registry read that failed
    // must leave the disposal unattributed for a retry, not attribute it
    // against a figure from the wrong month.
    console.error(`[skus] revision lookup for ${skuId} failed:`, err.message);
    return null;
  }
}

/** One SKU's full revision history, oldest first. */
async function listRevisions({ skuId, limit = 50 }) {
  const snap = await db()
    .collection(REVISIONS)
    .where('skuId', '==', skuId)
    .orderBy('revision', 'asc')
    .limit(limit)
    .get();

  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

async function listMassAudits({ skuId, limit = 20 }) {
  const snap = await db()
    .collection(AUDITS)
    .where('skuId', '==', skuId)
    .orderBy('createdAt', 'desc')
    .limit(limit)
    .get();

  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

/**
 * Whether an SKU's verified mass is due for re-verification (EPR-13).
 *
 * Resolved lazily at read time, in the pattern of `UserModel.isActiveAt` and
 * for the same reason: nothing runs on a timer (§3.3, NFR-E-2). A caller asking
 * the question gets the answer; no process rewrites a status when a clock
 * passes.
 */
function revalidationDue(sku, policy, now = new Date()) {
  if (sku.massStatus !== 'verified') return false;

  const verifiedAt = sku.verifiedAt?.toDate?.() ?? null;
  if (!verifiedAt) return false;

  const dueAt = new Date(verifiedAt);
  dueAt.setMonth(dueAt.getMonth() + policy.massRevalidationMonths);
  return now >= dueAt;
}

/** Normalised brand key, matching `organizations.brandKey`. */
function brandKey(value) {
  return String(value || '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '');
}

function notFound() {
  const error = new Error('That product no longer exists.');
  error.code = 'not_found';
  return error;
}

function conflict(message) {
  const error = new Error(message);
  error.code = 'conflict';
  return error;
}

function badRequest(message) {
  const error = new Error(message);
  error.code = 'bad_request';
  return error;
}

module.exports = {
  STRICT_NUMBER,
  SKUS,
  REVISIONS,
  AUDITS,
  MASS_STATUSES,
  SKU_STATUSES,
  GAZETTE_CATEGORIES,
  POLYMERS,
  REVISION_REASONS,
  MIN_UNIT_MASS_MG,
  MAX_UNIT_MASS_MG,
  MIN_COMPONENT_MASS_MG,
  componentMilligramsFromGrams,
  MG_PER_GRAM,
  milligramsFromGrams,
  normalizeComponents,
  validateSkuDraft,
  physicalDeclarationChanged,
  canonicalComponents,
  brandKey,
  saveSkuDraft,
  submitForVerification,
  recordMassAudit,
  setVerifiedMass,
  rejectSku,
  listSkus,
  listVerificationQueue,
  listRevisions,
  listMassAudits,
  revisionActiveAt,
  revalidationDue,
};
