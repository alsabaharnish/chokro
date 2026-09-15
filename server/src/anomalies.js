/**
 * Chokro — the anomaly queue (EPR-45, SEC-3, SEC-12).
 *
 * ===========================================================================
 * A QUEUE, NOT A BLOCK — AND WHAT THAT MEANS FOR THIS FILE
 * ===========================================================================
 *
 * EPR-45 asks for anomaly detection "as an Admin queue rather than an automatic
 * block". Nothing here refuses a disposal, withholds a certificate, changes a
 * figure or suspends anybody. A scan writes findings; an Admin reads them.
 *
 * Which makes the queue's real failure mode noise rather than error. A queue
 * that fills with findings that have an ordinary explanation is one the reader
 * clears without looking, and at that point Chokro believes it is watching and
 * is not. The detectors in `anomalyMath.js` carry deliberate floors for that
 * reason, and this file adds two more: a scan is idempotent per period, so
 * re-running it does not duplicate a finding an Admin has already dismissed,
 * and a dismissal is remembered.
 *
 * ===========================================================================
 * NO SCHEDULER (§3.3)
 * ===========================================================================
 *
 * Admin-triggered, like the recompute. A scan reads a period's attributions in
 * batches and is bounded by construction; there is no background job because
 * this deployment has no way to run one.
 *
 * ===========================================================================
 * ONE DETECTOR NAMES A PERSON
 * ===========================================================================
 *
 * `accountConcentration` reports a Champion's uid, because a single account
 * farming one brand is a real pattern and catching it requires looking at
 * accounts. That makes the whole collection Admin-only: `firestore.rules`
 * denies every producer read, and no route projects a finding to a producer.
 *
 * A producer must never learn that Chokro finds its numbers strange, for two
 * separate reasons. SEC-3, because the finding can name an individual. And
 * because telling the subject of an investigation what triggered it is how the
 * next attempt avoids the trigger.
 */

const crypto = require('crypto');
const { db, admin, serverTimestamp } = require('./firebase');
const audit = require('./producerAudit');
const eprPeriod = require('./eprPeriod');
const eprPeriods = require('./eprPeriods');
const eprPolicy = require('./eprPolicy');
const declarations = require('./declarations');
const anomalyMath = require('./anomalyMath');

const ANOMALIES = 'eprAnomalies';
const ATTRIBUTIONS = 'attributions';
const SKUS = 'producerSkus';
const ORGS = 'organizations';

const BATCH = 500;

/** How many prior periods a trailing baseline reads. */
const TRAILING_PERIODS = 6;

const STATUSES = Object.freeze(['open', 'dismissed', 'actioned']);

/**
 * The separator inside a finding's digest.
 *
 * The unit separator, for the same reason the audit chain uses it: it cannot
 * appear in an orgId, a periodId, a detector name or a subject id, so two
 * different findings cannot collide by concatenation.
 */
const FIELD_SEPARATOR = '';

/**
 * A stable id for a finding.
 *
 * ## Why the id is derived and not random
 *
 * A scan must be re-runnable. An Admin triggers one, an attribution is
 * reversed, the Admin triggers another — and the second scan must not produce a
 * second copy of a finding the first one raised, because a queue that grows on
 * every re-scan is one nobody can work through.
 *
 * So the id is a digest of what the finding IS: organisation, period, detector,
 * subject. Re-running updates the figures in place and leaves the status alone,
 * which is what makes a dismissal stick.
 *
 * The threshold is deliberately NOT in the digest. A finding whose figures
 * crossed a threshold that has since been tuned is the same finding, and
 * including the threshold would resurrect every dismissal the next time
 * somebody adjusted policy.
 */
function findingId({ orgId, periodId, type, subjectId }) {
  return crypto
    .createHash('sha256')
    .update([orgId, periodId, type, subjectId].join(FIELD_SEPARATOR), 'utf8')
    .digest('hex')
    .slice(0, 32);
}

/**
 * Scans one organisation's period and writes what it finds.
 *
 * A detector returning null is the common case, not an error: most SKUs in most
 * periods are unremarkable, and that is what a readable queue looks like.
 */
async function scanPeriod({ orgId, periodId, adminUid, adminName = '' }) {
  if (!eprPeriod.isValidPeriodId(periodId)) {
    throw badRequest('That is not a reporting period.');
  }

  const policy = await eprPolicy.readPolicy();
  const rows = await readAttributions({ orgId, periodId });

  const findings = [
    ...(await skuFindings({ orgId, periodId, rows, policy })),
    ...concentrationFindings({ rows, policy }),
    ...(await targetFindings({ orgId, periodId, policy })),
  ].filter(Boolean);

  const written = await persist({ orgId, periodId, findings, adminUid });

  await audit.append({
    orgId,
    action: audit.ACTIONS.ANOMALY_SCAN,
    actorUid: adminUid,
    actorName: adminName,
    actorRole: 'admin',
    targetType: 'period',
    targetId: periodId,
    summary:
      `Anomaly scan of ${periodId}: ${rows.length} attributions examined, `
      + `${findings.length} finding${findings.length === 1 ? '' : 's'} `
      + `(${written.created} new, ${written.updated} updated).`,
  });

  return {
    orgId,
    periodId,
    attributionsExamined: rows.length,
    findings: findings.length,
    ...written,
  };
}

// ---------------------------------------------------------------------------
// The per-SKU detectors
// ---------------------------------------------------------------------------

async function skuFindings({ orgId, periodId, rows, policy }) {
  const current = new Map();
  for (const row of rows) {
    if (row.reversedAt) continue;
    const entry = current.get(row.skuId) ?? { massMg: 0, matches: 0, medium: 0 };
    entry.massMg += intOr0(row.massMg);
    entry.matches += 1;
    if (row.confidenceTier !== 'high') entry.medium += 1;
    current.set(row.skuId, entry);
  }

  if (current.size === 0) return [];

  const skuIds = [...current.keys()];
  const trailing = await readTrailing({ orgId, periodId, skuIds });
  const comparables = await readCategoryUnitMasses({ orgId, skuIds });

  const findings = [];

  for (const [skuId, entry] of current) {
    const history = trailing.get(skuId) ?? { massMg: [], mediumShare: [] };

    findings.push(
      anomalyMath.skuMassSpike({
        skuId,
        currentMassMg: entry.massMg,
        trailingMassMg: history.massMg,
        multiple: policy.anomalySkuMassMultiple,
      }),
    );

    findings.push(
      anomalyMath.confidenceDrift({
        skuId,
        currentMediumShare: entry.matches > 0 ? entry.medium / entry.matches : 0,
        trailingMediumShare: history.mediumShare,
        driftThreshold: policy.anomalyConfidenceDrift,
        currentMatches: entry.matches,
      }),
    );

    const comparison = comparables.get(skuId);
    if (comparison) {
      findings.push(
        anomalyMath.unitMassOutlier({
          skuId,
          declaredUnitMassMg: comparison.unitMassMg,
          comparableUnitMassesMg: comparison.peers,
          iqrMultiple: policy.anomalyUnitMassIqrMultiple,
        }),
      );
    }
  }

  return findings;
}

/**
 * Bin and account concentration, from one pass.
 *
 * Both read the whole period's rows, so they share a traversal — the rows are
 * already in memory and a second pass buys nothing.
 */
function concentrationFindings({ rows, policy }) {
  const byBin = new Map();
  const byAccount = new Map();
  let total = 0;

  for (const row of rows) {
    if (row.reversedAt) continue;
    const mass = intOr0(row.massMg);
    total += mass;

    if (row.binId) byBin.set(row.binId, (byBin.get(row.binId) ?? 0) + mass);
    // The disposing account. Present on the attribution because reconciliation
    // needs it; never projected to a producer.
    if (row.disposedBy) {
      byAccount.set(row.disposedBy, (byAccount.get(row.disposedBy) ?? 0) + mass);
    }
  }

  if (total <= 0) return [];

  const findings = [];

  for (const [binId, binMassMg] of byBin) {
    findings.push(
      anomalyMath.binConcentration({
        binId,
        binMassMg,
        totalMassMg: total,
        binCount: byBin.size,
        shareThreshold: policy.anomalyBinShare,
      }),
    );
  }

  for (const [accountId, accountMassMg] of byAccount) {
    findings.push(
      anomalyMath.accountConcentration({
        accountId,
        accountMassMg,
        totalMassMg: total,
        accountCount: byAccount.size,
        shareThreshold: policy.anomalyAccountShare,
      }),
    );
  }

  return findings;
}

/**
 * The target-edge detector, which needs the declaration's filing time.
 *
 * Measured against the period's own close in Asia/Dhaka, never against "now" —
 * a scan run in December must give the same answer about September that a scan
 * run in October did, or the queue is not reproducible.
 */
async function targetFindings({ orgId, periodId, policy }) {
  const [period, declaration, orgSnap] = await Promise.all([
    eprPeriods.getPeriod({ orgId, periodId }),
    declarations.getDeclaration({ orgId, periodId }),
    db().collection(ORGS).doc(orgId).get(),
  ]);

  if (!declaration || declaration.status !== 'submitted') return [];
  if (!orgSnap.exists) return [];

  const attestedAt = declaration.attestedAt?.toDate?.() ?? null;
  if (!attestedAt) return [];

  const collectedMassMg = Object.values(period?.massMgByCategory ?? {}).reduce(
    (sum, mg) => sum + intOr0(mg),
    0,
  );
  const declaredMassMg = intOr0(declaration.totalMassMg);
  if (declaredMassMg <= 0) return [];

  // `passports.js` owns this arithmetic, so it is required rather than
  // duplicated — and required lazily, because `passports` requires
  // `eprPeriods` and a top-level require here would close a cycle.
  // eslint-disable-next-line global-require
  const passports = require('./passports');
  const obligationYear = passports.obligationYearAt(orgSnap.data(), periodId);
  if (obligationYear === null) return [];

  const closesAt = eprPeriod.periodEndUtc(periodId);
  const daysBeforeClose = Math.floor(
    (closesAt.getTime() - attestedAt.getTime()) / (24 * 60 * 60 * 1000),
  );

  // A declaration filed AFTER the period closed is the ordinary case, and is
  // not what this detector is about.
  if (daysBeforeClose < 0) return [];

  return [
    anomalyMath.targetEdge({
      periodId,
      collectionRate: collectedMassMg / declaredMassMg,
      applicableTarget: obligationYear >= 3 ? 0.3 : 0.15,
      declarationFiledDaysBeforeClose: daysBeforeClose,
      marginThreshold: policy.anomalyTargetMargin,
      daysThreshold: policy.anomalyTargetFilingDays,
    }),
  ];
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/** One period's attributions, in batches, ordered so paging terminates. */
async function readAttributions({ orgId, periodId }) {
  const rows = [];
  let cursor = null;

  for (;;) {
    let query = db()
      .collection(ATTRIBUTIONS)
      .where('orgId', '==', orgId)
      .where('periodId', '==', periodId)
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(BATCH);

    if (cursor) query = query.startAfter(cursor);

    const snap = await query.get();
    if (snap.empty) break;

    for (const doc of snap.docs) rows.push({ id: doc.id, ...doc.data() });
    cursor = snap.docs[snap.docs.length - 1].id;

    if (snap.size < BATCH) break;
  }

  return rows;
}

/**
 * Per-SKU trailing mass and confidence mix, from the prior periods.
 *
 * A period in which a SKU was not collected contributes a ZERO to the mass
 * history — it genuinely is part of the trailing average, and dropping it would
 * make a sporadic product look like a steady one and then flag its next
 * appearance as a spike.
 *
 * It contributes NOTHING to the confidence history, because a period with no
 * matches has no mix to average and a zero there would read as perfect
 * recognition.
 */
async function readTrailing({ orgId, periodId, skuIds }) {
  const out = new Map(skuIds.map((id) => [id, { massMg: [], mediumShare: [] }]));

  const periods = [];
  let cursor = periodId;
  for (let i = 0; i < TRAILING_PERIODS; i += 1) {
    cursor = eprPeriod.previousPeriodId(cursor);
    periods.push(cursor);
  }

  for (const prior of periods) {
    const snap = await db()
      .collection(ATTRIBUTIONS)
      .where('orgId', '==', orgId)
      .where('periodId', '==', prior)
      .limit(BATCH)
      .get();

    const bySku = new Map();
    for (const doc of snap.docs) {
      const row = doc.data();
      if (row.reversedAt) continue;
      const entry = bySku.get(row.skuId) ?? { massMg: 0, matches: 0, medium: 0 };
      entry.massMg += intOr0(row.massMg);
      entry.matches += 1;
      if (row.confidenceTier !== 'high') entry.medium += 1;
      bySku.set(row.skuId, entry);
    }

    for (const skuId of skuIds) {
      const entry = bySku.get(skuId);
      out.get(skuId).massMg.push(entry ? entry.massMg : 0);
      if (entry && entry.matches > 0) {
        out.get(skuId).mediumShare.push(entry.medium / entry.matches);
      }
    }
  }

  return out;
}

/**
 * Each SKU's unit mass, and the unit masses of comparable products.
 *
 * "Comparable" is the same gazette category across ALL producers, which is the
 * only way the comparison means anything — a single producer's catalogue is not
 * a distribution.
 *
 * That crosses a tenancy boundary deliberately. The comparison set is read
 * Admin-side, never projected anywhere, and only summary statistics of it reach
 * a finding: a median and two quartiles. No producer learns another producer's
 * unit masses, and no finding carries a competitor's product.
 */
async function readCategoryUnitMasses({ orgId, skuIds }) {
  const out = new Map();
  if (skuIds.length === 0) return out;

  const mine = await readSkus(skuIds);
  const categories = new Set(
    [...mine.values()]
      .filter((sku) => sku.orgId === orgId)
      .map((sku) => sku.gazetteCategory)
      .filter(Boolean),
  );

  const peersByCategory = new Map();
  for (const category of categories) {
    const snap = await db()
      .collection(SKUS)
      .where('gazetteCategory', '==', category)
      .where('massStatus', '==', 'verified')
      .limit(200)
      .get();

    peersByCategory.set(
      category,
      snap.docs
        .map((d) => intOr0(d.data().verifiedUnitMassMg))
        .filter((mg) => mg > 0),
    );
  }

  for (const [skuId, sku] of mine) {
    if (sku.orgId !== orgId) continue;
    const unitMassMg = intOr0(sku.verifiedUnitMassMg);
    if (unitMassMg <= 0 || !sku.gazetteCategory) continue;

    const peers = [...(peersByCategory.get(sku.gazetteCategory) ?? [])];
    // The SKU is excluded from its own comparison set: a product cannot be an
    // outlier from a distribution it is helping to define, and in a small
    // category it would pull the fence toward itself. One occurrence removed,
    // not every equal value — another producer's product of the same mass is a
    // legitimate peer.
    const self = peers.indexOf(unitMassMg);
    if (self !== -1) peers.splice(self, 1);

    out.set(skuId, { unitMassMg, peers });
  }

  return out;
}

async function readSkus(skuIds) {
  const out = new Map();
  const unique = [...new Set(skuIds.filter(Boolean))].sort();

  for (let i = 0; i < unique.length; i += 10) {
    const snap = await db()
      .collection(SKUS)
      .where(admin.firestore.FieldPath.documentId(), 'in', unique.slice(i, i + 10))
      .get();
    for (const doc of snap.docs) out.set(doc.id, doc.data());
  }

  return out;
}

// ---------------------------------------------------------------------------
// The queue
// ---------------------------------------------------------------------------

/**
 * Writes findings, without resurrecting dismissals.
 *
 * A re-scan updates a finding's figures and leaves its status alone. An Admin
 * who looked at a concentration and decided it was a bottling plant should not
 * have to decide it again every time somebody triggers a scan.
 */
async function persist({ orgId, periodId, findings, adminUid }) {
  const firestore = db();
  let created = 0;
  let updated = 0;

  for (const finding of findings) {
    const id = findingId({
      orgId,
      periodId,
      type: finding.type,
      subjectId: finding.subjectId,
    });
    const ref = firestore.collection(ANOMALIES).doc(id);
    const existing = await ref.get();

    if (existing.exists) {
      await ref.update({
        figures: finding.figures,
        summary: finding.summary,
        severity: finding.severity,
        lastSeenAt: serverTimestamp(),
        lastScanBy: adminUid,
        // `status` and `dismissedReason` are deliberately absent. A re-scan
        // refreshes what the finding SAYS, never whether it has been dealt
        // with.
      });
      updated += 1;
      continue;
    }

    await ref.set({
      id,
      orgId,
      periodId,
      type: finding.type,
      subjectType: finding.subjectType,
      subjectId: finding.subjectId,
      severity: finding.severity,
      figures: finding.figures,
      summary: finding.summary,
      status: 'open',
      dismissedBy: null,
      dismissedAt: null,
      dismissedReason: null,
      firstSeenAt: serverTimestamp(),
      lastSeenAt: serverTimestamp(),
      lastScanBy: adminUid,
      createdAt: serverTimestamp(),
    });
    created += 1;
  }

  return { created, updated };
}

/** The queue, newest first. Admin-only — see the module comment. */
async function listQueue({ status = 'open', orgId = null, limit = 50 }) {
  if (!STATUSES.includes(status)) {
    throw badRequest(`An anomaly is ${STATUSES.join(', ')} — not "${status}".`);
  }

  let query = db().collection(ANOMALIES).where('status', '==', status);
  if (orgId) query = query.where('orgId', '==', orgId);

  const snap = await query.orderBy('firstSeenAt', 'desc').limit(limit).get();
  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

/**
 * Closes a finding, with a reason.
 *
 * A reason is required for the same reason every other override in this system
 * requires one: a dismissal with no stated basis is indistinguishable from an
 * insider clearing the queue (SEC-12), and the audit entry is what makes the
 * difference visible afterwards.
 *
 * Two outcomes rather than one. "Dismissed" means the finding had an innocent
 * explanation; "actioned" means it did not and something was done. Collapsing
 * them would make the queue's own history useless for the question an auditor
 * actually asks — how many of these turned out to be real.
 */
async function dismiss({ id, reason, outcome = 'dismissed', adminUid, adminName = '' }) {
  if (typeof reason !== 'string' || reason.trim().length < 5) {
    throw badRequest('Record why this finding is being closed.');
  }
  if (!['dismissed', 'actioned'].includes(outcome)) {
    throw badRequest('An anomaly is either dismissed or actioned.');
  }

  const ref = db().collection(ANOMALIES).doc(id);
  const snap = await ref.get();
  if (!snap.exists) throw badRequest('That finding does not exist.');

  const finding = snap.data();
  if (finding.status !== 'open') {
    throw conflict('That finding has already been closed.');
  }

  await audit.append({
    orgId: finding.orgId,
    action: audit.ACTIONS.ANOMALY_DISMISSED,
    actorUid: adminUid,
    actorName: adminName,
    actorRole: 'admin',
    targetType: 'anomaly',
    targetId: id,
    summary:
      `${finding.type} on ${finding.subjectType} ${finding.subjectId} `
      + `(${finding.periodId}) ${outcome}: ${reason.trim()}`,
    before: { status: 'open' },
    after: { status: outcome },
  });

  await ref.update({
    status: outcome,
    dismissedBy: adminUid,
    dismissedAt: serverTimestamp(),
    dismissedReason: reason.trim().slice(0, 500),
  });

  return { id, status: outcome };
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
  ANOMALIES,
  STATUSES,
  TRAILING_PERIODS,
  FIELD_SEPARATOR,
  findingId,
  scanPeriod,
  listQueue,
  dismiss,
  concentrationFindings,
  readTrailing,
  readCategoryUnitMasses,
};
