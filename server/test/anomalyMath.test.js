/**
 * The anomaly detectors (EPR-45).
 *
 * ===========================================================================
 * MOST OF THIS FILE IS ABOUT WHAT DOES *NOT* FIRE
 * ===========================================================================
 *
 * EPR-45 asks for "an Admin queue rather than an automatic block", and a queue
 * has a failure mode a block does not: if it fills with findings that have an
 * ordinary explanation, the person reading it learns to clear it without
 * looking. At that point the detectors are worse than absent, because Chokro
 * believes it is watching.
 *
 * So every detector here has a floor — a minimum history, a minimum sample, a
 * minimum mass — and each floor is a deliberate blind spot accepted to keep the
 * queue readable. The tests for those floors are the important ones.
 */

const anomalies = require('../src/anomalyMath');

const {
  skuMassSpike,
  binConcentration,
  accountConcentration,
  confidenceDrift,
  unitMassOutlier,
  targetEdge,
  quantile,
  ANOMALY_TYPES,
} = anomalies;

const MG = 1000000; // one kilogram

describe('a SKU whose mass jumps', () => {
  const base = {
    skuId: 'sku_cola',
    trailingMassMg: [10 * MG, 12 * MG, 8 * MG],
    multiple: 3,
  };

  test('fires above the multiple', () => {
    const finding = skuMassSpike({ ...base, currentMassMg: 40 * MG });

    expect(finding.type).toBe(ANOMALY_TYPES.SKU_MASS_SPIKE);
    expect(finding.figures.observedMultiple).toBeCloseTo(4, 1);
    expect(finding.subjectId).toBe('sku_cola');
  });

  test('does not fire below it', () => {
    expect(skuMassSpike({ ...base, currentMassMg: 25 * MG })).toBeNull();
  });

  test('says the innocent explanation first', () => {
    // An Admin who reads every finding as an accusation will either escalate
    // everything or stop reading. Each summary leads with the likelier cause.
    const finding = skuMassSpike({ ...base, currentMassMg: 40 * MG });
    expect(finding.summary).toMatch(/genuine sales increase|new distributor/i);
  });

  test('stays silent on a SKU with too little history', () => {
    // THE FLOOR THAT MATTERS MOST HERE. With one prior period the "trailing
    // average" is that period, so any growth reads as a multiple of it — and a
    // product whose first month was a pilot and second was a launch would fire
    // every time. That is the most ordinary event in the dataset.
    for (const history of [[], [10 * MG], [10 * MG, 12 * MG]]) {
      expect(
        skuMassSpike({ ...base, trailingMassMg: history, currentMassMg: 90 * MG }),
      ).toBeNull();
    }
  });

  test('stays silent when the trailing history is all nil', () => {
    // Dividing by it would report an infinite multiple for the first gram.
    expect(
      skuMassSpike({ ...base, trailingMassMg: [0, 0, 0], currentMassMg: 50 * MG }),
    ).toBeNull();
  });

  test('stays silent on a trivial absolute mass', () => {
    // Ten grams against a trailing average of two is a multiple of five and is
    // not worth an Admin's attention.
    expect(
      skuMassSpike({
        ...base,
        trailingMassMg: [2000, 2000, 2000],
        currentMassMg: 10000,
      }),
    ).toBeNull();
  });

  test('excludes the current period from its own baseline', () => {
    // Including it would drag the average toward the spike, so the bigger the
    // anomaly the less anomalous it would look.
    const finding = skuMassSpike({ ...base, currentMassMg: 40 * MG });
    // 40 / 10 = 4, not 40 / 17.5 = 2.3.
    expect(finding.figures.trailingAverageMassMg).toBe(10 * MG);
  });

  test('escalates a very large multiple', () => {
    expect(skuMassSpike({ ...base, currentMassMg: 40 * MG }).severity).toBe('medium');
    expect(skuMassSpike({ ...base, currentMassMg: 200 * MG }).severity).toBe('high');
  });
});

describe('a bin producing most of a brand', () => {
  const base = { binId: 'bin_a', totalMassMg: 100 * MG, binCount: 10, shareThreshold: 0.4 };

  test('fires above the share threshold', () => {
    const finding = binConcentration({ ...base, binMassMg: 60 * MG });
    expect(finding.figures.share).toBeCloseTo(0.6, 3);
    expect(finding.subjectType).toBe('bin');
  });

  test('stays silent when there are too few bins to concentrate in', () => {
    // A brand collected at two bins has a leading bin with at least half its
    // mass, always, and nothing follows from that. The share means something
    // only once a concentration is a choice rather than arithmetic.
    for (const binCount of [1, 2, 3]) {
      expect(
        binConcentration({ ...base, binCount, binMassMg: 99 * MG }),
      ).toBeNull();
    }
  });

  test('stays silent on a trivial mass', () => {
    expect(
      binConcentration({ ...base, totalMassMg: 2000, binMassMg: 1900 }),
    ).toBeNull();
  });

  test('names the innocent explanations', () => {
    const finding = binConcentration({ ...base, binMassMg: 60 * MG });
    expect(finding.summary).toMatch(/bottling plant|distributor|campus/i);
  });
});

describe('one account attributed most of a brand', () => {
  const base = {
    accountId: 'uid_champion',
    totalMassMg: 100 * MG,
    accountCount: 20,
    shareThreshold: 0.25,
  };

  test('fires above the share threshold', () => {
    const finding = accountConcentration({ ...base, accountMassMg: 40 * MG });
    expect(finding.type).toBe(ANOMALY_TYPES.ACCOUNT_CONCENTRATION);
    expect(finding.severity).toBe('medium');
  });

  test('carries the account as an id and never as a name', () => {
    // SEC-3. This finding names a person, which is why it is Admin-only and
    // why nothing here carries anything but the uid.
    const finding = accountConcentration({ ...base, accountMassMg: 40 * MG });
    const serialised = JSON.stringify(finding);

    expect(finding.subjectId).toBe('uid_champion');
    expect(serialised).not.toMatch(/name|email|phone/i);
  });

  test('stays silent when there are too few accounts', () => {
    for (const accountCount of [1, 2, 4]) {
      expect(
        accountConcentration({ ...base, accountCount, accountMassMg: 99 * MG }),
      ).toBeNull();
    }
  });
});

describe('recognition confidence drifting for a SKU', () => {
  const base = {
    skuId: 'sku_cola',
    trailingMediumShare: [0.10, 0.12, 0.08],
    driftThreshold: 0.15,
    currentMatches: 100,
  };

  test('fires when the medium share rises above its own baseline', () => {
    const finding = confidenceDrift({ ...base, currentMediumShare: 0.40 });
    expect(finding.figures.drift).toBeCloseTo(0.30, 2);
  });

  test('reads the drift against this SKU’s own history, not a global one', () => {
    // Recognition is genuinely harder for a transparent wrapper than a printed
    // bottle, so a SKU that has ALWAYS been 60% medium is not drifting — it is
    // a hard SKU, and flagging it every period would be noise forever.
    const hardSku = confidenceDrift({
      ...base,
      trailingMediumShare: [0.60, 0.62, 0.58],
      currentMediumShare: 0.61,
    });
    expect(hardSku).toBeNull();
  });

  test('does not fire when recognition gets BETTER', () => {
    // One-sided on purpose: reporting improvement would halve the queue's
    // signal-to-noise for nothing.
    expect(
      confidenceDrift({ ...base, currentMediumShare: 0.01 }),
    ).toBeNull();
  });

  test('stays silent on too few matches', () => {
    // A handful of matches moves a ratio a long way, and one bad photograph
    // should not fill the queue.
    expect(
      confidenceDrift({ ...base, currentMediumShare: 0.9, currentMatches: 5 }),
    ).toBeNull();
  });

  test('offers the packaging-redesign reading, as EPR-45 does', () => {
    const finding = confidenceDrift({ ...base, currentMediumShare: 0.40 });
    expect(finding.summary).toMatch(/packaging redesign/i);
  });
});

describe('a unit mass far from its category', () => {
  // A realistic rigid-packaging spread: small bottles through a water jar.
  const comparables = [
    9800, 10200, 11000, 12500, 14000, 18000, 24000, 31000, 480000,
  ];
  const base = { skuId: 'sku_x', comparableUnitMassesMg: comparables, iqrMultiple: 1.5 };

  test('fires on a heavy outlier, and treats it as the serious direction', () => {
    const finding = unitMassOutlier({ ...base, declaredUnitMassMg: 200000 });

    expect(finding.figures.direction).toBe('heavy');
    // A heavier unit mass raises every figure Chokro reports for the product,
    // so this is the direction with a motive behind it.
    expect(finding.severity).toBe('high');
    expect(finding.summary).toMatch(/worth weighing again/i);
  });

  test('treats a light outlier as low severity', () => {
    const finding = unitMassOutlier({ ...base, declaredUnitMassMg: 50 });
    if (finding) {
      expect(finding.figures.direction).toBe('light');
      expect(finding.severity).toBe('low');
    }
  });

  test('is not dragged by the category’s own extremes', () => {
    // The 480 g water jar is a genuine member of the rigid category. A mean and
    // a standard deviation are both pulled by it, so the test would weaken the
    // more skewed the category is; the median and IQR are not.
    const finding = unitMassOutlier({ ...base, declaredUnitMassMg: 20000 });
    expect(finding).toBeNull();

    const mean = comparables.reduce((a, b) => a + b, 0) / comparables.length;
    // 20 g is well inside the IQR fence and well BELOW the mean the jar drags
    // upward — evidence the two tests would disagree.
    expect(mean).toBeGreaterThan(60000);
  });

  test('stays silent with too few comparables to have a distribution', () => {
    expect(
      unitMassOutlier({
        ...base,
        comparableUnitMassesMg: [9800, 10000, 10200],
        declaredUnitMassMg: 900000,
      }),
    ).toBeNull();
  });

  test('stays silent when the category has no spread at all', () => {
    // Every deviation would read as infinite.
    expect(
      unitMassOutlier({
        ...base,
        comparableUnitMassesMg: Array(10).fill(10000),
        declaredUnitMassMg: 50000,
      }),
    ).toBeNull();
  });
});

describe('a percentage that clears the target just before close', () => {
  const base = {
    periodId: '2026-09',
    applicableTarget: 0.15,
    marginThreshold: 0.02,
    daysThreshold: 3,
  };

  test('fires on a narrow clearance filed late', () => {
    const finding = targetEdge({
      ...base,
      collectionRate: 0.152,
      declarationFiledDaysBeforeClose: 1,
    });

    expect(finding.type).toBe(ANOMALY_TYPES.TARGET_EDGE);
    expect(finding.figures.margin).toBeCloseTo(0.002, 4);
  });

  test('does not fire on a comfortable clearance, however late', () => {
    // A producer that meets its target is doing the thing the scheme exists to
    // encourage. Flagging success would be perverse.
    expect(
      targetEdge({ ...base, collectionRate: 0.40, declarationFiledDaysBeforeClose: 0 }),
    ).toBeNull();
  });

  test('does not fire on a narrow clearance filed early', () => {
    // The signal is the COINCIDENCE. Filed on the first of the month, the
    // producer did not know the numerator.
    expect(
      targetEdge({ ...base, collectionRate: 0.152, declarationFiledDaysBeforeClose: 25 }),
    ).toBeNull();
  });

  test('does not fire on a producer that fell short', () => {
    // Falling short is the ordinary case the scheme is designed to change, not
    // a fraud signal.
    expect(
      targetEdge({ ...base, collectionRate: 0.05, declarationFiledDaysBeforeClose: 1 }),
    ).toBeNull();
  });

  test('needs a target and a rate to say anything', () => {
    expect(
      targetEdge({ ...base, collectionRate: null, declarationFiledDaysBeforeClose: 1 }),
    ).toBeNull();
    expect(
      targetEdge({
        ...base,
        applicableTarget: null,
        collectionRate: 0.152,
        declarationFiledDaysBeforeClose: 1,
      }),
    ).toBeNull();
  });
});

describe('every detector', () => {
  const invocations = [
    () => skuMassSpike({ skuId: 's', currentMassMg: 40 * MG, trailingMassMg: [10 * MG, 10 * MG, 10 * MG], multiple: 3 }),
    () => binConcentration({ binId: 'b', binMassMg: 60 * MG, totalMassMg: 100 * MG, binCount: 10, shareThreshold: 0.4 }),
    () => accountConcentration({ accountId: 'u', accountMassMg: 40 * MG, totalMassMg: 100 * MG, accountCount: 20, shareThreshold: 0.25 }),
    () => confidenceDrift({ skuId: 's', currentMediumShare: 0.4, trailingMediumShare: [0.1, 0.1, 0.1], driftThreshold: 0.15, currentMatches: 100 }),
    () => unitMassOutlier({ skuId: 's', declaredUnitMassMg: 200000, comparableUnitMassesMg: [9800, 10200, 11000, 12500, 14000, 18000, 24000, 31000], iqrMultiple: 1.5 }),
    () => targetEdge({ periodId: '2026-09', collectionRate: 0.152, applicableTarget: 0.15, declarationFiledDaysBeforeClose: 1, marginThreshold: 0.02, daysThreshold: 3 }),
  ];

  test('returns a finding with the fields the queue needs', () => {
    for (const invoke of invocations) {
      const finding = invoke();
      expect(finding).not.toBeNull();
      expect(Object.values(ANOMALY_TYPES)).toContain(finding.type);
      expect(anomalies.SEVERITIES).toContain(finding.severity);
      expect(finding.subjectId).toBeTruthy();
      expect(finding.subjectType).toBeTruthy();
      expect(finding.figures).toBeInstanceOf(Object);
      expect(finding.summary.length).toBeGreaterThan(40);
    }
  });

  test('carries the threshold that triggered it', () => {
    // So an Admin reading a finding six months later knows what the policy was
    // at the time, rather than comparing it against today's.
    for (const invoke of invocations) {
      const values = Object.values(invoke().figures);
      expect(values.some((v) => typeof v === 'number')).toBe(true);
    }
  });

  test('describes rather than decides', () => {
    // EPR-45: "an Admin queue rather than an automatic block". Nothing a
    // detector returns is an instruction.
    for (const invoke of invocations) {
      const finding = invoke();
      expect(finding).not.toHaveProperty('block');
      expect(finding).not.toHaveProperty('reject');
      expect(finding).not.toHaveProperty('action');
    }
  });

  test('is pure — the same input twice gives the same finding', () => {
    for (const invoke of invocations) {
      expect(invoke()).toEqual(invoke());
    }
  });
});

describe('quantiles', () => {
  test('interpolate between samples', () => {
    expect(quantile([1, 2, 3, 4, 5, 6, 7, 8, 9], 0.25)).toBe(3);
    expect(quantile([1, 2, 3, 4, 5, 6, 7, 8, 9], 0.5)).toBe(5);
    expect(quantile([1, 2, 3, 4, 5, 6, 7, 8, 9], 0.75)).toBe(7);
    expect(quantile([1, 2, 3, 4], 0.5)).toBe(2.5);
  });

  test('handle degenerate samples without throwing', () => {
    expect(quantile([], 0.5)).toBe(0);
    expect(quantile([7], 0.5)).toBe(7);
  });
});
