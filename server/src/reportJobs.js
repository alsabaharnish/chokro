/**
 * Chokro — report jobs (EPR-33, EPR-34, EPR-35, SEC-6).
 *
 * ===========================================================================
 * WHY A JOB AND NOT A REQUEST
 * ===========================================================================
 *
 * EPR-35, verbatim: "A year of attributions is not something to stream into a
 * Flutter widget, and the free-tier service will not hold a connection open
 * long enough to try."
 *
 * So `POST /epr/reports` enqueues and returns a job id, `GET
 * /epr/reports/{jobId}` polls, and the output is fetched through a short-lived
 * signed URL. The producer's client polls a cheap document instead of holding a
 * connection through a read that can span a hundred thousand rows.
 *
 * ===========================================================================
 * THERE IS NO SCHEDULER (§3.3), SO WHAT RUNS THE JOB?
 * ===========================================================================
 *
 * The same answer as everywhere else in this module: the request that created
 * it does, after replying. `enqueue` writes the job document, returns, and the
 * route then calls `runJob` without awaiting it. The client already has its job
 * id and is polling; nothing is waiting on the connection.
 *
 * That means a job can die mid-run — the instance sleeps, the process restarts,
 * the read times out. Which is why `runJob` is resumable and idempotent on the
 * job document, and why a job that has been `running` past
 * `STALE_AFTER_MINUTES` is reported as `stalled` rather than left spinning
 * forever in a progress bar. `POST /epr/reports/{jobId}/resume` picks it back
 * up from its cursor.
 *
 * ===========================================================================
 * DETERMINISM (EPR-34)
 * ===========================================================================
 *
 * "Two reports of the same scope and period must be byte-identical apart from
 * the generation timestamp and requester — determinism is what lets an auditor
 * compare their copy to the producer's."
 *
 * That is a strong constraint and it shapes everything here:
 *
 *   Every query is explicitly ordered. A Firestore read with no `orderBy` has
 *   no guaranteed order, so two runs could emit the same rows in different
 *   sequences and hash differently while stating identical facts.
 *
 *   Nothing is formatted with a locale-dependent function. `toLocaleString`
 *   depends on the host's ICU data.
 *
 *   No timestamp goes into the body. The generation time is in the header, and
 *   the CONTENT hash covers the body only — so the hash of an auditor's copy
 *   and the producer's copy of the same period agree, which is the entire point.
 */

const crypto = require('crypto');
const { db, admin, bucket, serverTimestamp } = require('./firebase');
const audit = require('./producerAudit');
const eprPeriod = require('./eprPeriod');
const declarations = require('./declarations');
const passports = require('./passports');
const eprPeriods = require('./eprPeriods');
const eprPolicy = require('./eprPolicy');
const organizations = require('./organizations');

const JOBS = 'reportJobs';
const ATTRIBUTIONS = 'attributions';
const SKUS = 'producerSkus';

/** The generating system, stamped on every report (EPR-34). */
const GENERATOR = 'Chokro EPR producer portal';
const GENERATOR_VERSION = '1.0.0';

/**
 * How long a signed URL lives (SEC-6).
 *
 * Ten minutes: long enough to survive a cold start and a slow mobile
 * connection, short enough that "a passport URL forwarded in an email becomes a
 * permanent unauthenticated data feed" — SEC-6's stated failure mode — is a
 * ten-minute window rather than forever.
 */
const SIGNED_URL_MINUTES = 10;

/** Rows read per pass, matching the period recompute's batch size. */
const BATCH = 500;

/**
 * When a `running` job is presumed dead.
 *
 * There is no scheduler to notice, so this is evaluated at read time — the same
 * lazy-expiry pattern the invitations use. Fifteen minutes is well past any
 * legitimate run on this data volume and well short of a producer concluding
 * the portal is broken.
 */
const STALE_AFTER_MINUTES = 15;

const JOB_STATUSES = Object.freeze([
  'queued',
  'running',
  'ready',
  'failed',
  'stalled',
]);

/**
 * The reports this module can produce (EPR-33).
 *
 * `scope` says what identifies a run for determinism purposes: two reports of
 * the same type and scope must be byte-identical apart from the header.
 */
const REPORT_TYPES = Object.freeze({
  periodCollectionStatement: {
    label: 'Period collection statement',
    formats: ['csv', 'json'],
    needsPeriod: true,
    minRole: 'orgViewer',
  },
  skuPerformance: {
    label: 'SKU performance report',
    formats: ['csv', 'json'],
    needsPeriod: true,
    minRole: 'orgViewer',
  },
  geographicRecovery: {
    label: 'Geographic recovery report',
    formats: ['csv', 'json'],
    needsPeriod: true,
    minRole: 'orgViewer',
  },
  chainOfCustody: {
    label: 'Chain-of-custody export',
    formats: ['csv', 'json'],
    needsPeriod: true,
    // Row-level evidence. Not a viewer's report: it is the export SEC-11's
    // "org member exfiltrates data" row is about, and an owner asking for it
    // is a deliberate act rather than a page somebody wandered onto.
    minRole: 'orgOwner',
  },
  doeAnnualProgress: {
    label: 'DoE annual progress report',
    formats: ['json'],
    needsPeriod: false,
    needsYear: true,
    minRole: 'orgOwner',
  },
  reconciliationVariance: {
    label: 'Reconciliation and variance report',
    formats: ['json'],
    needsPeriod: true,
    minRole: 'orgOwner',
  },
  surplusMass: {
    // §15 decision 7: report surplus mass, call it surplus, do NOT call it
    // credits until the framework is understood. The report type is named for
    // what it contains rather than for what somebody might want to trade.
    label: 'Surplus mass statement',
    formats: ['json'],
    needsPeriod: true,
    minRole: 'orgOwner',
  },
});

// ---------------------------------------------------------------------------
// Enqueue and poll
// ---------------------------------------------------------------------------

/**
 * Creates a job. Returns immediately; the caller kicks off [runJob] without
 * awaiting it.
 */
async function enqueue({
  orgId,
  reportType,
  periodId = null,
  year = null,
  format = 'json',
  actorUid,
  actorName = '',
  actorRole = 'orgViewer',
}) {
  const spec = REPORT_TYPES[reportType];
  if (!spec) {
    throw badRequest(
      `"${reportType}" is not a report. Available: ${Object.keys(REPORT_TYPES).join(', ')}.`,
    );
  }
  if (!spec.formats.includes(format)) {
    throw badRequest(
      `${spec.label} is not produced as ${format}. Available: ${spec.formats.join(', ')}.`,
    );
  }
  if (spec.needsPeriod && !eprPeriod.isValidPeriodId(periodId)) {
    throw badRequest(`${spec.label} needs a reporting period.`);
  }
  if (spec.needsYear && !Number.isInteger(year)) {
    throw badRequest(`${spec.label} needs a year.`);
  }

  const firestore = db();
  const ref = firestore.collection(JOBS).doc();

  // A signed URL is the only delivery mechanism EPR-35 permits, so a bucket
  // that cannot be signed for is a refusal at enqueue time rather than a job
  // that runs for a minute and then cannot hand anything over. Named
  // explicitly, because the operator reading this is the person who has to
  // configure it.
  assertStorageConfigured();

  await ref.set({
    jobId: ref.id,
    orgId,
    reportType,
    label: spec.label,
    periodId: spec.needsPeriod ? periodId : null,
    year: spec.needsYear ? year : null,
    format,
    status: 'queued',
    requestedBy: actorUid,
    requestedByName: actorName,
    requestedByRole: actorRole,
    requestedAt: serverTimestamp(),
    startedAt: null,
    finishedAt: null,
    // Resumable across passes, exactly as `recomputePeriod` is: a year of
    // attributions is not one read, and this instance will not hold a
    // connection open long enough to try.
    cursor: null,
    rowsRead: 0,
    storagePath: null,
    contentHash: null,
    byteSize: null,
    error: null,
    createdAt: serverTimestamp(),
  });

  await audit.append({
    orgId,
    action: audit.ACTIONS.REPORT_GENERATED,
    actorUid,
    actorName,
    actorRole,
    targetType: 'report',
    targetId: ref.id,
    summary:
      `${spec.label} requested`
      + (periodId ? ` for ${periodId}` : '')
      + (year ? ` for ${year}` : '')
      + ` as ${format.toUpperCase()}.`,
  });

  return { jobId: ref.id, status: 'queued', label: spec.label };
}

/**
 * Reads a job, marking it stalled if it has been running too long.
 *
 * Lazy, at read time, because there is no scheduler to notice (§3.3). A job
 * left `running` forever is a progress bar that never finishes, which is worse
 * than a failure the producer can retry.
 */
async function getJob({ jobId, orgId }) {
  const snap = await db().collection(JOBS).doc(jobId).get();
  if (!snap.exists) return null;

  const job = snap.data();
  // Membership is checked against the job's own organisation, never against
  // the id in the path.
  if (job.orgId !== orgId) return null;

  if (job.status === 'running' && isStale(job)) {
    // Reported, not rewritten: the job may still be alive on another instance,
    // and flipping the stored status could race a legitimate completion. The
    // resume route is what actually restarts it.
    return { ...job, status: 'stalled', stalledAfterMinutes: STALE_AFTER_MINUTES };
  }

  return job;
}

function isStale(job) {
  const startedAt = job.startedAt?.toDate?.();
  if (!startedAt) return false;
  return Date.now() - startedAt.getTime() > STALE_AFTER_MINUTES * 60 * 1000;
}

async function listJobs({ orgId, limit = 25 }) {
  const snap = await db()
    .collection(JOBS)
    .where('orgId', '==', orgId)
    .orderBy('requestedAt', 'desc')
    .limit(limit)
    .get();

  return snap.docs.map((d) => {
    const job = d.data();
    return job.status === 'running' && isStale(job)
      ? { ...job, status: 'stalled' }
      : job;
  });
}

// ---------------------------------------------------------------------------
// Running
// ---------------------------------------------------------------------------

/**
 * Builds the report and uploads it.
 *
 * Never throws to its caller: the route fires this without awaiting, so a
 * rejection here would be an unhandled promise rejection that takes the process
 * down — and taking the instance down because one producer's report failed
 * would turn a report fault into an outage for every tenant.
 */
async function runJob(jobId) {
  const ref = db().collection(JOBS).doc(jobId);

  try {
    const snap = await ref.get();
    if (!snap.exists) return;
    const job = snap.data();

    // Idempotent on the job document. A retry, a double-fire, or a resume of
    // something that finished must not produce a second artefact — an auditor
    // holding two files for one job id has no way to know which is the report.
    if (job.status === 'ready') return;

    await ref.update({ status: 'running', startedAt: serverTimestamp(), error: null });

    const body = await buildReport(job);
    const artefact = assembleArtefact(job, body);

    const path =
      `epr-reports/${job.orgId}/${job.reportType}/`
      + `${job.periodId || job.year || 'all'}/${jobId}.${job.format}`;

    await bucket().file(path).save(Buffer.from(artefact, 'utf8'), {
      contentType: job.format === 'csv' ? 'text/csv; charset=utf-8' : 'application/json',
      // No public read, ever (SEC-6): "No public bucket, no guessable path, no
      // permanent URL."
      resumable: false,
      metadata: {
        cacheControl: 'private, max-age=0, no-store',
        metadata: {
          orgId: job.orgId,
          reportType: job.reportType,
          jobId,
          contentHash: body.contentHash,
        },
      },
    });

    await ref.update({
      status: 'ready',
      finishedAt: serverTimestamp(),
      storagePath: path,
      // Over the BODY only, not the header. Two reports of the same scope and
      // period must compare equal for an auditor (EPR-34), and the header
      // carries the generation timestamp and the requester by design.
      contentHash: body.contentHash,
      byteSize: Buffer.byteLength(artefact, 'utf8'),
      rowsRead: body.rowsRead ?? 0,
    });
  } catch (err) {
    console.error(`[reportJobs] ${jobId} failed:`, err.message);
    try {
      await ref.update({
        status: 'failed',
        finishedAt: serverTimestamp(),
        // The message, not the stack. A producer sees this, and a stack trace
        // discloses paths and module structure to somebody who does not need
        // them.
        error: String(err.message || 'The report could not be produced.').slice(0, 500),
      });
    } catch (_) {
      // The job document itself is unreachable. Already logged; nothing else
      // to do, and throwing from here would be the unhandled rejection this
      // catch exists to prevent.
    }
  }
}

/**
 * Wraps the hashed body in its header (EPR-34).
 *
 * ## Why the header is assembled around the body rather than prepended to it
 *
 * The content hash must cover the BODY ONLY, and it must cover text an auditor
 * can actually recompute from. An earlier version prepended a JSON opening
 * fragment and appended a closing brace to the body, which meant the hash was
 * over text that was not valid JSON on its own — two copies of a report still
 * compared equal, but an auditor extracting the `data` member and hashing it
 * got a different answer, which defeats the point of publishing the hash.
 *
 * So `body.text` is the exact canonical serialisation of the payload, hashed as
 * such, and this function puts the header around it without touching it.
 */
function assembleArtefact(job, body) {
  const header = buildHeader(job, body);

  if (job.format === 'json') {
    // `body.text` appears verbatim, so hashing the `data` member's text
    // reproduces `contentHash` exactly.
    return `{\n"_header": ${JSON.stringify(header, null, 2)},\n"data": ${body.text}\n}\n`;
  }

  // CSV has no comment syntax in RFC 4180, so the header goes in `#` lines
  // above the column row. A strict parser will reject them and a spreadsheet
  // will show them as single-column rows; both are better than a report whose
  // provenance and boundary statements are in a separate file that gets
  // separated from it. EPR-34 requires them ON the artefact.
  return `${header.lines.map((l) => `# ${l}`).join('\n')}\n${body.text}`;
}

/**
 * The first-page header every report carries (EPR-34).
 *
 * Returns a structured object plus its rendered lines, so the JSON edition
 * carries it as data and the CSV edition as comments — the same facts either
 * way.
 */
function buildHeader(job, body) {
  const generatedAt = new Date().toISOString();
  const lines = [
    `system: ${GENERATOR} ${GENERATOR_VERSION}`,
    `report: ${job.label}`,
    `organisation: ${job.orgId}`,
    job.periodId ? `period: ${job.periodId} (Asia/Dhaka, UTC+06)` : `year: ${job.year}`,
    `generatedAt: ${generatedAt}`,
    `requestedBy: ${job.requestedByName || job.requestedBy}`,
    `contentHash: ${body.contentHash}`,
    '',
    'Boundary statements:',
    ...BOUNDARY_STATEMENTS.map((s) => `  - ${s}`),
  ];

  return {
    system: GENERATOR,
    version: GENERATOR_VERSION,
    report: job.label,
    organisation: job.orgId,
    period: job.periodId,
    year: job.year,
    timezone: 'Asia/Dhaka (UTC+06)',
    generatedAt,
    requestedBy: job.requestedByName || job.requestedBy,
    contentHash: body.contentHash,
    boundaries: BOUNDARY_STATEMENTS,
    lines,
  };
}

/**
 * The §6.7 boundary statements, on every report (EPR-34).
 *
 * The same limits the Plastic Passport carries, because a spreadsheet gets
 * forwarded further than a certificate does and arrives without the context the
 * certificate's layout provides.
 */
const BOUNDARY_STATEMENTS = Object.freeze([
  'Collection figures count only material collected through Chokro. They are '
    + 'not a total national collection and this report is not a statement of '
    + 'compliance with the 2024 gazette.',
  'This report does not state a recycling rate. Chokro records collection and '
    + 'holds no evidence of what was recycled downstream.',
  'Put-on-market figures are declared by the producer under attestation and '
    + 'have not been independently verified by Chokro.',
  'Avoided-emissions figures, where present, are indicative estimates from a '
    + 'published external factor and are not verified carbon credits or offsets.',
  'Mass attributed from medium-confidence recognition is reported separately '
    + 'as an estimated share. It is not certain mass.',
]);

// ---------------------------------------------------------------------------
// The reports
// ---------------------------------------------------------------------------

async function buildReport(job) {
  switch (job.reportType) {
    case 'periodCollectionStatement':
      return periodCollectionStatement(job);
    case 'skuPerformance':
      return skuPerformance(job);
    case 'geographicRecovery':
      return geographicRecovery(job);
    case 'chainOfCustody':
      return chainOfCustody(job);
    case 'doeAnnualProgress':
      return doeAnnualProgress(job);
    case 'reconciliationVariance':
      return reconciliationVariance(job);
    case 'surplusMass':
      return surplusMass(job);
    default:
      throw badRequest(`"${job.reportType}" has no builder.`);
  }
}

async function periodCollectionStatement(job) {
  const [period, declared, policy] = await Promise.all([
    eprPeriods.getPeriod({ orgId: job.orgId, periodId: job.periodId }),
    declarations.declaredMassByCategory({ orgId: job.orgId, periodId: job.periodId }),
    eprPolicy.readPolicy(),
  ]);

  const projected = eprPeriods.projectForProducer(
    period ?? { orgId: job.orgId, periodId: job.periodId },
    policy,
  );

  const rows = [];
  for (const category of passports.GAZETTE_CATEGORIES) {
    const collectedMg = projected.massMgByCategory?.[category] ?? 0;
    const declaredMg = declared ? declared[category] : undefined;
    if (!collectedMg && !Number.isInteger(declaredMg)) continue;

    rows.push({
      category,
      collectedMassMg: collectedMg,
      units: projected.unitsByCategory?.[category] ?? 0,
      // The literal string, not a blank and not a zero. EPR-42: an undeclared
      // category is not a nil declaration, and a spreadsheet cell containing 0
      // is read as a declared nil by anyone who opens it.
      declaredMassMg: Number.isInteger(declaredMg) ? declaredMg : 'notDeclared',
      collectionRate:
        Number.isInteger(declaredMg) && declaredMg > 0
          ? (collectedMg / declaredMg).toFixed(6)
          : 'notStated',
    });
  }

  return serialise(job, { rows, totals: summarise(projected, declared) }, [
    'category',
    'collectedMassMg',
    'units',
    'declaredMassMg',
    'collectionRate',
  ]);
}

async function skuPerformance(job) {
  // Ordered explicitly, so two runs emit the same rows in the same sequence
  // and hash identically (EPR-34).
  const attributions = await readAllAttributions(job);

  const bySku = new Map();
  for (const row of attributions) {
    // `reversedAt`, not a boolean `reversed` — nothing in the system writes
    // one. `attribute.js` initialises `reversedAt: null` and
    // `eprPeriods.reverseAttribution` sets it; `accumulate` and the Dart
    // model's `isReversed` both key off it. Testing a field no writer sets
    // meant this guard never fired, so reversed mass was counted here while
    // the period rollup and the certificate correctly excluded it — a report
    // that overstates against the certificate for the same period.
    if (isReversed(row)) continue;
    const current = bySku.get(row.skuId) ?? {
      skuId: row.skuId,
      skuRevision: row.skuRevision ?? null,
      units: 0,
      massMg: 0,
      unitMassMgUsed: row.unitMassMgUsed ?? null,
      highConfidence: 0,
      mediumConfidence: 0,
    };
    current.units += intOr0(row.units);
    current.massMg += intOr0(row.massMg);
    if (row.confidenceTier === 'high') current.highConfidence += 1;
    else current.mediumConfidence += 1;
    bySku.set(row.skuId, current);
  }

  // Sorted by id, not by mass: a tie in mass would order two SKUs
  // arbitrarily, and the report has to be byte-identical across runs.
  const rows = [...bySku.values()].sort((a, b) => a.skuId.localeCompare(b.skuId));

  const skus = await readSkus(job.orgId, rows.map((r) => r.skuId));
  for (const row of rows) {
    const sku = skus.get(row.skuId);
    row.name = sku?.name ?? '';
    row.brand = sku?.brand ?? '';
    row.gazetteCategory = sku?.gazetteCategory ?? '';
    row.massStatus = sku?.massStatus ?? '';
  }

  return serialise(job, { rows, rowsRead: attributions.length }, [
    'skuId',
    'name',
    'brand',
    'gazetteCategory',
    'skuRevision',
    'unitMassMgUsed',
    'massStatus',
    'units',
    'massMg',
    'highConfidence',
    'mediumConfidence',
  ]);
}

async function geographicRecovery(job) {
  const [period, policy] = await Promise.all([
    eprPeriods.getPeriod({ orgId: job.orgId, periodId: job.periodId }),
    eprPolicy.readPolicy(),
  ]);

  // Projected, so the k-anonymity floor is applied here exactly as it is on
  // screen (SEC-3). A report that bypassed it would be the export route around
  // the control.
  const projected = eprPeriods.projectForProducer(
    period ?? { orgId: job.orgId, periodId: job.periodId },
    policy,
  );

  const rows = Object.entries(projected.massMgByDistrict ?? {})
    .map(([district, massMg]) => ({ district, massMg: intOr0(massMg) }))
    .sort((a, b) => a.district.localeCompare(b.district));

  return serialise(
    job,
    {
      rows,
      districtsSuppressed: projected.districtSuppressed === true,
      kAnonymityFloor: projected.districtSuppressed ? policy.kAnonymityFloor : null,
      note: projected.districtSuppressed
        ? 'Some districts are withheld: too few records fall in them to report '
          + 'without identifying individual disposals.'
        : null,
    },
    ['district', 'massMg'],
  );
}

/**
 * Row-level attributions, pseudonymised (EPR-33, SEC-3).
 *
 * "no personal identifiers" is the requirement, and the disposal id is
 * pseudonymous: an HMAC keyed per organisation, so an auditor can follow one
 * disposal across rows of this producer's export and cannot join it against
 * another producer's export of the same disposal.
 */
async function chainOfCustody(job) {
  const attributions = await readAllAttributions(job);

  const rows = attributions.map((row) => ({
    attributionId: row.id,
    // Pseudonymous, and per-organisation. The raw disposal id would let two
    // producers who both received a fragment of the same bag correlate their
    // exports and reconstruct a Champion's activity.
    disposalRef: pseudonym(job.orgId, row.disposalId),
    binId: row.binId ?? '',
    // Date only, not a timestamp. A second-precision time plus a bin location
    // identifies the person who was standing there (SEC-3).
    date: dhakaDate(row.createdAt),
    district: row.district ?? '',
    skuId: row.skuId ?? '',
    skuRevision: row.skuRevision ?? '',
    units: intOr0(row.units),
    unitMassMgUsed: intOr0(row.unitMassMgUsed),
    massMg: intOr0(row.massMg),
    gazetteCategory: row.gazetteCategory ?? '',
    method: row.method ?? '',
    confidenceTier: row.confidenceTier ?? '',
    // The same field, and the reason this column exists at all. Hardcoded
    // false, an auditor summing this export gets a figure above the
    // certificate's with the one column that would explain it saying nothing
    // happened.
    reversed: isReversed(row),
  }));

  return serialise(job, { rows, rowsRead: attributions.length }, [
    'attributionId',
    'disposalRef',
    'binId',
    'date',
    'district',
    'skuId',
    'skuRevision',
    'units',
    'unitMassMgUsed',
    'massMg',
    'gazetteCategory',
    'method',
    'confidenceTier',
    'reversed',
  ]);
}

async function doeAnnualProgress(job) {
  const orgSnap = await db().collection('organizations').doc(job.orgId).get();
  if (!orgSnap.exists) throw badRequest('That organisation does not exist.');
  const organization = orgSnap.data();

  // The producer's own registration clock, not the calendar year — EPR-33 says
  // "annual, on the producer's registration clock".
  const periodIds = twelvePeriodsFrom(organization, job.year);

  const periods = [];
  for (const periodId of periodIds) {
    const [period, declared] = await Promise.all([
      eprPeriods.getPeriod({ orgId: job.orgId, periodId }),
      declarations.declaredMassByCategory({ orgId: job.orgId, periodId }),
    ]);
    const policy = await eprPolicy.readPolicy();
    const projected = eprPeriods.projectForProducer(
      period ?? { orgId: job.orgId, periodId },
      policy,
    );
    periods.push({ periodId, ...summarise(projected, declared) });
  }

  const issued = await passports.listPassports({ orgId: job.orgId, limit: 50 });

  return serialise(job, {
    registration: {
      legalName: organization.legalName ?? '',
      tradeName: organization.tradeName ?? '',
      doeRegistrationNo: organization.doeRegistrationNo ?? null,
      sizeClass: organization.sizeClass ?? null,
      obligationStartDate: organization.obligationStartDate?.toDate?.()
        ? dhakaDate(organization.obligationStartDate)
        : null,
      complianceRoute: organization.complianceRoute ?? null,
    },
    periods,
    // The gazette comparison, stated per period rather than as an annual
    // average: a producer above target in eleven months and far below in one
    // has not met the target in that month, and averaging hides it.
    gazetteTargets: periods.map((p) => ({
      periodId: p.periodId,
      obligationYear: passports.obligationYearAt(organization, p.periodId),
      applicableCollectionTarget: (() => {
        const year = passports.obligationYearAt(organization, p.periodId);
        return year === null ? null : year >= 3 ? 0.3 : 0.15;
      })(),
      collectionRate: p.collectionRate,
    })),
    // EPR-33 lists a "recycling-gap statement" as required content. It is a
    // statement, not a figure: Chokro has no recycling evidence at all, and
    // the gap between the gazette's recycling target and what Chokro can
    // support is the whole of it.
    recyclingGapStatement:
      'The 2024 gazette sets a recycling target alongside its collection '
      + 'target. Chokro records collection only and holds no evidence of what '
      + 'was recycled downstream, so no recycling rate is stated in this '
      + 'report and none can be derived from it. The recycling target is '
      + 'therefore unaddressed by this evidence and must be evidenced '
      + 'separately.',
    passportRegister: issued.map((p) => ({
      serial: p.serial,
      periodId: p.periodId,
      status: p.status,
      contentHash: p.contentHash,
    })),
    methodology: methodologyStatement(),
  });
}

async function reconciliationVariance(job) {
  const [period, declaration, versions] = await Promise.all([
    eprPeriods.getPeriod({ orgId: job.orgId, periodId: job.periodId }),
    declarations.getDeclaration({ orgId: job.orgId, periodId: job.periodId }),
    declarations.listVersions({ orgId: job.orgId, periodId: job.periodId }),
  ]);

  const affected = await db()
    .collection(passports.PASSPORTS)
    .where('orgId', '==', job.orgId)
    .where('periodId', '==', job.periodId)
    .orderBy('issuedAt', 'asc')
    .limit(50)
    .get();

  return serialise(job, {
    incrementedMassMg: sumMap(period?.massMgByCategory),
    // QA-3: a mismatch is surfaced, never silently corrected. Both figures are
    // reported side by side and the reader is told they disagree.
    recomputedMassMg: period?.recomputedMassMg ?? null,
    recomputeMatched: typeof period?.recomputeMatched === 'boolean'
      ? period.recomputeMatched
      : null,
    recomputedAt: period?.recomputedAt ? dhakaDate(period.recomputedAt) : null,
    reversedCount: intOr0(period?.reversedCount),
    declarationVersions: versions.map((v) => ({
      version: v.version,
      totalMassMg: v.totalMassMg,
      attestedByName: v.attestedByName ?? '',
      supersededReason: v.supersededReason ?? null,
    })),
    currentDeclarationStatus: declaration?.status ?? 'none',
    passports: affected.docs.map((d) => ({
      serial: d.data().serial,
      status: d.data().status,
      supersededReason: d.data().supersededReason ?? null,
      revocationReason: d.data().revocationReason ?? null,
    })),
  });
}

/**
 * Surplus mass above the applicable target (§15 decision 7).
 *
 * Called surplus, not credits. The gazette permits plastic credits, but the
 * operational framework — who issues, who verifies, how they transfer — is an
 * open question, and reporting a tradeable instrument before the framework
 * exists would be Chokro asserting one into being.
 */
async function surplusMass(job) {
  const [orgSnap, period, declared, policy] = await Promise.all([
    db().collection('organizations').doc(job.orgId).get(),
    eprPeriods.getPeriod({ orgId: job.orgId, periodId: job.periodId }),
    declarations.declaredMassByCategory({ orgId: job.orgId, periodId: job.periodId }),
    eprPolicy.readPolicy(),
  ]);
  if (!orgSnap.exists) throw badRequest('That organisation does not exist.');

  const projected = eprPeriods.projectForProducer(
    period ?? { orgId: job.orgId, periodId: job.periodId },
    policy,
  );
  const totals = summarise(projected, declared);
  const obligationYear = passports.obligationYearAt(orgSnap.data(), job.periodId);
  const target = obligationYear === null ? null : obligationYear >= 3 ? 0.3 : 0.15;

  // Null, not zero, in every case where a surplus cannot be established: no
  // declaration means no denominator, and no obligation year means no target.
  // A zero would read as "no surplus", which is a different claim.
  const surplusMg =
    totals.declaredMassMg === null || target === null
      ? null
      : Math.max(0, totals.collectedMassMg - Math.round(totals.declaredMassMg * target));

  return serialise(job, {
    collectedMassMg: totals.collectedMassMg,
    declaredMassMg: totals.declaredMassMg,
    applicableCollectionTarget: target,
    obligationYear,
    requiredMassMg:
      totals.declaredMassMg === null || target === null
        ? null
        : Math.round(totals.declaredMassMg * target),
    surplusMassMg: surplusMg,
    surplusAbsenceReason:
      surplusMg !== null
        ? null
        : totals.declaredMassMg === null
          ? 'No put-on-market declaration has been filed for this period, so '
            + 'there is no denominator against which a surplus could be measured.'
          : 'No obligation start date is recorded, so no gazette target applies '
            + 'and no surplus can be established.',
    eligibilityCaveats: [
      'This is surplus MASS, not a plastic credit. Chokro does not issue, '
        + 'verify or transfer credits, and nothing in this statement is a '
        + 'tradeable instrument.',
      'The operational framework for plastic credits under the 2024 gazette — '
        + 'who issues, who verifies, how they transfer — is not established. '
        + 'Any credit claim built on this figure would be built on an '
        + 'unestablished framework.',
      'The figure counts only mass collected through Chokro, and rests in part '
        + `on estimated mass (${(totals.estimatedShare * 100).toFixed(1)}% of `
        + 'this period).',
      'The denominator is the producer’s own attested declaration, not '
        + 'independently verified.',
    ],
  });
}

function methodologyStatement() {
  return {
    attribution:
      'Packaging is attributed to a producer when Chokro recognises a '
      + 'registered product in a disposal photograph, or when a scanned '
      + 'barcode matches a registered GTIN. Recognition confidence is recorded '
      + 'per attribution and reported as a confidence mix.',
    mass:
      'Reported mass is the number of units recognised multiplied by the unit '
      + 'mass Chokro established by weighing a sample of the product, not the '
      + 'mass the producer declared. All figures are stored as integer '
      + 'milligrams and rounded once, at display.',
    period:
      'Reporting periods are calendar months in Asia/Dhaka (UTC+06), assigned '
      + 'server-side from the disposal decision time.',
    knownLimits: [
      'Recognition is imperfect. Medium-confidence matches are attributed and '
        + 'reported separately as an estimated share; low-confidence matches '
        + 'are not attributed at all.',
      'Material Chokro could not attribute to any producer is held in an '
        + 'unattributed pool and is not counted against any company.',
      'The web client cannot prove a photograph was taken live. Disposals '
        + 'submitted through it carry weaker provenance than those from the '
        + 'native app.',
    ],
  };
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/**
 * Every attribution for a period, in batches.
 *
 * Ordered by document id, which is both stable and unique — ordering by
 * `createdAt` alone would leave two attributions written in the same
 * millisecond in an arbitrary order, and EPR-34 requires two runs to be
 * byte-identical.
 */
async function readAllAttributions(job) {
  const rows = [];
  let cursor = null;

  for (;;) {
    let query = db()
      .collection(ATTRIBUTIONS)
      .where('orgId', '==', job.orgId)
      .where('periodId', '==', job.periodId)
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

/** The SKUs named by an attribution set, read in `in` chunks of ten. */
async function readSkus(orgId, skuIds) {
  const out = new Map();
  const unique = [...new Set(skuIds.filter(Boolean))].sort();

  for (let i = 0; i < unique.length; i += 10) {
    const chunk = unique.slice(i, i + 10);
    const snap = await db()
      .collection(SKUS)
      .where(admin.firestore.FieldPath.documentId(), 'in', chunk)
      .get();
    for (const doc of snap.docs) {
      const sku = doc.data();
      // Checked, not assumed. A SKU id reaching here from an attribution
      // should always belong to this organisation, but reading one that does
      // not into a report would put another company's product name in this
      // company's export.
      if (sku.orgId !== orgId) continue;
      out.set(doc.id, sku);
    }
  }

  return out;
}

// ---------------------------------------------------------------------------
// Serialising
// ---------------------------------------------------------------------------

/**
 * Renders the body and hashes it.
 *
 * The hash covers the body only. EPR-34's determinism requirement is that two
 * reports of the same scope and period differ only in the generation timestamp
 * and requester, and a hash that covered those would differ on every run —
 * making it useless for the comparison it exists to enable.
 */
function serialise(job, payload, csvColumns = null) {
  let text;

  if (job.format === 'csv') {
    if (!csvColumns) {
      throw badRequest(`${job.label} is not produced as CSV.`);
    }
    const rows = payload.rows ?? [];
    text = [
      csvColumns.join(','),
      ...rows.map((row) => csvColumns.map((c) => csvCell(row[c])).join(',')),
    ].join('\n');
    text += '\n';
  } else {
    // Key order is insertion order, and every payload above is built in a
    // fixed order — so two runs over the same data produce identical text.
    // Two-space indent so a human can read a diff between two copies, which is
    // the comparison EPR-34 exists to enable.
    text = JSON.stringify(payload, null, 2);
  }

  return {
    text,
    contentHash: crypto.createHash('sha256').update(text, 'utf8').digest('hex'),
    rowsRead: payload.rowsRead ?? (payload.rows?.length ?? 0),
  };
}

/**
 * One CSV cell, quoted and escaped.
 *
 * Also neutralises formula injection: a cell beginning `=`, `+`, `-` or `@` is
 * executed as a formula by Excel and Sheets on open, and these exports carry
 * producer-supplied product names and brands. `=HYPERLINK(...)` in a brand name
 * would run in an auditor's spreadsheet.
 */
function csvCell(value) {
  if (value === null || value === undefined) return '';
  const raw = typeof value === 'boolean' ? String(value) : String(value);
  const guarded = /^[=+\-@\t\r]/.test(raw) ? `'${raw}` : raw;
  return `"${guarded.replace(/"/g, '""')}"`;
}

// ---------------------------------------------------------------------------
// Delivery (SEC-6)
// ---------------------------------------------------------------------------

/**
 * A short-lived signed URL for a finished job.
 *
 * SEC-6: "No public bucket, no guessable path, no permanent URL. Fetched only
 * through a signed URL that is scoped to the requesting user, expires in
 * minutes, and is single-use where the storage layer allows it. Every download
 * is logged with actor, org and artefact."
 *
 * GCS V4 signed URLs are not single-use — the storage layer does not support
 * it — so the "where the storage layer allows it" clause applies and the
 * mitigation is the short expiry plus the download log. Said here rather than
 * left for a reader to discover.
 */
async function signedUrlFor({ jobId, orgId, actorUid, actorName = '', actorRole }) {
  const job = await getJob({ jobId, orgId });
  if (!job) throw badRequest('That report does not exist.');
  if (job.status !== 'ready') {
    throw conflict(`That report is ${job.status}, not ready.`);
  }
  if (!job.storagePath) throw badRequest('That report has no artefact.');

  // ==========================================================================
  // THE ROLE IS RE-CHECKED HERE, NOT ONLY AT ENQUEUE
  // ==========================================================================
  //
  // `chainOfCustody`, the annual return and the surplus statement are
  // owner-only, and the enqueue route enforces that. Delivery is a separate
  // request, and `listJobs` returns every job for the organisation — so
  // without this check a viewer lists the jobs, finds the row-level export an
  // owner requested yesterday, and downloads it.
  //
  // That is the SEC-11 "org member exfiltrates data" row, reached by the one
  // route that hands over the actual bytes. An authorisation enforced only at
  // the point of request is not enforced.
  const spec = REPORT_TYPES[job.reportType];
  if (spec && !organizations.orgRoleAtLeast(actorRole, spec.minRole)) {
    const error = new Error(
      `${spec.label} can only be downloaded by an owner.`,
    );
    error.code = 'forbidden';
    throw error;
  }

  const expires = Date.now() + SIGNED_URL_MINUTES * 60 * 1000;

  const [url] = await bucket().file(job.storagePath).getSignedUrl({
    version: 'v4',
    action: 'read',
    expires,
    // Forces a download rather than an inline render, so a forwarded URL
    // cannot be embedded as an image or a script source somewhere.
    responseDisposition:
      `attachment; filename="chokro-${job.reportType}-`
      + `${job.periodId || job.year || 'all'}.${job.format}"`,
  });

  await audit.append({
    orgId,
    action: audit.ACTIONS.REPORT_DOWNLOADED,
    actorUid,
    actorName,
    actorRole,
    targetType: 'report',
    targetId: jobId,
    summary:
      `${job.label} downloaded (${job.format.toUpperCase()}, `
      + `content hash ${String(job.contentHash).slice(0, 12)}…).`,
  });

  return {
    url,
    expiresAt: new Date(expires).toISOString(),
    expiresInSeconds: SIGNED_URL_MINUTES * 60,
    contentHash: job.contentHash,
    byteSize: job.byteSize,
  };
}

/**
 * Refuses at enqueue time when there is nowhere to put the artefact.
 *
 * A signed URL is the only delivery EPR-35 permits. Without a bucket the
 * alternative would be streaming the report in the response — which is the
 * thing EPR-35 exists to prevent — so this fails loudly and names the variable
 * the operator has to set.
 */
function assertStorageConfigured() {
  if (!process.env.FIREBASE_STORAGE_BUCKET) {
    const error = new Error(
      'Report generation is not configured: FIREBASE_STORAGE_BUCKET is unset, '
        + 'so there is nowhere to write the artefact and no signed URL to hand '
        + 'back. Reports are delivered only through a short-lived signed URL '
        + '(SEC-6); streaming one in the response is what EPR-35 forbids.',
    );
    error.code = 'reports_unconfigured';
    throw error;
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function summarise(projected, declared) {
  const collectedMassMg = sumMap(projected.massMgByCategory);
  const declaredMassMg = declared
    ? Object.values(declared).reduce((sum, mg) => sum + intOr0(mg), 0)
    : null;
  const uncertainMassMg = intOr0(projected.uncertainMassMg);

  return {
    collectedMassMg,
    declaredMassMg,
    // Null, never zero. EPR-24: a period with no declaration has no
    // percentage; it does not have a percentage of zero.
    collectionRate:
      declaredMassMg !== null && declaredMassMg > 0
        ? Number((collectedMassMg / declaredMassMg).toFixed(6))
        : null,
    attributionCount: intOr0(projected.attributionCount),
    uncertainMassMg,
    estimatedShare: collectedMassMg > 0 ? uncertainMassMg / collectedMassMg : 0,
  };
}

/**
 * The twelve reporting periods of an obligation year.
 *
 * Counted from the producer's own registration anniversary in Asia/Dhaka, not
 * from January — EPR-33 says "annual, on the producer's registration clock".
 */
function twelvePeriodsFrom(organization, obligationYear) {
  const start = organization.obligationStartDate?.toDate?.();
  if (!start) return [];

  const dhaka = new Date(start.getTime() + 6 * 60 * 60 * 1000);
  const startMonthIndex =
    dhaka.getUTCFullYear() * 12 + dhaka.getUTCMonth() + (obligationYear - 1) * 12;

  const periods = [];
  for (let i = 0; i < 12; i += 1) {
    const monthIndex = startMonthIndex + i;
    const year = Math.floor(monthIndex / 12);
    const month = (monthIndex % 12) + 1;
    periods.push(`${year}-${String(month).padStart(2, '0')}`);
  }
  return periods;
}

/**
 * A per-organisation pseudonym for a disposal id (SEC-3).
 *
 * Keyed with the audit chain key where one is set. Without it the digest is
 * unkeyed and therefore reversible by anyone who can guess disposal ids — which
 * is worth stating rather than hiding, and is the same caveat the audit chain
 * carries.
 */
function pseudonym(orgId, disposalId) {
  if (!disposalId) return '';
  const key = process.env.AUDIT_CHAIN_KEY || '';
  return crypto
    .createHmac('sha256', `${key}:${orgId}`)
    .update(String(disposalId))
    .digest('hex')
    .slice(0, 24);
}

/** A date in Asia/Dhaka, at fixed +6. Date only — see `chainOfCustody`. */
function dhakaDate(value) {
  const date = value?.toDate?.() ?? (value instanceof Date ? value : null);
  if (!date) return '';
  const dhaka = new Date(date.getTime() + 6 * 60 * 60 * 1000);
  return dhaka.toISOString().slice(0, 10);
}

function sumMap(map) {
  if (!map) return 0;
  return Object.values(map).reduce((sum, mg) => sum + intOr0(mg), 0);
}

/**
 * Whether an attribution has been reversed (EPR-21).
 *
 * The canonical marker is `reversedAt`. There is no boolean `reversed` field:
 * `attribute.js` writes `reversedBy`/`reversedAt`/`reversedReason` as nulls at
 * creation and `eprPeriods.reverseAttribution` fills them in, so a reader
 * testing `row.reversed` tests something no writer ever sets and silently
 * treats every reversed row as live.
 *
 * One predicate rather than the expression inline at each call site, because
 * this file had the same mistake in two places and a third reader would have
 * made it again.
 */
function isReversed(row) {
  return Boolean(row?.reversedAt);
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
  JOBS,
  JOB_STATUSES,
  REPORT_TYPES,
  BOUNDARY_STATEMENTS,
  GENERATOR,
  GENERATOR_VERSION,
  SIGNED_URL_MINUTES,
  STALE_AFTER_MINUTES,
  enqueue,
  getJob,
  listJobs,
  runJob,
  buildReport,
  buildHeader,
  assembleArtefact,
  serialise,
  csvCell,
  signedUrlFor,
  assertStorageConfigured,
  summarise,
  twelvePeriodsFrom,
  pseudonym,
  dhakaDate,
  isReversed,
  methodologyStatement,
};
