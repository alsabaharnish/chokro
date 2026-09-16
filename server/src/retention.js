/**
 * Chokro — the retention schedule (SEC-13, NFR-E-8).
 *
 * ## THIS MODULE HAS NO DEFAULT DURATIONS, AND THAT IS THE POINT
 *
 * `eprPolicy.js` tolerates absence: a missing value falls back to a documented
 * default, because a mass verification that fails when nobody has opened the
 * policy screen is a worse failure than one that uses a sensible number.
 *
 * Retention inverts that rule, deliberately. Every duration here is a legal
 * determination under Bangladesh's Personal Data Protection Act that SEC-13
 * says in as many words "needs a lawyer's answer, not an engineer's". A
 * default would be an engineer's answer wearing a lawyer's clothes, and it
 * would be wrong in one of two directions, both of which are the harm this
 * module exists to prevent:
 *
 *   - too short, and evidence behind an issued certificate is destroyed before
 *     the DoE's audit horizon closes (NFR-E-8);
 *   - too long, and personal data is kept past its lawful basis, which is the
 *     exposure SEC-13 opens by saying this feature "materially increases" it.
 *
 * So: **an unconfigured collection throws.** Nothing expires by accident, and
 * nothing expires because nobody chose a number. `assertConfigured` is how a
 * caller finds out, by name, which determinations are still missing.
 *
 * ## THIS MODULE DOES NOT DELETE ANYTHING
 *
 * It classifies, it computes what is due, and it reports what an erasure
 * request would touch. There is no executor, and the omission is not an
 * oversight — see `planExpiry`. A deleter cannot be written correctly until
 * open decision 9 is answered, because the answer decides whether expiry
 * *purges* a record or merely *severs* its link to a person, and those are
 * different programs.
 *
 * ## THE FACT THAT MAKES THE LEGAL QUESTION TRACTABLE
 *
 * An attribution holds no Champion identifier. It holds `disposalId`, a
 * foreign key into `disposals`, and `disposals` holds the uid. The compliance
 * record Chokro must retain is therefore about *packaging* — "21 g of rigid
 * PET, SKU X, Dhaka, 3 March" — and is personal only by way of a link that can
 * be cut. `erasureImpact` measures exactly that, per Champion, so counsel is
 * answering a question with numbers attached.
 *
 * See `docs/DATA_FLOW_MAP.md` §5 for the chain and the five questions.
 */

const { db } = require('./firebase');

const DOC_PATH = ['config', 'retentionSchedule'];

/** What expiry does to a record. */
const DISPOSITIONS = Object.freeze({
  /** Delete the document. */
  purge: 'purge',
  /** Keep the document; cut its link to the person. */
  sever: 'sever',
  /** Never expires. A duration is not merely unset, it is inapplicable. */
  retain: 'retain',
});

/** What a Champion's erasure request does to a record. */
const ERASURE = Object.freeze({
  purge: 'purge',
  sever: 'sever',
  /** Holds nothing about the Champion; the request does not reach it. */
  none: 'none',
  /**
   * The request reaches it and compliance says no. Every entry carrying this
   * is a row counsel must rule on before launch.
   */
  contested: 'contested',
});

const CLASSES = Object.freeze({
  /** Identifies a living person directly. */
  personal: 'personal',
  /** About packaging or a company, retained to prove a compliance figure. */
  compliance: 'compliance',
  /** Computed from the above; reproducible, so cheap to lose. */
  derived: 'derived',
  /** Neither personal nor compliance. Infrastructure. */
  operational: 'operational',
});

/**
 * Every collection the EPR surface reads or writes, plus every Champion-side
 * collection a PDPA erasure request reaches.
 *
 * `months: null` throughout — see the header. The field exists so the shape of
 * a configured schedule is visible before it is configured, and so
 * `assertConfigured` can name what is missing rather than reporting a count.
 *
 * `basis` is the field the clock runs from. A schedule without one is a
 * duration with nothing to subtract it from, which is how retention rules
 * quietly become "whenever someone remembers".
 */
const SCHEDULE = Object.freeze([
  // ---------------------------------------------------------------------
  // The compliance record. Retained for the DoE's audit horizon (NFR-E-8).
  // ---------------------------------------------------------------------
  {
    collection: 'attributions',
    class: CLASSES.compliance,
    basis: 'createdAt',
    disposition: DISPOSITIONS.sever,
    erasure: ERASURE.sever,
    months: null,
    why:
      'Holds no uid — only disposalId. Severing that one field leaves a record '
      + 'about packaging and reproduces every certified figure. What severing '
      + 'costs is re-derivability from the photograph: counsel Q2.',
  },
  {
    collection: 'eprPeriods',
    class: CLASSES.derived,
    basis: 'periodId',
    disposition: DISPOSITIONS.retain,
    erasure: ERASURE.none,
    months: null,
    why:
      'Aggregate rollups. Nothing about a person survives aggregation above '
      + 'the k-anonymity floor. Retained because a passport certifies them.',
  },
  {
    collection: 'plasticPassports',
    class: CLASSES.compliance,
    basis: 'issuedAt',
    disposition: DISPOSITIONS.retain,
    erasure: ERASURE.none,
    months: null,
    why:
      'An issued certificate is a public, content-hashed statement of grams. '
      + 'Deleting one would not erase a person — it would break verification '
      + 'for whoever holds it (SEC-7).',
  },
  {
    collection: 'putOnMarketDeclarations',
    class: CLASSES.compliance,
    basis: 'periodId',
    disposition: DISPOSITIONS.retain,
    erasure: ERASURE.none,
    months: null,
    why: "A producer's own attested filing. No Champion data.",
  },
  {
    collection: 'putOnMarketVersions',
    class: CLASSES.compliance,
    basis: 'createdAt',
    disposition: DISPOSITIONS.retain,
    erasure: ERASURE.none,
    months: null,
    why:
      'Superseded versions are the evidence that a correction happened '
      + '(EPR-12). Retaining only the current one would make variance review '
      + 'unfalsifiable.',
  },
  {
    collection: 'producerAuditLog',
    class: CLASSES.compliance,
    basis: 'timestampIso',
    disposition: DISPOSITIONS.retain,
    erasure: ERASURE.none,
    months: null,
    why:
      'HMAC-chained and append-only. DELETING ANY ENTRY BREAKS THE CHAIN FROM '
      + 'THAT POINT FORWARD and makes every later entry unverifiable — the log '
      + 'cannot have a retention period in the ordinary sense. Holds producer '
      + 'staff identity, not Champion identity.',
  },
  {
    collection: 'producerAuditHeads',
    class: CLASSES.compliance,
    basis: 'updatedAt',
    disposition: DISPOSITIONS.retain,
    erasure: ERASURE.none,
    months: null,
    why: 'The chain head. Meaningless apart from the log it points at.',
  },
  {
    collection: 'skuMassAudits',
    class: CLASSES.compliance,
    basis: 'createdAt',
    disposition: DISPOSITIONS.retain,
    erasure: ERASURE.none,
    months: null,
    why:
      'The physical-sampling evidence behind a verified unit mass (EPR-11), '
      + 'and the tolerance in force when it was judged. Without it a '
      + 'certificate rests on an unexplained number.',
  },

  // ---------------------------------------------------------------------
  // The producer's own registry and staff.
  // ---------------------------------------------------------------------
  {
    collection: 'producerSkus',
    class: CLASSES.compliance,
    basis: 'updatedAt',
    disposition: DISPOSITIONS.retain,
    erasure: ERASURE.none,
    months: null,
    why: 'Product data. Attributions reference a revision of it.',
  },
  {
    collection: 'skuRevisions',
    class: CLASSES.compliance,
    basis: 'createdAt',
    disposition: DISPOSITIONS.retain,
    erasure: ERASURE.none,
    months: null,
    why:
      'An attribution pins the revision it used. Deleting revisions would '
      + 'strand the figures that cite them.',
  },
  {
    collection: 'organizations',
    class: CLASSES.compliance,
    basis: 'createdAt',
    disposition: DISPOSITIONS.retain,
    erasure: ERASURE.none,
    months: null,
    why: 'A company, not a person. Named on every certificate it holds.',
  },
  {
    collection: 'organizationMembers',
    class: CLASSES.personal,
    basis: 'joinedAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.purge,
    months: null,
    why:
      "A producer's staff. Personal data of a person with no Chokro "
      + 'relationship beyond their employer. The one personal-data retention '
      + 'here that has nothing to do with Champions.',
  },
  {
    collection: 'orgInvitations',
    class: CLASSES.personal,
    basis: 'createdAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.purge,
    months: null,
    why:
      'An invitation holds an email address and, once redeemed or expired, '
      + 'serves no purpose. The shortest duration on this schedule.',
  },

  // ---------------------------------------------------------------------
  // Oversight. Derived, and reproducible by rescanning.
  // ---------------------------------------------------------------------
  {
    collection: 'eprAnomalies',
    class: CLASSES.derived,
    basis: 'detectedAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.none,
    months: null,
    why:
      'Findings and dismissals. Reproducible by rescanning the period — but a '
      + 'dismissal is a human judgement that a rescan does not reproduce.',
  },
  {
    collection: 'attributionConfirmations',
    class: CLASSES.derived,
    basis: 'createdAt',
    disposition: DISPOSITIONS.sever,
    erasure: ERASURE.sever,
    months: null,
    why:
      'The accuracy-audit sample. Carries a disposal reference for the same '
      + 'reason an attribution does, and is severable the same way.',
  },
  {
    collection: 'reportJobs',
    class: CLASSES.derived,
    basis: 'createdAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.none,
    months: null,
    why:
      'Generated artefacts. NFR-E-8 requires reports be REPRODUCIBLE from '
      + 'retained inputs, not that every generated copy be kept. A stored '
      + 'chain-of-custody export is a standing copy of row-level data and is '
      + 'the strongest argument on this schedule for a SHORT duration.',
  },
  {
    collection: 'binSkuFrequency',
    class: CLASSES.derived,
    basis: 'updatedAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.none,
    months: null,
    why:
      'Counters used as a recognition prior. Aggregate across all Champions '
      + 'at a bin; one person is not recoverable from it.',
  },

  // ---------------------------------------------------------------------
  // Champion-side, including the marketplace. In scope because erasure
  // reaches it, and because this is where the tension SEC-13 describes
  // actually lives. The marketplace rows were found by the completeness test
  // in `retention.test.js`, not by reading the spec — which is the argument
  // for keeping that test.
  // ---------------------------------------------------------------------
  {
    collection: 'users',
    class: CLASSES.personal,
    basis: 'createdAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.purge,
    months: null,
    why: 'The Champion. The subject of the request.',
  },
  {
    collection: 'disposals',
    class: CLASSES.personal,
    basis: 'createdAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.contested,
    months: null,
    why:
      'THE CONTESTED RECORD. Holds the uid, the photograph and the capture '
      + 'geolocation — and is the primary evidence behind every attribution '
      + 'that cites it. Purging satisfies erasure and destroys '
      + 're-derivability; retaining preserves the audit trail and keeps a '
      + "person's photograph past their request. Counsel Q1 and Q2 decide "
      + 'this row, and this row decides the schedule.',
  },
  {
    collection: 'claims',
    class: CLASSES.personal,
    basis: 'createdAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.purge,
    months: null,
    why:
      'Self-reported eco-actions. Outside the attribution path entirely '
      + '(EPR-27), so nothing compliance-critical cites them.',
  },
  {
    collection: 'devices',
    class: CLASSES.personal,
    basis: 'updatedAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.purge,
    months: null,
    why: 'Push tokens. No compliance interest whatsoever.',
  },
  {
    collection: 'points',
    class: CLASSES.personal,
    basis: 'createdAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.purge,
    months: null,
    why:
      'The points ledger is deliberately outside the attribution path '
      + '(EPR-27), so erasing it cannot move a compliance figure.',
  },
  {
    collection: 'wallets',
    class: CLASSES.personal,
    basis: 'updatedAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.contested,
    months: null,
    why:
      'A balance with financial-record obligations of its own, unrelated to '
      + 'EPR. Flagged rather than answered: it belongs to the pre-existing '
      + 'PDPA work SEC-13 says is already on the radar.',
  },
  {
    collection: 'transactions',
    class: CLASSES.personal,
    basis: 'createdAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.contested,
    months: null,
    why: 'As `wallets`. Financial records, not EPR records.',
  },
  {
    collection: 'orders',
    class: CLASSES.personal,
    basis: 'createdAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.contested,
    months: null,
    why:
      'A purchase by an identifiable buyer from an identifiable seller. Carries '
      + 'financial-record obligations of its own, unrelated to EPR, and an '
      + "erasure request from one party reaches the other party's record of the "
      + 'same transaction. Pre-existing PDPA work, not EPR work.',
  },
  {
    collection: 'carts',
    class: CLASSES.personal,
    basis: 'updatedAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.purge,
    months: null,
    why:
      'An abandoned cart is a record of what someone wanted and did not buy. '
      + 'No compliance interest and no counterparty; the shortest duration on '
      + 'the Champion side.',
  },
  {
    collection: 'products',
    class: CLASSES.personal,
    basis: 'createdAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.contested,
    months: null,
    why:
      "A seller's listing, including their photographs. Contested because a "
      + 'listing cited by a completed order cannot be erased without stranding '
      + "the buyer's record of what they bought.",
  },
  {
    collection: 'donations',
    class: CLASSES.personal,
    basis: 'createdAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.contested,
    months: null,
    why:
      'A donation is a charitable-giving record with its own retention '
      + 'expectations and a named recipient organisation. Flagged for the same '
      + 'pre-existing PDPA work as `wallets` and `transactions`.',
  },
  {
    collection: 'lockouts',
    class: CLASSES.operational,
    basis: 'expiresAt',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.purge,
    months: null,
    why: 'Anti-abuse state, already short-lived by design.',
  },
  {
    collection: 'dailyCaps',
    class: CLASSES.operational,
    basis: 'date',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.purge,
    months: null,
    why:
      'Per-day earn counters, keyed by uid and date. Anti-abuse state with no '
      + 'value once the day has passed.',
  },
  {
    collection: 'claimQuotas',
    class: CLASSES.operational,
    basis: 'date',
    disposition: DISPOSITIONS.purge,
    erasure: ERASURE.purge,
    months: null,
    why:
      'Per-day claim counters, keyed by uid and date. As `dailyCaps`, for the '
      + 'weaker earn route.',
  },
  {
    collection: 'bins',
    class: CLASSES.operational,
    basis: null,
    disposition: DISPOSITIONS.retain,
    erasure: ERASURE.none,
    months: null,
    why: 'Physical infrastructure. Not about anyone.',
  },
]);

const BY_COLLECTION = Object.freeze(
  Object.fromEntries(SCHEDULE.map((e) => [e.collection, e])),
);

/**
 * The schedule with any configured durations merged in.
 *
 * A malformed stored value is treated as UNSET rather than clamped. Clamping a
 * bad duration into range would produce a number nobody chose, which is the
 * failure mode this whole module is built to avoid — and unlike a policy
 * threshold, the consequence is destroyed evidence.
 */
async function loadSchedule() {
  let raw = {};
  try {
    const snap = await db().collection(DOC_PATH[0]).doc(DOC_PATH[1]).get();
    if (snap.exists) raw = snap.data() || {};
  } catch (err) {
    // A read failure must not look like "nothing is configured", because that
    // reads as "everything is unset" and an operator would go and set it all
    // again. Raised so the caller can say the schedule is UNAVAILABLE.
    console.error('[retention] schedule read failed:', err.message);
    throw new Error('retention_schedule_unavailable');
  }

  const months = raw.months && typeof raw.months === 'object' ? raw.months : {};

  return SCHEDULE.map((entry) => ({
    ...entry,
    months: readMonths(months[entry.collection]),
    configuredBy: typeof raw.configuredBy === 'string' ? raw.configuredBy : null,
    configuredAt: typeof raw.configuredAt === 'string' ? raw.configuredAt : null,
    counselReference:
      typeof raw.counselReference === 'string' ? raw.counselReference : null,
  }));
}

/** A duration, or null. Never a coerced approximation of one. */
function readMonths(value) {
  if (typeof value !== 'number' || !Number.isFinite(value)) return null;
  if (!Number.isInteger(value)) return null;
  // Zero would mean "delete immediately", which no lawful basis produces and a
  // typo easily does. Beyond a century is a typo in the other direction.
  if (value < 1 || value > 1200) return null;
  return value;
}

/**
 * Which determinations are still missing.
 *
 * Entries dispositioned `retain` are excluded: they do not expire, so they are
 * not unset — they are inapplicable, and reporting them as missing would make
 * the outstanding list permanently non-empty and therefore ignorable.
 */
async function pendingDeterminations() {
  const schedule = await loadSchedule();
  return schedule
    .filter((e) => e.disposition !== DISPOSITIONS.retain && e.months === null)
    .map((e) => ({
      collection: e.collection,
      class: e.class,
      disposition: e.disposition,
      why: e.why,
    }));
}

/**
 * Throws unless every expiring collection has a duration.
 *
 * Names them, because "retention is not configured" sends an operator looking
 * and a list tells them what to ask counsel for.
 */
async function assertConfigured() {
  const pending = await pendingDeterminations();
  if (pending.length === 0) return true;

  const names = pending.map((p) => p.collection).join(', ');
  const error = new Error(
    `Retention is not configured for: ${names}. `
    + 'Each is a legal determination under SEC-13, not an engineering default. '
    + 'See docs/RETENTION_SCHEDULE.md.',
  );
  error.code = 'retention_unconfigured';
  error.pending = pending;
  throw error;
}

/**
 * The cutoff instant for one collection: anything older is due.
 *
 * Throws on an unconfigured collection rather than returning null, because a
 * null cutoff compared against a timestamp is `false` in JavaScript — an
 * unconfigured collection would silently look like "nothing is due", which is
 * the difference between a schedule nobody has set and a schedule with nothing
 * to do.
 */
function cutoffFor(entry, now) {
  if (!entry) throw new Error('retention: unknown collection');
  if (entry.disposition === DISPOSITIONS.retain) return null;
  if (entry.months === null) {
    const error = new Error(
      `Retention for '${entry.collection}' is not configured (SEC-13).`,
    );
    error.code = 'retention_unconfigured';
    throw error;
  }

  const cutoff = new Date(now.getTime());
  // setUTCMonth handles the rollover, including the 31 Jan → 28 Feb case,
  // which a 30-day-per-month arithmetic would get wrong by up to three days a
  // year — irrelevant for a three-year horizon, and wrong in a document that
  // claims to say exactly when a record dies.
  cutoff.setUTCMonth(cutoff.getUTCMonth() - entry.months);
  return cutoff;
}

/**
 * What is due, and what would happen to it. **Does not delete.**
 *
 * The executor is deliberately absent. Open decision 9 has not been answered,
 * and until it is, a `sever` and a `purge` are indistinguishable guesses about
 * the same record — `disposals` above is the case in point. Writing the
 * deleter first would mean choosing, in code, the thing SEC-13 says is not an
 * engineer's to choose.
 *
 * What this returns is the artefact you would review BEFORE running such a
 * thing: counts, per collection, with the disposition that would apply.
 */
async function planExpiry({ now, collections = null } = {}) {
  if (!(now instanceof Date) || Number.isNaN(now.getTime())) {
    throw new Error('retention: planExpiry requires an explicit `now`');
  }

  const schedule = await loadSchedule();
  const wanted = collections
    ? schedule.filter((e) => collections.includes(e.collection))
    : schedule;

  const plan = [];
  for (const entry of wanted) {
    if (entry.disposition === DISPOSITIONS.retain) {
      plan.push({
        collection: entry.collection,
        disposition: entry.disposition,
        status: 'neverExpires',
        dueCount: 0,
        cutoff: null,
      });
      continue;
    }

    if (entry.months === null) {
      plan.push({
        collection: entry.collection,
        disposition: entry.disposition,
        // Not a count of zero. An unconfigured collection and an empty one
        // must never render the same.
        status: 'unconfigured',
        dueCount: null,
        cutoff: null,
      });
      continue;
    }

    const cutoff = cutoffFor(entry, now);
    let dueCount = null;
    let status = 'planned';

    if (entry.basis) {
      try {
        const snap = await db()
          .collection(entry.collection)
          .where(entry.basis, '<', cutoff)
          .count()
          .get();
        dueCount = snap.data().count;
      } catch (err) {
        // A basis field that is a string period id, or an index that does not
        // exist, lands here. Reported rather than swallowed: a plan that
        // silently counts zero for a collection it could not query would be
        // read as "nothing due".
        status = 'uncountable';
        console.error(
          `[retention] could not count ${entry.collection}:`,
          err.message,
        );
      }
    } else {
      status = 'uncountable';
    }

    plan.push({
      collection: entry.collection,
      disposition: entry.disposition,
      status,
      dueCount,
      cutoff: cutoff.toISOString(),
      months: entry.months,
    });
  }

  return {
    generatedAt: now.toISOString(),
    executed: false,
    executorImplemented: false,
    note:
      'Plan only. No executor exists until open decision 9 (retention versus '
      + 'erasure) is answered; see docs/DATA_FLOW_MAP.md §5.',
    plan,
  };
}

/**
 * What one Champion's erasure request would touch, and what it collides with.
 *
 * This is the SEC-13 artefact with numbers on it. Counsel is not being asked
 * "how do you weigh erasure against compliance retention" in the abstract;
 * they are being asked it about *this* Champion, whose 340 disposals became
 * 512 attributions contributing 4.1 kg to eleven issued certificates held by
 * three producers.
 *
 * Read-only, and bounded: `limit` caps the disposal scan, and the result says
 * when it was truncated rather than quietly under-reporting the collision.
 */
async function erasureImpact(uid, { limit = 2000 } = {}) {
  if (typeof uid !== 'string' || uid.length === 0) {
    throw new Error('retention: erasureImpact requires a uid');
  }

  const disposalSnap = await db()
    .collection('disposals')
    .where('userId', '==', uid)
    .limit(limit + 1)
    .get();

  const truncated = disposalSnap.size > limit;
  const disposalIds = disposalSnap.docs
    .slice(0, limit)
    .map((d) => d.id);

  const attributions = [];
  // Firestore's `in` takes thirty values per query, so this walks in chunks
  // rather than issuing one query per disposal.
  for (let i = 0; i < disposalIds.length; i += 30) {
    const chunk = disposalIds.slice(i, i + 30);
    const snap = await db()
      .collection('attributions')
      .where('disposalId', 'in', chunk)
      .get();
    for (const doc of snap.docs) attributions.push({ id: doc.id, ...doc.data() });
  }

  const periods = new Map();
  for (const row of attributions) {
    if (!row.orgId || !row.periodId) continue;
    const key = `${row.orgId}_${row.periodId}`;
    const existing = periods.get(key)
      || { orgId: row.orgId, periodId: row.periodId, attributionCount: 0, massMg: 0 };
    existing.attributionCount += 1;
    existing.massMg += Number.isInteger(row.massMg) ? row.massMg : 0;
    periods.set(key, existing);
  }

  // The collision itself: certificates whose figures were assembled from a
  // period this Champion contributed to.
  const certificates = [];
  for (const period of periods.values()) {
    const snap = await db()
      .collection('plasticPassports')
      .where('orgId', '==', period.orgId)
      .where('periodId', '==', period.periodId)
      .get();
    for (const doc of snap.docs) {
      const data = doc.data();
      certificates.push({
        serial: doc.id,
        orgId: period.orgId,
        periodId: period.periodId,
        status: data.status ?? null,
        contributedMassMg: period.massMg,
      });
    }
  }

  const organizations = new Set([...periods.values()].map((p) => p.orgId));

  return {
    uid,
    truncated,
    disposals: disposalIds.length,
    attributions: attributions.length,
    contributedMassMg: attributions.reduce(
      (sum, r) => sum + (Number.isInteger(r.massMg) ? r.massMg : 0),
      0,
    ),
    periods: [...periods.values()],
    organizations: [...organizations],
    certificates,
    // Stated, not implied. A caller rendering this must not present it as a
    // decision Chokro has taken.
    resolution: 'undetermined',
    resolutionNote:
      'Open decision 9. Severing `attributions.disposalId` would satisfy '
      + 'erasure while leaving every certified figure reproducible; purging '
      + '`disposals` additionally destroys the photographic evidence behind '
      + 'these certificates. Counsel Q1 and Q2 (docs/DATA_FLOW_MAP.md §5).',
  };
}

module.exports = {
  SCHEDULE,
  BY_COLLECTION,
  DISPOSITIONS,
  ERASURE,
  CLASSES,
  loadSchedule,
  pendingDeterminations,
  assertConfigured,
  cutoffFor,
  planExpiry,
  erasureImpact,
  // Exported for the schedule-completeness test.
  readMonths,
};
