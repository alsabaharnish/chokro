/**
 * Reconciliation and the standing accuracy audit (EPR-17, EPR-48, QA-3).
 *
 * The accuracy queue has been filling since Phase C and nothing has ever
 * resolved one, so the precision figure EPR-17 says to publish in report
 * methodology has never been measurable. Most of this file is about the
 * discipline that makes that figure worth publishing: refusing to state one
 * below a sample floor, keeping `unclear` out of the ratio, and refusing to
 * state a recall figure at all.
 */

jest.mock('../src/firebase', () => ({
  db: jest.fn(),
  admin: {
    firestore: {
      FieldValue: {
        increment: (n) => ({ __increment: n }),
        arrayUnion: (...v) => ({ __arrayUnion: v }),
      },
      FieldPath: { documentId: () => '__name__' },
      Timestamp: { now: () => ({ toDate: () => new Date('2026-10-03T05:12:00Z') }) },
    },
  },
  serverTimestamp: jest.fn(() => '__TS__'),
}));

const firebase = require('../src/firebase');
const reconciliation = require('../src/reconciliation');
const audit = require('../src/producerAudit');
const { fakeFirestore } = require('./helpers/firestoreFake');

let fs;
const MG = 1000000;

beforeEach(() => {
  jest.clearAllMocks();
  fs = fakeFirestore();
  firebase.db.mockReturnValue(fs);
});

/** A sampled high-confidence match, as `attribute.js` writes it. */
function sample(id, over = {}) {
  fs._seed(reconciliation.CONFIRMATIONS, id, {
    orgId: 'org_cola',
    periodId: '2026-09',
    skuId: 'sku_cola',
    confidenceTier: 'high',
    reason: reconciliation.REASONS.ACCURACY_AUDIT,
    status: 'pending',
    createdAt: new Date('2026-09-14T09:00:00Z'),
    ...over,
  });
}

function reviewed(id, verdict, over = {}) {
  sample(id, {
    status: 'reviewed',
    verdict,
    reviewedAt: new Date('2026-09-20T09:00:00Z'),
    ...over,
  });
}

// ---------------------------------------------------------------------------
// Resolving a sampled match
// ---------------------------------------------------------------------------

describe('reviewing a sampled match', () => {
  test('records the verdict and who gave it', async () => {
    sample('c1');

    await reconciliation.resolveConfirmation({
      confirmationId: 'c1',
      verdict: 'correct',
      adminUid: 'uid_admin',
      adminName: 'Chokro Compliance',
    });

    const stored = fs._store.get(`${reconciliation.CONFIRMATIONS}/c1`);
    expect(stored.status).toBe('reviewed');
    expect(stored.verdict).toBe('correct');
    expect(stored.reviewedBy).toBe('uid_admin');
  });

  test('does NOT reverse the attribution', async () => {
    // A verdict is evidence about the model, not a correction. Reversing on
    // one reviewer's read would make the accuracy audit a second,
    // unaccountable attribution path — removing mass with no reason recorded
    // against it. Reversal is its own act, with its own reason and audit entry.
    fs._seed('attributions', 'attr_1', {
      orgId: 'org_cola', periodId: '2026-09', massMg: 19600,
    });
    sample('c1', { attributionId: 'attr_1' });

    await reconciliation.resolveConfirmation({
      confirmationId: 'c1', verdict: 'incorrect', adminUid: 'uid_admin',
    });

    const attribution = fs._store.get('attributions/attr_1');
    expect(attribution.reversedAt).toBeUndefined();
    expect(attribution.massMg).toBe(19600);
  });

  test('records the review in the audit chain', async () => {
    sample('c1');
    await reconciliation.resolveConfirmation({
      confirmationId: 'c1', verdict: 'incorrect', adminUid: 'uid_admin',
      note: 'The bottle is a competitor’s, not this producer’s.',
    });

    const entry = fs._find(audit.COLLECTION)
      .find((e) => e.action === audit.ACTIONS.ACCURACY_REVIEWED);
    expect(entry.summary).toMatch(/incorrect/);
    expect(entry.summary).toMatch(/competitor/);
  });

  test('refuses a verdict that is not one', async () => {
    sample('c1');
    for (const verdict of [undefined, '', 'maybe', 'yes']) {
      await expect(
        reconciliation.resolveConfirmation({
          confirmationId: 'c1', verdict, adminUid: 'uid_admin',
        }),
      ).rejects.toThrow(/correct, incorrect, unclear/);
    }
  });

  test('will not review the same match twice', async () => {
    sample('c1');
    await reconciliation.resolveConfirmation({
      confirmationId: 'c1', verdict: 'correct', adminUid: 'uid_admin',
    });
    await expect(
      reconciliation.resolveConfirmation({
        confirmationId: 'c1', verdict: 'incorrect', adminUid: 'uid_admin',
      }),
    ).rejects.toThrow(/already been reviewed/i);
  });

  test('refuses a match that does not exist', async () => {
    await expect(
      reconciliation.resolveConfirmation({
        confirmationId: 'nope', verdict: 'correct', adminUid: 'uid_admin',
      }),
    ).rejects.toThrow(/does not exist/i);
  });
});

describe('the pending sample', () => {
  test('is worked oldest first', async () => {
    sample('newer', { createdAt: new Date('2026-09-20') });
    sample('older', { createdAt: new Date('2026-09-01') });

    const pending = await reconciliation.listPendingSample({});
    expect(pending.map((p) => p.id)).toEqual(['older', 'newer']);
  });

  test('can be narrowed to the standing audit', async () => {
    sample('audit_1');
    sample('low_1', { reason: reconciliation.REASONS.LOW_CONFIDENCE });

    const audited = await reconciliation.listPendingSample({
      reason: reconciliation.REASONS.ACCURACY_AUDIT,
    });
    expect(audited.map((p) => p.id)).toEqual(['audit_1']);
  });

  test('excludes what has already been reviewed', async () => {
    reviewed('done', 'correct');
    sample('todo');

    const pending = await reconciliation.listPendingSample({});
    expect(pending.map((p) => p.id)).toEqual(['todo']);
  });

  test('refuses a reason that is not one', async () => {
    await expect(
      reconciliation.listPendingSample({ reason: 'because' }),
    ).rejects.toThrow(/not a sampling reason/i);
  });
});

// ---------------------------------------------------------------------------
// The measured accuracy (EPR-17)
// ---------------------------------------------------------------------------

describe('the accuracy snapshot', () => {
  /** Ids are namespaced by period, so two calls do not overwrite each other. */
  function seedJudged({ correct, incorrect, unclear = 0, periodId = '2026-09' }) {
    let n = 0;
    for (let i = 0; i < correct; i += 1) reviewed(`${periodId}_c${n++}`, 'correct', { periodId });
    for (let i = 0; i < incorrect; i += 1) reviewed(`${periodId}_c${n++}`, 'incorrect', { periodId });
    for (let i = 0; i < unclear; i += 1) reviewed(`${periodId}_c${n++}`, 'unclear', { periodId });
  }

  test('states no precision below the sample floor', async () => {
    // THE DISCIPLINE THIS EXISTS FOR. A precision of "100%" over three reviewed
    // matches is not a measurement, and a methodology section is exactly where
    // an unsupported number does the most damage — it is the section a reader
    // turns to in order to decide how much to trust everything else.
    seedJudged({ correct: 3, incorrect: 0 });

    const snapshot = await reconciliation.accuracySnapshot({ endPeriodId: '2026-09' });

    expect(snapshot.precision).toBeNull();
    expect(snapshot.precisionAbsenceReason).toMatch(/3 sampled matches/);
    expect(snapshot.judged).toBe(3);
  });

  test('states a precision once the sample supports one', async () => {
    seedJudged({ correct: 45, incorrect: 5 });

    const snapshot = await reconciliation.accuracySnapshot({ endPeriodId: '2026-09' });

    expect(snapshot.precision).toBeCloseTo(0.9, 6);
    expect(snapshot.judged).toBe(50);
    expect(snapshot.precisionAbsenceReason).toBeNull();
  });

  test('keeps unclear verdicts out of the ratio', async () => {
    // A photograph too dark to judge is a real outcome. Folding it into either
    // bucket would bias precision in whichever direction the reviewer felt
    // generous.
    seedJudged({ correct: 40, incorrect: 0, unclear: 20 });

    const snapshot = await reconciliation.accuracySnapshot({ endPeriodId: '2026-09' });

    expect(snapshot.precision).toBe(1);
    expect(snapshot.judged).toBe(40);
    expect(snapshot.reviewed).toBe(60);
    // Reported rather than hidden: a high figure here says the photographs are
    // the problem, not the model, and that is a different fix.
    expect(snapshot.unclearShare).toBeCloseTo(1 / 3, 4);
  });

  test('refuses to state a recall figure at all', async () => {
    // EPR-17 names "precision/recall", and only one is observable from a sample
    // drawn from what the model CLAIMED. Nothing here knows what was in a
    // photograph that the model did not report.
    seedJudged({ correct: 45, incorrect: 5 });

    const snapshot = await reconciliation.accuracySnapshot({ endPeriodId: '2026-09' });

    expect(snapshot.recall).toBeNull();
    expect(snapshot.recallAbsenceReason).toMatch(/cannot say what Chokro missed/i);
  });

  test('counts only the standing audit, not the low-confidence queue', async () => {
    // The low-confidence queue holds matches that were NEVER attributed. A
    // reviewer confirming one is telling Chokro about a near-miss, not about
    // the precision of what it reported — mixing them would measure a different
    // thing and call it the same name.
    seedJudged({ correct: 40, incorrect: 0 });
    for (let i = 0; i < 40; i += 1) {
      reviewed(`low${i}`, 'incorrect', {
        reason: reconciliation.REASONS.LOW_CONFIDENCE,
      });
    }

    const snapshot = await reconciliation.accuracySnapshot({ endPeriodId: '2026-09' });
    expect(snapshot.judged).toBe(40);
    expect(snapshot.precision).toBe(1);
  });

  test('reports a trend across the window', async () => {
    seedJudged({ correct: 8, incorrect: 2, periodId: '2026-09' });
    seedJudged({ correct: 5, incorrect: 5, periodId: '2026-08' });

    const snapshot = await reconciliation.accuracySnapshot({ endPeriodId: '2026-09' });

    expect(snapshot.windowPeriods).toHaveLength(reconciliation.ACCURACY_WINDOW_PERIODS);
    expect(snapshot.windowPeriods[0]).toBe('2026-09');

    const september = snapshot.trend.find((t) => t.periodId === '2026-09');
    const august = snapshot.trend.find((t) => t.periodId === '2026-08');
    expect(september.precision).toBeCloseTo(0.8, 4);
    expect(august.precision).toBeCloseTo(0.5, 4);
    // The count sits beside each figure, so a spike on two reviews is visible
    // for what it is.
    expect(september.judged).toBe(10);
  });

  test('excludes periods outside the window', async () => {
    seedJudged({ correct: 40, incorrect: 0, periodId: '2020-01' });

    const snapshot = await reconciliation.accuracySnapshot({ endPeriodId: '2026-09' });
    expect(snapshot.judged).toBe(0);
  });

  test('refuses a period that is not one', async () => {
    await expect(
      reconciliation.accuracySnapshot({ endPeriodId: '2026-9' }),
    ).rejects.toThrow(/reporting period/i);
  });

  test('says nothing rather than zero when nothing has been reviewed', async () => {
    const snapshot = await reconciliation.accuracySnapshot({ endPeriodId: '2026-09' });

    expect(snapshot.reviewed).toBe(0);
    expect(snapshot.precision).toBeNull();
    // Not 0% — which would read as "recognition is never right".
    expect(snapshot.unclearShare).toBeNull();
  });
});

// ---------------------------------------------------------------------------
// Reconciliation (EPR-48, QA-3)
// ---------------------------------------------------------------------------

describe('the reconciliation overview', () => {
  function period(orgId, periodId, over = {}) {
    fs._seed('eprPeriods', `${orgId}_${periodId}`, {
      orgId,
      periodId,
      massMgByCategory: { rigid: 100 * MG },
      attributionCount: 50,
      ...over,
    });
  }

  test('separates matched, mismatched and never-checked', async () => {
    period('org_a', '2026-09', {
      recomputedAt: new Date(), recomputedMassMg: 100 * MG, recomputeMatched: true,
    });
    period('org_b', '2026-09', {
      recomputedAt: new Date(), recomputedMassMg: 140 * MG, recomputeMatched: false,
    });
    period('org_c', '2026-09');

    const overview = await reconciliation.reconciliationOverview({});

    expect(overview.reconciled).toBe(1);
    expect(overview.mismatched).toHaveLength(1);
    expect(overview.mismatched[0].orgId).toBe('org_b');
    expect(overview.mismatched[0].variance).toBe(40 * MG);
    expect(overview.uncheckedCount).toBe(1);
  });

  test('reports the never-checked mass as a total', async () => {
    // THE FIGURE AN AUDITOR ACTUALLY ASKS ABOUT: how much of this has anyone
    // checked? It cannot be read off a list sorted by variance, and the list
    // itself is bounded — so the count and the mass are totals.
    for (let i = 0; i < 60; i += 1) period(`org_${i}`, '2026-09');

    const overview = await reconciliation.reconciliationOverview({});

    expect(overview.uncheckedCount).toBe(60);
    expect(overview.unchecked.length).toBeLessThanOrEqual(50);
    expect(overview.uncheckedMassMg).toBe(60 * 100 * MG);
  });

  test('orders mismatches by magnitude, in either direction', async () => {
    // A period short by 40 kg and one long by 40 kg are equally wrong.
    period('org_small', '2026-09', {
      recomputedAt: new Date(), recomputedMassMg: 105 * MG, recomputeMatched: false,
    });
    period('org_big', '2026-09', {
      recomputedAt: new Date(), recomputedMassMg: 20 * MG, recomputeMatched: false,
    });

    const overview = await reconciliation.reconciliationOverview({});
    expect(overview.mismatched[0].orgId).toBe('org_big');
    expect(overview.mismatched[0].variance).toBe(-80 * MG);
  });

  test('excludes the platform’s unattributed pool', async () => {
    // Not an organisation's period, with no declaration or certificate behind
    // it (EPR-19).
    period('__platform', '2026-09');
    period('org_a', '2026-09');

    const overview = await reconciliation.reconciliationOverview({});
    expect(overview.periodsExamined).toBe(1);
    expect(overview.unchecked.every((p) => p.orgId !== '__platform')).toBe(true);
  });

  test('never overwrites the incremented figure with the recomputed one', async () => {
    // QA-3. Both figures are reported side by side and the reader is told they
    // disagree; the stored counter is left exactly as the increments made it.
    period('org_b', '2026-09', {
      recomputedAt: new Date(), recomputedMassMg: 140 * MG, recomputeMatched: false,
    });

    const overview = await reconciliation.reconciliationOverview({});
    const row = overview.mismatched[0];

    expect(row.incrementedMassMg).toBe(100 * MG);
    expect(row.recomputedMassMg).toBe(140 * MG);
    expect(fs._store.get('eprPeriods/org_b_2026-09').massMgByCategory.rigid)
      .toBe(100 * MG);
  });
});

describe('one organisation’s reconciliation history', () => {
  test('reports a null variance for a period nobody has checked', async () => {
    // Not a zero. Zero means "checked and agreed"; null means "never checked",
    // and conflating them is how an unchecked year looks clean.
    fs._seed('eprPeriods', 'org_a_2026-09', {
      orgId: 'org_a', periodId: '2026-09', massMgByCategory: { rigid: 100 * MG },
    });
    fs._seed('organizations', 'org_a', { tradeName: 'A Ltd' });

    const history = await reconciliation.organizationReconciliation({ orgId: 'org_a' });

    expect(history.tradeName).toBe('A Ltd');
    expect(history.periods[0].variance).toBeNull();
    expect(history.periods[0].matched).toBeNull();
    expect(history.periods[0].recomputedMassMg).toBeNull();
  });
});
