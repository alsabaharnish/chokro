/**
 * Chokro — the EPR policy document (`config/eprPolicy`).
 *
 * WHY THESE ARE STORED AND NOT CONSTANTS
 * Every value here is a number Chokro chose and may revise: a verification
 * tolerance, a sample size, a confidence threshold, a shortlist cap. The
 * existing points policy already establishes the pattern and the reason — a
 * threshold in code can only be changed by a deploy, and a threshold nobody can
 * see cannot be audited.
 *
 * WHAT IS DELIBERATELY *NOT* HERE
 * The gazette's own collection and recycling targets. Those are the law's
 * numbers, not Chokro's, and putting them behind an editable policy document
 * would let an operator change what the regulation says. They live in
 * `GazetteTargets` in `lib/core/epr_categories.dart` as constants, with a
 * source.
 *
 * READS TOLERATE ABSENCE. A missing document, a missing field or a malformed
 * value falls back to the default below rather than throwing, in the manner of
 * `pointsPolicy.js` — a policy read is on the path of a mass verification, and
 * a verification that fails because an operator has never opened the policy
 * screen is a worse failure than one that uses a documented default.
 */

const { db, serverTimestamp } = require('./firebase');

const DOC_PATH = ['config', 'eprPolicy'];

/**
 * The defaults, each with the §15 open decision or requirement it answers.
 *
 * `massToleranceFraction` and `massAuditSampleSize` are open decision 3, whose
 * recommendation is ±10% and n ≥ 5. They are recorded here as the *current*
 * answer rather than the final one; the decision wants a documented method
 * note, and changing the number afterwards must not silently rewrite whether a
 * past audit passed — which is why `skuMassAudits` stores the tolerance that
 * was in force when it was judged.
 */
const DEFAULTS = Object.freeze({
  // EPR-11: physical sampling.
  massAuditSampleSize: 5,
  massToleranceFraction: 0.10,

  // EPR-13: re-verification is periodic, not one-off. Packaging is
  // light-weighted constantly — a 2026 bottle weighs less than a 2024 one.
  massRevalidationMonths: 12,

  /// Attributed mass for one SKU in a period, above which it is re-queued for
  /// sampling regardless of how recently it was verified. In kilograms.
  massRevalidationMassKg: 1000,

  // EPR-17: confidence tiers. Present in the policy from Phase B so the
  // document has one shape across phases, and read for the first time in
  // Phase C.
  highConfidenceThreshold: 0.85,
  lowConfidenceThreshold: 0.60,
  accuracyAuditSampleFraction: 0.02,

  // EPR-15, SEC-11, NFR-E-7: the recognition shortlist cap exists for cost as
  // much as for accuracy.
  skuShortlistCap: 40,

  /// SEC-3's k-anonymity floor.
  ///
  /// "Any producer-facing aggregate broken down finely enough to isolate
  /// individuals (a single bin, a single day) is suppressed below a policy
  /// k-anonymity floor (default k = 5)."
  ///
  /// The unit is disposals, because a disposal is one person's act. A district
  /// row built from a single disposal says where one identifiable person threw
  /// something away, and that is the disclosure the floor exists to prevent.
  kAnonymityFloor: 5,

  /// EPR-39's ceiling on uncertainty before a carbon figure is refused.
  ///
  /// "any carbon figure at all for a period whose `estimatedShare` exceeds a
  /// policy ceiling". A carbon estimate is already an indicative figure from a
  /// UK-derived factor; building it on a mass that is itself a quarter
  /// uncertain compounds two uncertainties into one number that reads as
  /// precise.
  carbonUncertaintyCeiling: 0.25,

  /// EPR-30's materiality threshold for reversal-driven supersession.
  ///
  /// "a reversed attribution above a policy materiality threshold" must
  /// supersede every affected passport. A threshold rather than any reversal at
  /// all, because a single mis-recognised bottle removed from a period does not
  /// make a certificate wrong, and superseding on every correction would train
  /// producers and their customers to ignore the status entirely — which is
  /// the one thing that would make supersession useless.
  ///
  /// Expressed as a fraction of the period's certified collected mass, so it
  /// scales: 1% of a large producer's month is a lot of material, and 1% of a
  /// small one's is not much, and in both cases it is the same distortion to
  /// the percentage on the certificate.
  reversalMaterialityFraction: 0.01,

  // EPR-19: category-average estimates for unmatched mass. Open decision 4,
  // whose recommendation is "not in v1" — a defensible smaller number is the
  // product. Present as a flag so turning it on is a deliberate act with a
  // recorded date, not a drift.
  estimateUnmatchedMass: false,
});

/** Clamps a policy number, falling back to the default when unusable. */
function readNumber(raw, key, { min, max }) {
  const value = raw?.[key];
  if (typeof value !== 'number' || !Number.isFinite(value)) return DEFAULTS[key];
  if (value < min || value > max) return DEFAULTS[key];
  return value;
}

function readBoolean(raw, key) {
  return typeof raw?.[key] === 'boolean' ? raw[key] : DEFAULTS[key];
}

/**
 * Normalises a stored policy document, field by field.
 *
 * Each bound is stated with the reason it exists, because a clamp with no
 * rationale is a number somebody will widen.
 */
function normalize(raw) {
  return {
    // Below five units a mean is not a mean; above fifty, nobody is weighing
    // that many bottles by hand.
    massAuditSampleSize: Math.round(
      readNumber(raw, 'massAuditSampleSize', { min: 3, max: 50 }),
    ),
    // A tolerance above a quarter would accept a declaration that is wrong by
    // more than the light-weighting a re-weigh is meant to catch. A tolerance
    // of zero would fail every audit on scale precision alone.
    massToleranceFraction: readNumber(raw, 'massToleranceFraction', {
      min: 0.01,
      max: 0.25,
    }),
    massRevalidationMonths: Math.round(
      readNumber(raw, 'massRevalidationMonths', { min: 1, max: 60 }),
    ),
    massRevalidationMassKg: readNumber(raw, 'massRevalidationMassKg', {
      min: 1,
      max: 1000000,
    }),
    highConfidenceThreshold: readNumber(raw, 'highConfidenceThreshold', {
      min: 0.5,
      max: 0.99,
    }),
    lowConfidenceThreshold: readNumber(raw, 'lowConfidenceThreshold', {
      min: 0.1,
      max: 0.9,
    }),
    accuracyAuditSampleFraction: readNumber(raw, 'accuracyAuditSampleFraction', {
      min: 0,
      max: 1,
    }),
    skuShortlistCap: Math.round(
      readNumber(raw, 'skuShortlistCap', { min: 5, max: 200 }),
    ),
    // A floor of 1 would suppress nothing, which is the same as not having the
    // control; above about fifty a producer with a modest programme would see
    // no geography at all and the figure would stop being useful.
    kAnonymityFloor: Math.round(
      readNumber(raw, 'kAnonymityFloor', { min: 2, max: 50 }),
    ),
    // A ceiling of 1 would never refuse, which is the same as not having the
    // control. Zero would refuse every period with any uncertainty at all,
    // including the ordinary case.
    carbonUncertaintyCeiling: readNumber(raw, 'carbonUncertaintyCeiling', {
      min: 0.01,
      max: 0.9,
    }),
    // A threshold of zero would supersede on every reversal, and one of 1
    // would never supersede at all — each is the same as not having the
    // control.
    reversalMaterialityFraction: readNumber(raw, 'reversalMaterialityFraction', {
      min: 0.0001,
      max: 0.5,
    }),
    estimateUnmatchedMass: readBoolean(raw, 'estimateUnmatchedMass'),
  };
}

/**
 * Checks a proposed policy for the invariants rules cannot express.
 *
 * The same shape as `pointsPolicy.validate`, and for the same reason: the
 * relationship between two fields is not something a per-field bound can state.
 */
function validate(policy) {
  const problems = [];
  const p = normalize(policy);

  if (p.lowConfidenceThreshold >= p.highConfidenceThreshold) {
    // Otherwise the medium tier is empty or inverted, and EPR-17's three
    // outcomes collapse into two with no way to tell which.
    problems.push(
      'The low-confidence threshold must be below the high-confidence one.',
    );
  }

  return problems;
}

/** Reads the policy, tolerating absence. */
async function readPolicy() {
  try {
    const snap = await db().collection(DOC_PATH[0]).doc(DOC_PATH[1]).get();
    return normalize(snap.exists ? snap.data() : null);
  } catch (err) {
    // A policy read failing must not fail a verification. The defaults are
    // documented and conservative, and the log line says the read failed so it
    // is not silent.
    console.error('[eprPolicy] read failed, using defaults:', err.message);
    return { ...DEFAULTS };
  }
}

/** Writes the policy after [validate] passes. Server-only, like every config. */
async function writePolicy(proposed, { adminUid }) {
  const problems = validate(proposed);
  if (problems.length > 0) {
    const error = new Error(problems.join(' '));
    error.problems = problems;
    throw error;
  }

  const policy = normalize(proposed);
  await db()
    .collection(DOC_PATH[0])
    .doc(DOC_PATH[1])
    .set(
      { ...policy, updatedAt: serverTimestamp(), updatedBy: adminUid },
      { merge: true },
    );

  return policy;
}

/**
 * Whether a measured mean is within tolerance of a declared mass.
 *
 * Takes the tolerance explicitly rather than reading the policy, so an audit
 * judged last year against a 10% tolerance is still judged against 10% when it
 * is re-examined — the stored `toleranceFraction` on the audit is what is
 * passed in.
 */
function isWithinTolerance({ declaredMg, measuredMeanMg, toleranceFraction }) {
  if (!Number.isFinite(declaredMg) || declaredMg <= 0) return false;
  if (!Number.isFinite(measuredMeanMg) || measuredMeanMg <= 0) return false;

  const allowed = declaredMg * toleranceFraction;
  return Math.abs(measuredMeanMg - declaredMg) <= allowed;
}

module.exports = {
  DEFAULTS,
  normalize,
  validate,
  readPolicy,
  writePolicy,
  isWithinTolerance,
};
