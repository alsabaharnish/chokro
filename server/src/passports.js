/**
 * Chokro — the Plastic Passport (EPR-28 to EPR-31, SEC-6, SEC-7).
 *
 * The producer's headline deliverable, and "the artefact most likely to be
 * handed to a regulator, a buyer's sustainability team or a journalist. It has
 * to be worth trusting."
 *
 * ===========================================================================
 * WHAT MAKES IT WORTH TRUSTING
 * ===========================================================================
 *
 * Four properties, and each is a separate mechanism:
 *
 * 1. THE FIGURES ARE NOT THE PRODUCER'S. Every number on the certificate is
 *    read here, server-side, from `eprPeriods` (which Chokro incremented) and
 *    `putOnMarketDeclarations` (which the producer attested to and cannot
 *    edit). Nothing is accepted from the request.
 *
 * 2. THE CONTENT IS HASHED. `canonicalPayload` renders the figures into a
 *    fixed-order string and `contentHash` digests it. A third party holding the
 *    PDF can ask the verification endpoint whether that hash is the one Chokro
 *    issued.
 *
 * 3. THE SERIAL IS UNGUESSABLE (SEC-7). Not `CHOKRO-2026-0001`: a sequential
 *    serial lets a competitor enumerate every certificate Chokro has ever
 *    issued, and the verification endpoint would answer each one.
 *
 * 4. IT IS IMMUTABLE. Reissue supersedes; it does not overwrite (EPR-30). A
 *    certificate already in a third party's hands cannot be edited, so the only
 *    honest way to correct one is to mark it superseded and let the verification
 *    endpoint say so.
 */

const crypto = require('crypto');
const { db, admin, serverTimestamp } = require('./firebase');
const audit = require('./producerAudit');
const eprPeriod = require('./eprPeriod');
const eprPeriods = require('./eprPeriods');
const declarations = require('./declarations');
const eprPolicy = require('./eprPolicy');

const PASSPORTS = 'plasticPassports';
const ORGS = 'organizations';

const MG_PER_KILOGRAM = 1000000;
const MG_PER_TONNE = 1000000000;

const GAZETTE_CATEGORIES = Object.freeze([
  'rigid',
  'flexible',
  'eps',
  'singleUse',
  'other',
]);

/**
 * The serial alphabet: Crockford base32 without the ambiguous letters.
 *
 * No I, L, O or U. The first three are unreadable next to 1 and 0 on a printed
 * certificate somebody is retyping into a verification page, and U is dropped
 * because its presence makes accidental English words more likely in a
 * four-character group — a serial that reads as a word invites the reader to
 * believe it means something.
 */
const SERIAL_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

/**
 * How many random characters a serial carries.
 *
 * Eight, in two groups of four, matching Appendix A's `CHKR-PP-9F2K-7T4D`.
 * Eight base32 characters is 40 bits — about a trillion serials — so guessing
 * one at the verification endpoint's rate limit is not a strategy, and the
 * endpoint returns the same shape for an unknown serial as for a revoked one
 * (SEC-7) so a guesser learns nothing from a miss either.
 */
const SERIAL_RANDOM_CHARS = 8;

const SERIAL_PATTERN = /^CHKR-PP-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}$/;

/** Issued certificate states (EPR-30). */
const PASSPORT_STATUSES = Object.freeze(['issued', 'superseded', 'revoked']);

/**
 * Mints a serial (SEC-7).
 *
 * `crypto.randomBytes` with rejection sampling, not `% 32` on a byte: 256 is
 * not a multiple of 32 — it is, in fact — but the habit matters, and a byte
 * masked to 5 bits is uniform without any modulo bias at all. Taking the low 5
 * bits is exact here and is what this does.
 */
function generateSerial() {
  const bytes = crypto.randomBytes(SERIAL_RANDOM_CHARS);
  let body = '';
  for (const byte of bytes) {
    body += SERIAL_ALPHABET[byte & 0x1f];
  }
  return `CHKR-PP-${body.slice(0, 4)}-${body.slice(4, 8)}`;
}

function isValidSerial(value) {
  return typeof value === 'string' && SERIAL_PATTERN.test(value);
}

/**
 * The canonical figure payload — the exact bytes the content hash covers.
 *
 * ## Why this is an explicit field list and not `JSON.stringify(figures)`
 *
 * The same reasoning as the audit chain's digest. Key order in a stringified
 * object is insertion order, so a later refactor that reordered two assignments
 * would change the hash of a certificate whose figures had not changed — and
 * every previously issued passport would then fail verification.
 *
 * ## What it covers, and what it deliberately does not
 *
 * It covers every figure a reader could act on: the organisation, the period,
 * the collected mass by category and polymer, the declared denominator, the
 * computed rate, the uncertain share, and the factor version behind the carbon
 * line. Change any of those and the hash changes.
 *
 * It does not cover the issue timestamp or the issuing Admin. Those are
 * properties of the *issuance* rather than of the figures, and including them
 * would mean two certificates over identical evidence had different hashes —
 * which would make the hash useless for its actual purpose, which is answering
 * "is the document in my hand the document Chokro issued".
 *
 * It does not cover `declarationFingerprint` either, and deliberately: that
 * field exists only so `issuePassport` can detect a declaration changing
 * mid-issue, and a draft-versus-submitted distinction is already carried by
 * `declarationVersion`. Hashing it would make the hash depend on an internal
 * concurrency marker.
 */
function canonicalPayload(figures) {
  const lines = [];

  lines.push(`orgId=${figures.orgId}`);
  lines.push(`periodId=${figures.periodId}`);
  lines.push(`scope=${figures.scope}`);

  // ==========================================================================
  // THE IDENTITY OF THE CERTIFICATE'S SUBJECT
  // ==========================================================================
  //
  // These were missing, and their absence was a forgery hole. Measured: two
  // figure sets naming different companies, with different DoE registration
  // numbers, different attesters, different size classes and different
  // obligation years, hashed IDENTICALLY.
  //
  // The hash exists so a third party can answer "is the document in my hand the
  // document Chokro issued". A hash that covers the masses but not the name
  // answers a narrower question than the one it is printed to answer: take a
  // genuine certificate, change the legal name and the DoE number, and the
  // printed hash still matches what the verification endpoint reports.
  //
  // `orgId` alone was not enough. It is not printed on the certificate and it
  // is not returned by the endpoint, so a reader has nothing to compare it
  // against — the fields a reader can actually see are the ones that have to be
  // bound.
  lines.push(`legalName=${figures.organizationLegalName ?? ''}`);
  lines.push(`tradeName=${figures.organizationTradeName ?? ''}`);
  lines.push(`doeRegistrationNo=${figures.doeRegistrationNo ?? 'absent'}`);
  lines.push(`sizeClass=${figures.sizeClass ?? 'absent'}`);
  lines.push(`obligationYear=${figures.obligationYear ?? 'absent'}`);
  // The attester's name is on the page and is the person who carries the
  // consequence of a false declaration. Substituting it would substitute who
  // signed.
  lines.push(`attestedByName=${figures.declarationAttestedByName ?? 'absent'}`);

  // Gazette order, always, so the payload does not depend on how a map
  // happened to iterate.
  for (const category of GAZETTE_CATEGORIES) {
    lines.push(
      `collected.${category}=${intOr0(figures.collectedMassMgByCategory?.[category])}`,
    );
    lines.push(
      `units.${category}=${intOr0(figures.unitsByCategory?.[category])}`,
    );
    lines.push(
      `declared.${category}=${declaredOrAbsent(figures.declaredMassMgByCategory, category)}`,
    );
  }

  // Polymers in the same fixed order the vocabulary defines.
  for (const polymer of [
    'pet',
    'hdpe',
    'pvc',
    'ldpe',
    'pp',
    'ps',
    'multilayer',
    'other',
  ]) {
    lines.push(
      `polymer.${polymer}=${intOr0(figures.massMgByPolymer?.[polymer])}`,
    );
  }

  lines.push(`collectedTotal=${intOr0(figures.collectedMassMg)}`);
  // `== null` catches undefined too. `=== null` did not, so a figure set
  // missing the field — one from an older stored certificate, or one built by
  // hand — crashed here instead of reading as absent.
  lines.push(
    `declaredTotal=${figures.declaredMassMg == null ? 'absent' : intOr0(figures.declaredMassMg)}`,
  );
  lines.push(`declarationVersion=${figures.declarationVersion ?? 'absent'}`);
  // The rate to six decimal places, or the literal word. A rate that exists is
  // a number; a rate that does not is not zero (EPR-24).
  lines.push(
    `collectionRate=${
      figures.collectionRate == null ? 'absent' : figures.collectionRate.toFixed(6)
    }`,
  );
  lines.push(
    `applicableTarget=${
      figures.applicableCollectionTarget == null
        ? 'absent'
        : figures.applicableCollectionTarget.toFixed(4)
    }`,
  );
  lines.push(`attributionCount=${intOr0(figures.attributionCount)}`);
  lines.push(`disposalCount=${intOr0(figures.disposalCount)}`);
  lines.push(`uniqueSkuCount=${intOr0(figures.uniqueSkuCount)}`);
  lines.push(`uncertainMassMg=${intOr0(figures.uncertainMassMg)}`);
  lines.push(`estimatedShare=${(figures.estimatedShare ?? 0).toFixed(6)}`);
  lines.push(`reversedCount=${intOr0(figures.reversedCount)}`);
  // The factor VERSION, not the figure. A report pins the version it used so
  // the carbon number stays reproducible when the registry is updated (EPR-38).
  lines.push(`carbonFactorVersion=${figures.carbonFactorVersion ?? 'absent'}`);
  lines.push(
    `carbonKgCo2eAvoided=${
      figures.carbonKgCo2eAvoided == null
        ? 'absent'
        : figures.carbonKgCo2eAvoided.toFixed(3)
    }`,
  );
  // Recycling is never on a passport (§6.6). The literal appears in the payload
  // so that a future version which added one would change every hash, rather
  // than slipping in unnoticed.
  lines.push('recyclingRate=notCoveredByChokroEvidence');

  return lines.join('\n');
}

/** `absent` when a category was not declared; the figure when it was. */
function declaredOrAbsent(declaredMap, category) {
  if (!declaredMap) return 'absent';
  const value = declaredMap[category];
  return Number.isInteger(value) ? value : 'absent';
}

/**
 * The content hash, over [canonicalPayload].
 *
 * Plain SHA-256 rather than an HMAC, and deliberately: a third party holding
 * the PDF must be able to recompute this themselves from the printed figures if
 * they want to, without holding a Chokro secret. The verification endpoint
 * confirms the hash matches what Chokro issued; the hash's job is integrity,
 * not authenticity, and the serial is what proves provenance.
 */
function contentHash(figures) {
  return crypto
    .createHash('sha256')
    .update(canonicalPayload(figures), 'utf8')
    .digest('hex');
}

/**
 * Assembles a period's figures from stored evidence.
 *
 * NOTHING IS TAKEN FROM THE REQUEST. The caller names an organisation, a period
 * and a scope; every number comes from here.
 */
async function assembleFigures({ orgId, periodId, scope = 'period' }) {
  const [period, declaredMassMgByCategory, declaration, policy, orgSnap] =
    await Promise.all([
      eprPeriods.getPeriod({ orgId, periodId }),
      declarations.declaredMassByCategory({ orgId, periodId }),
      declarations.getDeclaration({ orgId, periodId }),
      eprPolicy.readPolicy(),
      db().collection(ORGS).doc(orgId).get(),
    ]);

  if (!orgSnap.exists) throw badRequest('That organisation does not exist.');
  const organization = orgSnap.data();

  const collectedMassMgByCategory = period?.massMgByCategory ?? {};
  const collectedMassMg = Object.values(collectedMassMgByCategory).reduce(
    (sum, mg) => sum + intOr0(mg),
    0,
  );

  const declaredMassMg = declaredMassMgByCategory
    ? Object.values(declaredMassMgByCategory).reduce(
        (sum, mg) => sum + intOr0(mg),
        0,
      )
    : null;

  // EPR-24: no percentage without a submitted declaration, and none against a
  // nil denominator either. Null, never zero.
  const collectionRate =
    declaredMassMg !== null && declaredMassMg > 0
      ? collectedMassMg / declaredMassMg
      : null;

  const obligationYear = obligationYearAt(organization, periodId);
  const applicableCollectionTarget =
    obligationYear === null ? null : obligationYear >= 3 ? 0.3 : 0.15;

  const uncertainMassMg = intOr0(period?.uncertainMassMg);
  const estimatedShare =
    collectedMassMg > 0 ? uncertainMassMg / collectedMassMg : 0;

  // EPR-39: no carbon figure at all above the uncertainty ceiling, and none
  // without a resolved factor version.
  const carbon = resolveCarbon({
    collectedMassMg,
    estimatedShare,
    ceiling: policy.carbonUncertaintyCeiling,
  });

  return {
    orgId,
    periodId,
    scope,
    organizationLegalName: organization.legalName ?? '',
    organizationTradeName: organization.tradeName ?? '',
    doeRegistrationNo: organization.doeRegistrationNo ?? null,
    sizeClass: organization.sizeClass ?? null,

    collectedMassMgByCategory,
    unitsByCategory: period?.unitsByCategory ?? {},
    massMgByPolymer: period?.massMgByPolymer ?? {},
    collectedMassMg,

    declaredMassMgByCategory,
    declaredMassMg,
    declarationVersion: declaration?.status === 'submitted' ? declaration.version : null,
    // Which declaration document state these figures were derived from.
    //
    // NOT part of the canonical payload — `canonicalPayload` is an explicit
    // field list, so this is inert for the content hash. It exists so
    // `issuePassport` can re-check inside its transaction that the denominator
    // has not moved underneath it, and it distinguishes states that
    // `declarationVersion` alone cannot: a draft at version 1 and no
    // declaration at all both give `declarationVersion: null`.
    declarationFingerprint: declarationFingerprint(declaration),
    declarationAttestedByName:
      declaration?.status === 'submitted' ? declaration.attestedByName : null,
    declarationAttestedAt:
      declaration?.status === 'submitted' ? declaration.attestedAt ?? null : null,

    collectionRate,
    applicableCollectionTarget,
    obligationYear,

    attributionCount: intOr0(period?.attributionCount),
    disposalCount: intOr0(period?.disposalCount),
    uniqueSkuCount: Array.isArray(period?.skuIds) ? period.skuIds.length : 0,
    uncertainMassMg,
    estimatedShare,
    reversedCount: intOr0(period?.reversedCount),

    carbonFactorVersion: carbon.factorVersion,
    carbonKgCo2eAvoided: carbon.kgCo2eAvoided,
    carbonAbsenceReason: carbon.absenceReason,

    recomputedAt: period?.recomputedAt ?? null,
    recomputeMatched:
      typeof period?.recomputeMatched === 'boolean'
        ? period.recomputeMatched
        : null,
  };
}

/**
 * A stable marker for the declaration state a set of figures came from.
 *
 * `none` when nothing is filed, `status:version` otherwise. Compared inside
 * `issuePassport`'s transaction against a re-read of the same document, so a
 * correction that lands mid-issue aborts the certificate rather than freezing
 * a percentage over a denominator the producer has just withdrawn.
 */
function declarationFingerprint(declaration) {
  if (!declaration) return 'none';
  return `${declaration.status ?? 'unknown'}:${declaration.version ?? 0}`;
}

/**
 * The carbon line, or the reason there is not one (EPR-38, EPR-39).
 *
 * Mirrors `carbonAvoided` in `carbon_math.dart`. The factor is the cited
 * default from §9.2; its version is what a report pins.
 */
function resolveCarbon({ collectedMassMg, estimatedShare, ceiling }) {
  if (collectedMassMg <= 0) {
    return { factorVersion: null, kgCo2eAvoided: null, absenceReason: 'noMass' };
  }
  if (estimatedShare > ceiling) {
    // A carbon estimate built on a mass that is itself substantially uncertain
    // compounds two uncertainties into one number that reads as precise.
    return {
      factorVersion: 'mixedPlastics-2015-uk-v1',
      kgCo2eAvoided: null,
      absenceReason: 'tooUncertain',
    };
  }

  const tonnes = collectedMassMg / MG_PER_TONNE;
  return {
    factorVersion: 'mixedPlastics-2015-uk-v1',
    // Positive for an avoidance; the direction is in the wording.
    kgCo2eAvoided: tonnes * 1024,
    absenceReason: null,
  };
}

/**
 * Which obligation year a reporting period falls in, or null.
 *
 * ## Why this is arithmetic on calendar months and not on instants
 *
 * The obligation start date is a CALENDAR DAY in Bangladesh — the date on the
 * approval — stored as a UTC-midnight `Timestamp`. A reporting period is a
 * CALENDAR MONTH in Asia/Dhaka, so `periodStartUtc('2026-07')` is
 * `2026-06-30T18:00:00Z`.
 *
 * Comparing those two as instants says that July 2026 *precedes* an obligation
 * that started on 1 July 2026, by six hours. Which is how the first version of
 * this function reported `null` for a producer's very first obligated period —
 * and a null obligation year means no applicable target on the certificate.
 *
 * So both sides are reduced to a Dhaka calendar year-and-month first, and the
 * comparison is between those. Day-of-month is deliberately ignored: a
 * reporting period cannot be half in one obligation year and half in the next,
 * and month granularity is the finest the reporting scheme has.
 *
 * ## The mapping
 *
 * Months 0–11 after the start month are year 1, 12–23 are year 2, and so on —
 * which is what makes §2's "15% in years 1–2, 30% thereafter" resolve to 30%
 * from the twenty-fifth month.
 */
function obligationYearAt(organization, periodId) {
  const startDate = organization?.obligationStartDate?.toDate?.() ?? null;
  if (!startDate || Number.isNaN(startDate.getTime())) return null;
  if (!eprPeriod.isValidPeriodId(periodId)) return null;

  // The Dhaka calendar month the obligation started in. Fixed +6, as
  // everywhere else in this module.
  const startDhaka = new Date(startDate.getTime() + 6 * 60 * 60 * 1000);
  const startYear = startDhaka.getUTCFullYear();
  const startMonth = startDhaka.getUTCMonth();

  const [periodYear, periodMonth] = periodId
    .split('-')
    .map((part) => Number(part));

  const monthsElapsed =
    (periodYear - startYear) * 12 + (periodMonth - 1 - startMonth);

  if (monthsElapsed < 0) return null;
  return Math.floor(monthsElapsed / 12) + 1;
}

/**
 * Issues a passport (EPR-28, EPR-31).
 *
 * Admin-only, because issuance is Chokro putting its name to a figure. The
 * serial, the hash and the timestamp are all minted here — the three things
 * EPR-31 names as the reason a client-rendered certificate can never be the
 * authoritative artefact.
 */
async function issuePassport({ orgId, periodId, scope = 'period', adminUid, adminName = '' }) {
  if (!eprPeriod.isValidPeriodId(periodId)) {
    throw badRequest('That is not a reporting period.');
  }

  const figures = await assembleFigures({ orgId, periodId, scope });
  const hash = contentHash(figures);

  // ==========================================================================
  // PROVE IT CAN BE RENDERED BEFORE COMMITTING TO IT
  // ==========================================================================
  //
  // The renderer refuses text neither bundled face can draw, rather than
  // printing mojibake. Without this check that refusal arrives too late:
  // issuance succeeds, the PDF route answers 422 forever, and — because
  // issuing SUPERSEDES every earlier certificate for the period — the
  // producer's last downloadable certificate has already been invalidated.
  // An Admin would have destroyed a working certificate to mint an
  // undownloadable one.
  //
  // Rendered outside the transaction, because it is a pure function of the
  // figures and holding a transaction open across two PDF renders would be
  // absurd. Both editions, because NFR-E-4 promises both and a producer that
  // can only download English has not been given what the certificate claims.
  //
  // Issuance is Admin-triggered and rare, so two renders is a cost worth
  // paying to never issue a certificate nobody can read.
  await assertRenderable({ figures, hash, serial: 'CHKR-PP-PREFLIGHT', periodId, orgId });

  const firestore = db();
  const now = admin.firestore.Timestamp.now();
  const declarationRef = firestore
    .collection(declarations.DECLARATIONS)
    .doc(declarations.documentId(orgId, periodId));

  // Retried on the astronomically unlikely serial collision rather than
  // trusting randomness blindly. A collision would overwrite an issued
  // certificate, which is the one thing EPR-30 forbids outright.
  for (let attempt = 0; attempt < 5; attempt += 1) {
    const serial = generateSerial();
    const ref = firestore.collection(PASSPORTS).doc(serial);

    try {
      return await firestore.runTransaction(async (txn) => {
        const existing = await txn.get(ref);
        if (existing.exists) throw new Error('serial_collision');

        // ===================================================================
        // THE DENOMINATOR HAS TO BE READ IN HERE, NOT JUST OUTSIDE
        // ===================================================================
        //
        // `assembleFigures` above runs OUTSIDE this transaction, so Firestore's
        // concurrency control does not cover the declaration it read. That
        // leaves a window with no happens-before edge between issuing and
        // correcting, and the interleaving that falls through it is not
        // recoverable by anything else in this codebase:
        //
        //   1. `assembleFigures` reads declaration v1 and computes 25%.
        //   2. `openCorrection` runs. Its query for passports with
        //      `status == 'issued'` finds NOTHING, because this certificate has
        //      not been written yet. It withdraws v1 and returns.
        //   3. This transaction commits a certificate stating 25% against a
        //      denominator that no longer exists.
        //
        // Nothing sweeps that up afterwards. `openCorrection` has already run
        // and found nothing, `submitDeclaration` supersedes no passports, and
        // the verification endpoint answers `found: true, status: 'issued'`
        // for as long as the record stands.
        //
        // Reading the document here puts it under the transaction's read set,
        // so a correction committing first forces a retry. And because
        // `assembleFigures` is outside the closure, the retry would re-use the
        // same stale figures — so the fingerprint is compared and the whole
        // issuance is abandoned rather than retried with numbers that are
        // already wrong.
        const declarationNow = await txn.get(declarationRef);
        const fingerprintNow = declarationFingerprint(
          declarationNow.exists ? declarationNow.data() : null,
        );

        if (fingerprintNow !== figures.declarationFingerprint) {
          throw conflict(
            'The put-on-market declaration for this period changed while the '
              + 'certificate was being issued, so its figures are already out '
              + 'of date. Nothing was issued. Try again.',
          );
        }

        // Every currently-issued passport for this organisation and period.
        // Reissue supersedes rather than duplicating (EPR-30), so a third party
        // holding the old one can discover from the endpoint that it has been
        // replaced.
        const previous = await txn.get(
          firestore
            .collection(PASSPORTS)
            .where('orgId', '==', orgId)
            .where('periodId', '==', periodId)
            .where('scope', '==', scope)
            .where('status', '==', 'issued')
            .limit(20),
        );

        await audit.appendInTransaction(txn, {
          orgId,
          action: audit.ACTIONS.PASSPORT_ISSUED,
          actorUid: adminUid,
          actorName: adminName,
          actorRole: 'admin',
          targetType: 'passport',
          targetId: serial,
          summary:
            `Plastic Passport ${serial} issued for ${periodId}: ` +
            `${Math.round(figures.collectedMassMg / MG_PER_KILOGRAM)} kg collected` +
            (figures.collectionRate === null
              ? ', no collection percentage (no put-on-market declaration filed)'
              : `, ${(figures.collectionRate * 100).toFixed(1)}% of declared`) +
            (previous.size > 0
              ? `. ${previous.size} earlier ${previous.size === 1 ? 'passport' : 'passports'} superseded.`
              : '.'),
          after: { serial, contentHash: hash },
        });

        for (const doc of previous.docs) {
          txn.update(doc.ref, {
            status: 'superseded',
            supersededBy: serial,
            supersededAt: serverTimestamp(),
            supersededReason: 'A later passport was issued for the same period.',
          });
        }

        txn.set(ref, {
          serial,
          orgId,
          periodId,
          scope,
          status: 'issued',
          // The figure snapshot. Stored, not referenced: a certificate must
          // stay reproducible from its own record even after the period is
          // recomputed or a mass is re-verified (NFR-E-8).
          figures,
          contentHash: hash,
          canonicalPayloadLength: canonicalPayload(figures).length,
          issuedBy: adminUid,
          issuedByName: adminName,
          issuedAt: now,
          supersededBy: null,
          supersededAt: null,
          supersededReason: null,
          revokedBy: null,
          revokedAt: null,
          revocationReason: null,
          createdAt: serverTimestamp(),
        });

        return {
          serial,
          orgId,
          periodId,
          scope,
          contentHash: hash,
          supersededCount: previous.size,
          issuedAt: now.toDate().toISOString(),
        };
      });
    } catch (err) {
      if (err.message === 'serial_collision') continue;
      // A stale-denominator conflict is deliberately NOT retried here: a retry
      // would re-run the transaction with the same figures `assembleFigures`
      // already computed, which are the figures that are wrong. The caller
      // re-issues, which recomputes them.
      throw err;
    }
  }

  throw new Error('Could not mint a unique serial. Try again.');
}

/**
 * Revokes a passport (EPR-30).
 *
 * Admin-only, always with a recorded reason, and always visible on the
 * verification endpoint — which is the point: a revoked certificate that still
 * verified as issued would be worse than no verification at all.
 */
async function revokePassport({ serial, reason, adminUid, adminName = '' }) {
  if (!isValidSerial(serial)) throw badRequest('That is not a passport serial.');
  if (typeof reason !== 'string' || reason.trim().length < 5) {
    throw badRequest('Record why this passport is being revoked.');
  }

  const firestore = db();
  const ref = firestore.collection(PASSPORTS).doc(serial);

  return firestore.runTransaction(async (txn) => {
    const snap = await txn.get(ref);
    if (!snap.exists) throw badRequest('That passport does not exist.');

    const passport = snap.data();
    if (passport.status === 'revoked') {
      throw conflict('That passport has already been revoked.');
    }

    await audit.appendInTransaction(txn, {
      orgId: passport.orgId,
      action: audit.ACTIONS.PASSPORT_REVOKED,
      actorUid: adminUid,
      actorName: adminName,
      actorRole: 'admin',
      targetType: 'passport',
      targetId: serial,
      summary: `Plastic Passport ${serial} revoked: ${reason.trim()}`,
      before: { status: passport.status },
      after: { status: 'revoked' },
    });

    txn.update(ref, {
      status: 'revoked',
      revokedBy: adminUid,
      revokedAt: serverTimestamp(),
      revocationReason: reason.trim().slice(0, 500),
    });

    return { serial, status: 'revoked' };
  });
}

/**
 * The public verification response (EPR-29, SEC-7).
 *
 * ## Deliberately impoverished, and the list is exhaustive
 *
 * EPR-29 names exactly five things: whether the serial exists, its status, the
 * organisation's **trade** name, the period, and the content hash. It returns
 * "no figures, no evidence, no member details, no contact information", and its
 * purpose is only "to let a third party confirm that the PDF in their hand is
 * the document Chokro issued and has not been superseded — nothing more".
 *
 * Trade name and not legal name, because the trade name is what the certificate
 * itself prints and what a journalist or a buyer would recognise; the legal name
 * is registry data.
 *
 * ## Why an unknown serial and a revoked one look the same shape
 *
 * SEC-7: the endpoint "returns the same shape for unknown and revoked serials
 * rather than distinguishing them by error class". A 404 for unknown and a 200
 * for revoked would let an enumerator separate real serials from guesses by
 * status code alone, and the whole point of an unguessable serial is that a miss
 * teaches nothing.
 */
async function verifySerial(serial) {
  const notFound = {
    found: false,
    status: null,
    tradeName: null,
    periodId: null,
    contentHash: null,
  };

  // A malformed serial is answered as not-found rather than as a validation
  // error, for the same enumeration reason.
  if (!isValidSerial(serial)) return notFound;

  try {
    const snap = await db().collection(PASSPORTS).doc(serial).get();
    if (!snap.exists) return notFound;

    const passport = snap.data();
    const status = PASSPORT_STATUSES.includes(passport.status)
      ? passport.status
      : 'revoked';

    return {
      found: true,
      status,
      // The trade name only. Not the legal name, not the DoE number, not a
      // contact, not a figure.
      tradeName: passport.figures?.organizationTradeName ?? null,
      periodId: passport.periodId ?? null,
      contentHash: passport.contentHash ?? null,
      // Present only when the certificate has been replaced, so the holder of
      // an old one can find the current one. Not a figure and not evidence.
      supersededBy: status === 'superseded' ? passport.supersededBy ?? null : null,
    };
  } catch (err) {
    // A read failure must not become a "not found", because that would tell a
    // holder their genuine certificate is fake. Raised so the route can answer
    // 503 and the reader can try again.
    console.error(`[passports] verification of ${serial} failed:`, err.message);
    throw new Error('verification_unavailable');
  }
}

/**
 * Refuses figures the renderer cannot turn into a certificate.
 *
 * Required lazily: `passportPdf` requires this module for
 * `GAZETTE_CATEGORIES`, so a top-level require would be a cycle. Lazy here
 * rather than restructuring, because the dependency is genuinely one-directional
 * at every other moment — only issuance needs to render.
 */
async function assertRenderable({ figures, hash, serial, periodId, orgId }) {
  // eslint-disable-next-line global-require
  const passportPdf = require('./passportPdf');

  for (const locale of passportPdf.LOCALES) {
    try {
      await passportPdf.renderPassportPdf({
        passport: {
          serial,
          orgId,
          periodId,
          status: 'issued',
          figures,
          contentHash: hash,
          issuedAt: new Date(),
          issuedByName: 'preflight',
          locale,
        },
        verifyBaseUrl: 'https://chokro.app',
      });
    } catch (err) {
      if (err.code === 'unrenderable_text') {
        const error = new Error(
          `This period cannot be certified as it stands: ${err.message} `
            + 'Nothing was issued, and any existing certificate for this period '
            + 'still stands.',
        );
        error.code = 'unrenderable_text';
        error.codePoint = err.codePoint;
        error.locale = locale;
        throw error;
      }
      throw err;
    }
  }
}

/** One organisation's passports, newest first. Bounded (QA-10). */
async function listPassports({ orgId, limit = 50 }) {
  const snap = await db()
    .collection(PASSPORTS)
    .where('orgId', '==', orgId)
    .orderBy('issuedAt', 'desc')
    .limit(limit)
    .get();
  return snap.docs.map((d) => ({ id: d.id, ...d.data() }));
}

async function getPassport(serial) {
  if (!isValidSerial(serial)) return null;
  const snap = await db().collection(PASSPORTS).doc(serial).get();
  return snap.exists ? { id: snap.id, ...snap.data() } : null;
}

/**
 * Supersedes every issued passport whose evidence has changed underneath it
 * (EPR-30).
 *
 * "Any of these events must supersede every affected passport automatically and
 * notify the organisation: a corrected put-on-market declaration, a re-verified
 * unit mass that changes a period already certified, a reversed attribution
 * above a policy materiality threshold, or an accuracy audit that invalidates a
 * batch of matches."
 *
 * The declaration case is handled inside `declarations.openCorrection`, in the
 * same transaction as the correction. This is the handle for the other three,
 * which happen in paths that should not have to know about certificates.
 */
async function supersedeForPeriod({ orgId, periodId, reason, actorUid }) {
  if (!eprPeriod.isValidPeriodId(periodId)) return { superseded: 0 };

  const firestore = db();

  const affected = await firestore
    .collection(PASSPORTS)
    .where('orgId', '==', orgId)
    .where('periodId', '==', periodId)
    .where('status', '==', 'issued')
    .limit(50)
    .get();

  if (affected.empty) return { superseded: 0 };

  const batch = firestore.batch();
  for (const doc of affected.docs) {
    batch.update(doc.ref, {
      status: 'superseded',
      supersededAt: serverTimestamp(),
      supersededReason: String(reason || 'The underlying evidence changed.').slice(0, 500),
      supersededBy: null,
    });
  }
  await batch.commit();

  await audit.append({
    orgId,
    action: audit.ACTIONS.PASSPORT_SUPERSEDED,
    actorUid: actorUid || 'system',
    actorRole: 'admin',
    targetType: 'passport',
    targetId: periodId,
    summary:
      `${affected.size} ${affected.size === 1 ? 'passport' : 'passports'} for ` +
      `${periodId} superseded: ${reason}`,
  });

  return { superseded: affected.size };
}

/**
 * Supersedes certificates after an attribution is reversed (EPR-30).
 *
 * ## Why this is a separate function and not a call inside `reverseAttribution`
 *
 * `passports.js` already requires `eprPeriods.js`, so calling back the other
 * way would be a cycle. More importantly, this must run AFTER the reversal
 * commits, for the same reason attribution runs after the disposal decision
 * commits: a supersession failing must not roll back a reversal an Admin has
 * decided on and recorded a reason for.
 *
 * ## Why a materiality threshold
 *
 * EPR-30 says "a reversed attribution above a policy materiality threshold",
 * and the threshold is the point. A single mis-recognised bottle removed from a
 * month does not make a certificate wrong, and superseding on every correction
 * would teach producers and their customers to ignore the status — which would
 * make supersession useless exactly when it matters.
 *
 * Never throws: the caller has already committed the reversal.
 */
async function supersedeForReversal({ orgId, periodId, massMg, actorUid }) {
  try {
    if (!eprPeriod.isValidPeriodId(periodId)) return { superseded: 0 };

    const [period, policy] = await Promise.all([
      eprPeriods.getPeriod({ orgId, periodId }),
      eprPolicy.readPolicy(),
    ]);

    // The mass the certificates for this period were computed over — which is
    // the post-reversal figure plus what was just removed, since the rollup has
    // already been decremented.
    const certifiedMassMg =
      Object.values(period?.massMgByCategory ?? {}).reduce(
        (sum, mg) => sum + intOr0(mg),
        0,
      ) + intOr0(massMg);

    if (certifiedMassMg <= 0) return { superseded: 0 };

    const fraction = intOr0(massMg) / certifiedMassMg;
    if (fraction < policy.reversalMaterialityFraction) {
      return { superseded: 0, fraction, immaterial: true };
    }

    return await supersedeForPeriod({
      orgId,
      periodId,
      reason:
        `An attribution of ${Math.round(intOr0(massMg) / MG_PER_KILOGRAM)} kg `
        + `was reversed after review — ${(fraction * 100).toFixed(1)}% of the `
        + 'mass this certificate was computed over.',
      actorUid,
    });
  } catch (err) {
    // Logged, never rethrown. The reversal is already committed and correct;
    // failing here must not turn an Admin's correction into an error they
    // conclude did not take effect.
    console.error(
      `[passports] supersession after reversal in ${orgId}/${periodId} failed:`,
      err.message,
    );
    return { superseded: 0, error: err.message };
  }
}

/**
 * Supersedes certificates after a unit mass is re-verified (EPR-30).
 *
 * "a re-verified unit mass that changes a period already certified". A
 * certificate's mass is units multiplied by the unit mass Chokro established;
 * establishing a different one makes every period that used the old figure
 * state a mass Chokro no longer stands behind.
 *
 * Every period with an issued certificate for this organisation is swept,
 * because a SKU sold across a year appears in a year of periods and the
 * re-verification does not know which. Bounded, and never throws.
 */
async function supersedeForMassChange({ orgId, skuId, actorUid, reason }) {
  try {
    const issued = await db()
      .collection(PASSPORTS)
      .where('orgId', '==', orgId)
      .where('status', '==', 'issued')
      .limit(50)
      .get();

    if (issued.empty) return { superseded: 0 };

    // Distinct periods, so one call per period rather than one per certificate.
    const periods = [...new Set(issued.docs.map((d) => d.data().periodId))];

    let superseded = 0;
    for (const periodId of periods) {
      const result = await supersedeForPeriod({
        orgId,
        periodId,
        reason:
          reason
          || `The verified unit mass of ${skuId} changed, so this period's `
            + 'collected mass is no longer the figure this certificate states.',
        actorUid,
      });
      superseded += result.superseded;
    }

    return { superseded, periods: periods.length };
  } catch (err) {
    console.error(
      `[passports] supersession after a mass change in ${orgId} failed:`,
      err.message,
    );
    return { superseded: 0, error: err.message };
  }
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
  PASSPORTS,
  GAZETTE_CATEGORIES,
  SERIAL_ALPHABET,
  SERIAL_PATTERN,
  PASSPORT_STATUSES,
  generateSerial,
  isValidSerial,
  canonicalPayload,
  contentHash,
  assembleFigures,
  assertRenderable,
  declarationFingerprint,
  obligationYearAt,
  resolveCarbon,
  issuePassport,
  revokePassport,
  verifySerial,
  listPassports,
  getPassport,
  supersedeForPeriod,
  supersedeForReversal,
  supersedeForMassChange,
};
