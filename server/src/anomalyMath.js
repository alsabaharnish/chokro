/**
 * Chokro — the anomaly detectors (EPR-45).
 *
 * ===========================================================================
 * PURE, AND DELIBERATELY SO
 * ===========================================================================
 *
 * Every function here is a derivation over numbers already read. Nothing
 * touches Firestore, nothing reads a clock, nothing has an opinion about what
 * to do with a finding. `anomalies.js` does the reading and the writing; this
 * file decides only whether a set of figures is strange.
 *
 * The split is the same one `compliance_math.dart` makes and for the same
 * reason: a detector that can only be exercised through a database is a
 * detector nobody writes the awkward test for — and the awkward cases are the
 * entire point. A SKU with one prior period. A brand collected at exactly one
 * bin. A Champion who is the only person who has ever used a bin.
 *
 * ===========================================================================
 * A QUEUE, NOT A BLOCK
 * ===========================================================================
 *
 * EPR-45 is explicit: "as an Admin queue rather than an automatic block". So
 * every function here returns a FINDING OR NULL, and a finding is a
 * description, never a verdict. Nothing in this module or its caller refuses a
 * disposal, withholds a certificate, or changes a figure.
 *
 * That is not timidity. Each of these signals has an innocent explanation that
 * is more common than the guilty one — a packaging redesign, a new distributor,
 * a university campus with one very active collector — and a system that
 * blocked on them would be wrong most of the time while training its operators
 * to click through the warning.
 *
 * ===========================================================================
 * WHAT A FINDING SAYS, AND WHAT IT REFUSES TO SAY
 * ===========================================================================
 *
 * Each finding carries the figures that triggered it and a sentence naming the
 * INNOCENT explanation first. "Usually a packaging redesign the producer has
 * not declared" is EPR-45's own gloss on the confidence-drift detector, and it
 * belongs in the queue rather than in a comment: an Admin who reads every
 * finding as an accusation will either escalate everything or stop reading.
 */

/** The detector vocabulary. Stored on findings, so it is a fixed set. */
const ANOMALY_TYPES = Object.freeze({
  SKU_MASS_SPIKE: 'skuMassSpike',
  BIN_CONCENTRATION: 'binConcentration',
  ACCOUNT_CONCENTRATION: 'accountConcentration',
  CONFIDENCE_DRIFT: 'confidenceDrift',
  UNIT_MASS_OUTLIER: 'unitMassOutlier',
  TARGET_EDGE: 'targetEdge',
});

const SEVERITIES = Object.freeze(['low', 'medium', 'high']);

/**
 * Attributed mass for one SKU jumping beyond a multiple of its trailing
 * average (EPR-45).
 *
 * ## Why a minimum history, and why it is not negotiable
 *
 * A SKU with one prior period has a "trailing average" of that single period,
 * so any growth at all reads as a multiple of it. A newly registered product
 * whose first month was a pilot and whose second was a national launch would
 * trigger on its second period, every time — and the queue would fill with the
 * most ordinary event in the dataset.
 *
 * So fewer than [minPeriods] of history yields no finding. That is a real blind
 * spot: a SKU registered to inflate a first return is invisible here. It is
 * covered elsewhere — the mass chain verifies unit masses (EPR-9) and the
 * declaration is attested — and a detector that fires on every new product
 * would be worse than this gap.
 *
 * ## Why the trailing average excludes the current period
 *
 * Including it drags the average toward the spike and shrinks the multiple,
 * which is exactly backwards: the bigger the anomaly, the less anomalous it
 * would look.
 */
function skuMassSpike({
  skuId,
  currentMassMg,
  trailingMassMg,
  multiple,
  minPeriods = 3,
  minMassMg = 1000000,
}) {
  const history = (trailingMassMg ?? []).filter((mg) => Number.isFinite(mg));
  if (history.length < minPeriods) return null;

  // A SKU whose whole history is nil has no meaningful average, and dividing
  // by it would report an infinite multiple for the first gram collected.
  const total = history.reduce((sum, mg) => sum + mg, 0);
  if (total <= 0) return null;

  const average = total / history.length;

  // A floor in absolute terms as well as in ratio. Ten grams against a
  // trailing average of two is a multiple of five and is not worth an Admin's
  // attention; the ratio alone would surface every trivial product.
  if (currentMassMg < minMassMg) return null;

  const observed = currentMassMg / average;
  if (observed < multiple) return null;

  return {
    type: ANOMALY_TYPES.SKU_MASS_SPIKE,
    subjectType: 'sku',
    subjectId: skuId,
    severity: observed >= multiple * 2 ? 'high' : 'medium',
    figures: {
      currentMassMg,
      trailingAverageMassMg: Math.round(average),
      observedMultiple: round(observed, 2),
      threshold: multiple,
      periodsOfHistory: history.length,
    },
    summary:
      `Attributed mass is ${round(observed, 1)}× its trailing average over `
      + `${history.length} periods. Usually a genuine sales increase or a new `
      + 'distributor; worth confirming the product has not been re-registered '
      + 'under a heavier unit mass.',
  };
}

/**
 * One bin producing an implausible share of one brand's attributed mass
 * (EPR-45).
 *
 * ## Why a minimum bin count as well as a share threshold
 *
 * A brand collected at two bins has a leading bin with at least 50% of its
 * mass, always, and nothing follows from that. The share only means something
 * once there are enough bins for a concentration to be a choice rather than an
 * arithmetic necessity.
 */
function binConcentration({
  binId,
  binMassMg,
  totalMassMg,
  binCount,
  shareThreshold,
  minBins = 4,
  minMassMg = 1000000,
}) {
  if (binCount < minBins) return null;
  if (totalMassMg <= 0 || binMassMg < minMassMg) return null;

  const share = binMassMg / totalMassMg;
  if (share < shareThreshold) return null;

  return {
    type: ANOMALY_TYPES.BIN_CONCENTRATION,
    subjectType: 'bin',
    subjectId: binId,
    severity: share >= 0.75 ? 'high' : 'medium',
    figures: {
      binMassMg,
      totalMassMg,
      share: round(share, 4),
      threshold: shareThreshold,
      binCount,
    },
    summary:
      `${round(share * 100, 1)}% of this brand's attributed mass came from a `
      + `single bin, out of ${binCount} bins with any of it. Often a bin beside `
      + 'a bottling plant, a distributor or a large campus; worth confirming it '
      + 'is not one account disposing of collected-elsewhere material.',
  };
}

/**
 * One account attributed a disproportionate share of one brand (EPR-45).
 *
 * ## This finding names a person, and that constrains where it can go
 *
 * SEC-3: a producer must never learn anything about an individual Champion.
 * This detector exists because a single account farming one brand is a real
 * fraud pattern, and catching it requires looking at accounts — but the finding
 * is Admin-only, and `anomalies.js` writes it to a collection no producer can
 * read. The account is carried as its uid and never as a name.
 */
function accountConcentration({
  accountId,
  accountMassMg,
  totalMassMg,
  accountCount,
  shareThreshold,
  minAccounts = 5,
  minMassMg = 1000000,
}) {
  if (accountCount < minAccounts) return null;
  if (totalMassMg <= 0 || accountMassMg < minMassMg) return null;

  const share = accountMassMg / totalMassMg;
  if (share < shareThreshold) return null;

  return {
    type: ANOMALY_TYPES.ACCOUNT_CONCENTRATION,
    subjectType: 'account',
    subjectId: accountId,
    severity: share >= 0.5 ? 'high' : 'medium',
    figures: {
      accountMassMg,
      totalMassMg,
      share: round(share, 4),
      threshold: shareThreshold,
      accountCount,
    },
    summary:
      `${round(share * 100, 1)}% of this brand's attributed mass came from one `
      + `account, out of ${accountCount} accounts with any of it. Often a `
      + 'dedicated collector working a commercial route; worth confirming '
      + 'against that account’s disposal photographs.',
  };
}

/**
 * Recognition confidence drifting for one SKU (EPR-45).
 *
 * EPR-45's own gloss: "usually a packaging redesign the producer has not
 * declared". That reading is in the summary, because it is the likeliest cause
 * and an Admin who treats every finding as fraud stops reading the queue.
 *
 * ## Why the drift is measured against this SKU's own history
 *
 * Not against a global baseline. Recognition is genuinely harder for a
 * transparent flexible wrapper than for a printed rigid bottle, so a SKU that
 * has always been 60% medium-confidence is not drifting — it is a hard SKU. The
 * signal is a CHANGE in a SKU's own mix.
 */
function confidenceDrift({
  skuId,
  currentMediumShare,
  trailingMediumShare,
  driftThreshold,
  minPeriods = 3,
  minMatches = 20,
  currentMatches = 0,
}) {
  const history = (trailingMediumShare ?? []).filter((v) => Number.isFinite(v));
  if (history.length < minPeriods) return null;

  // A handful of matches moves a ratio a long way. Twenty is not a
  // statistically satisfying floor, and it is enough to stop one bad photograph
  // from filling the queue.
  if (currentMatches < minMatches) return null;

  const baseline = history.reduce((sum, v) => sum + v, 0) / history.length;
  const drift = currentMediumShare - baseline;

  // One-sided. Recognition getting BETTER is not an anomaly, and reporting it
  // would halve the signal-to-noise of the queue for nothing.
  if (drift < driftThreshold) return null;

  return {
    type: ANOMALY_TYPES.CONFIDENCE_DRIFT,
    subjectType: 'sku',
    subjectId: skuId,
    severity: drift >= driftThreshold * 2 ? 'high' : 'medium',
    figures: {
      currentMediumShare: round(currentMediumShare, 4),
      baselineMediumShare: round(baseline, 4),
      drift: round(drift, 4),
      threshold: driftThreshold,
      periodsOfHistory: history.length,
      currentMatches,
    },
    summary:
      `Medium-confidence matches rose ${round(drift * 100, 1)} points above `
      + `this product's own baseline of ${round(baseline * 100, 1)}%. Usually a `
      + 'packaging redesign the producer has not declared, which makes the '
      + 'registered sample images stale.',
  };
}

/**
 * A declared unit mass far from the distribution of comparable products
 * (EPR-45).
 *
 * ## Why the median and the IQR rather than the mean and a standard deviation
 *
 * The comparison set is other SKUs in the same gazette category, and that set
 * contains genuine extremes — a 20-litre water jar sits in the same category as
 * a 250 ml bottle. A mean and a standard deviation are both dragged by exactly
 * those outliers, so the test becomes weaker the more skewed the category is.
 * The median and the interquartile range are not.
 */
function unitMassOutlier({
  skuId,
  declaredUnitMassMg,
  comparableUnitMassesMg,
  iqrMultiple,
  minComparables = 8,
}) {
  const sample = (comparableUnitMassesMg ?? [])
    .filter((mg) => Number.isFinite(mg) && mg > 0)
    .sort((a, b) => a - b);

  // Too few comparables and the quartiles are noise. A category with five
  // registered products has no distribution to be an outlier from.
  if (sample.length < minComparables) return null;
  if (!Number.isFinite(declaredUnitMassMg) || declaredUnitMassMg <= 0) return null;

  const q1 = quantile(sample, 0.25);
  const q3 = quantile(sample, 0.75);
  const iqr = q3 - q1;

  // A category whose middle half is identical has no spread to measure
  // against, and any deviation would read as infinite.
  if (iqr <= 0) return null;

  const upper = q3 + iqr * iqrMultiple;
  const lower = q1 - iqr * iqrMultiple;

  if (declaredUnitMassMg <= upper && declaredUnitMassMg >= lower) return null;

  const heavy = declaredUnitMassMg > upper;

  return {
    type: ANOMALY_TYPES.UNIT_MASS_OUTLIER,
    subjectType: 'sku',
    subjectId: skuId,
    // A heavy outlier inflates the producer's reported collection; a light one
    // deflates it. The heavy direction is the one with a motive behind it.
    severity: heavy ? 'high' : 'low',
    figures: {
      declaredUnitMassMg,
      medianUnitMassMg: Math.round(quantile(sample, 0.5)),
      q1UnitMassMg: Math.round(q1),
      q3UnitMassMg: Math.round(q3),
      upperFenceMg: Math.round(upper),
      lowerFenceMg: Math.round(lower),
      comparables: sample.length,
      direction: heavy ? 'heavy' : 'light',
    },
    summary:
      `Unit mass is ${heavy ? 'above' : 'below'} the range of the `
      + `${sample.length} comparable products in its gazette category `
      + `(middle half ${Math.round(q1 / 1000)}–${Math.round(q3 / 1000)} g). `
      + (heavy
        ? 'A heavier unit mass raises every figure Chokro reports for this '
          + 'product, so this one is worth weighing again.'
        : 'Often a genuinely light product such as a film or a sachet.'),
  };
}

/**
 * A collection percentage crossing a gazette target just before a period
 * closes (EPR-45).
 *
 * ## What this detector is actually about
 *
 * Not the percentage. A producer that meets its target is doing the thing the
 * scheme exists to encourage, and flagging success would be perverse.
 *
 * It is about the COINCIDENCE of two things: a rate that clears the threshold
 * by a hair, and a declaration filed in the last days before the period closed.
 * The denominator is the producer's own figure, and filing it late — once the
 * numerator is nearly known — is the one moment at which a small adjustment to
 * it decides whether the target is met.
 *
 * So a rate of 40% against a 15% target never fires however late it was filed,
 * and a rate of 15.2% filed on the first of the month never fires either. Both
 * conditions, or nothing.
 */
function targetEdge({
  periodId,
  collectionRate,
  applicableTarget,
  declarationFiledDaysBeforeClose,
  marginThreshold,
  daysThreshold,
}) {
  if (collectionRate === null || collectionRate === undefined) return null;
  if (applicableTarget === null || applicableTarget === undefined) return null;
  if (!Number.isFinite(declarationFiledDaysBeforeClose)) return null;

  // Only a rate that CLEARED the target. Falling short is not a fraud signal;
  // it is the ordinary case the scheme is designed to change.
  if (collectionRate < applicableTarget) return null;

  const margin = collectionRate - applicableTarget;
  if (margin > marginThreshold) return null;
  if (declarationFiledDaysBeforeClose > daysThreshold) return null;

  return {
    type: ANOMALY_TYPES.TARGET_EDGE,
    subjectType: 'period',
    subjectId: periodId,
    severity: 'medium',
    figures: {
      collectionRate: round(collectionRate, 6),
      applicableTarget,
      margin: round(margin, 6),
      marginThreshold,
      declarationFiledDaysBeforeClose,
      daysThreshold,
    },
    summary:
      `Cleared the ${round(applicableTarget * 100, 0)}% target by `
      + `${round(margin * 100, 2)} points, on a declaration filed `
      + `${declarationFiledDaysBeforeClose} day`
      + `${declarationFiledDaysBeforeClose === 1 ? '' : 's'} before the period `
      + 'closed. The denominator is the producer’s own figure, and a late '
      + 'filing is when a small change to it decides whether the target is met.',
  };
}

// ---------------------------------------------------------------------------
// Statistics
// ---------------------------------------------------------------------------

/**
 * A quantile by linear interpolation, over an already-sorted sample.
 *
 * Sorted by the caller rather than here, because every caller needs the sorted
 * array for something else too and sorting it three times would be the only
 * expensive thing in this file.
 */
function quantile(sorted, q) {
  if (sorted.length === 0) return 0;
  if (sorted.length === 1) return sorted[0];

  const position = (sorted.length - 1) * q;
  const lower = Math.floor(position);
  const upper = Math.ceil(position);
  if (lower === upper) return sorted[lower];

  return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - lower);
}

/** Rounds for display in a stored finding. Never used on a compliance figure. */
function round(value, places) {
  const scale = 10 ** places;
  return Math.round(value * scale) / scale;
}

module.exports = {
  ANOMALY_TYPES,
  SEVERITIES,
  skuMassSpike,
  binConcentration,
  accountConcentration,
  confidenceDrift,
  unitMassOutlier,
  targetEdge,
  quantile,
};
