/**
 * Every composite query has an index (QA-10, NFR-E-3).
 *
 * ===========================================================================
 * WHY THIS TEST EXISTS
 * ===========================================================================
 *
 * A missing composite index is invisible to every other test in this
 * repository. The in-memory fake filters and sorts in JavaScript, so a query
 * that real Firestore would refuse with FAILED_PRECONDITION passes here
 * happily — and the route's own `catch` turns the production failure into a
 * 503, so it presents as an endpoint that is simply always broken.
 *
 * That is exactly what happened: `reportJobs` was written after the index pass
 * and got no index at all, so `GET /epr/reports` — the job list and the
 * report-type catalogue clients are told not to hardcode — would have failed on
 * its first production call. 58 server tests covered that module and none could
 * have caught it.
 *
 * ===========================================================================
 * WHAT IT CHECKS
 * ===========================================================================
 *
 * Firestore needs a composite index for any query that combines filters with an
 * ordering on a different field, or that filters on more than one field. This
 * reads the query chains out of the source and checks each one against
 * `firestore.indexes.json`.
 *
 * It is a static approximation, not a Firestore planner. It will not catch
 * every index a real deployment needs, and it deliberately errs toward
 * demanding an index rather than assuming one is unnecessary — a spurious index
 * costs storage, and a missing one costs an endpoint.
 */

const fs = require('fs');
const path = require('path');

const SRC = path.resolve(__dirname, '../src');
const INDEXES = path.resolve(__dirname, '../../firestore.indexes.json');

const declared = JSON.parse(fs.readFileSync(INDEXES, 'utf8')).indexes;

/**
 * The query chains in one module.
 *
 * Matches `.collection('name')` and then the `where`/`orderBy` calls that
 * follow it, stopping at `.get(`, `.doc(` or a statement boundary. Comments are
 * stripped first, so a query written out in prose is not mistaken for one in
 * code.
 */
function queriesIn(source) {
  const code = source
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/\/\/[^\n]*/g, '');

  const queries = [];
  const collectionPattern = /\.collection\(\s*['"`]([^'"`]+)['"`]\s*\)|\.collection\(\s*([A-Za-z_$][\w$.]*)\s*\)/g;

  let match = collectionPattern.exec(code);
  while (match !== null) {
    const rawName = match[1] ?? match[2];
    // A chain runs until the terminating `.get(` — long enough for a
    // multi-line builder, bounded so it cannot swallow the next statement.
    const tail = code.slice(match.index, match.index + 900);
    const stop = tail.indexOf('.get(');
    const chain = stop === -1 ? tail.slice(0, 400) : tail.slice(0, stop);

    const filters = [...chain.matchAll(/\.where\(\s*([^,]+),\s*['"`]([^'"`]+)['"`]/g)].map(
      (m) => ({ field: fieldNameOf(m[1]), op: m[2] }),
    );
    const orders = [...chain.matchAll(/\.orderBy\(\s*([^,)]+)/g)].map((m) =>
      fieldNameOf(m[1]),
    );

    if (filters.length > 0 || orders.length > 0) {
      queries.push({ collection: resolveName(rawName), filters, orders, chain });
    }
    match = collectionPattern.exec(code);
  }

  return queries;
}

/** `'orgId'` or `admin.firestore.FieldPath.documentId()` to a field name. */
function fieldNameOf(raw) {
  const trimmed = raw.trim();
  const quoted = /^['"`]([^'"`]+)['"`]$/.exec(trimmed);
  if (quoted) return quoted[1];
  if (/documentId\(\)/.test(trimmed)) return '__name__';
  return null;
}

/**
 * A collection name that was written as a constant.
 *
 * The modules hold their collection names in module constants, so the literal
 * is not at the call site. Resolved from the known set rather than by
 * evaluating the source.
 */
const CONSTANTS = {
  PASSPORTS: 'plasticPassports',
  DECLARATIONS: 'putOnMarketDeclarations',
  VERSIONS: 'putOnMarketVersions',
  JOBS: 'reportJobs',
  ATTRIBUTIONS: 'attributions',
  SKUS: 'producerSkus',
  REVISIONS: 'skuRevisions',
  AUDITS: 'skuMassAudits',
  ORGS: 'organizations',
  MEMBERS: 'organizationMembers',
  INVITATIONS: 'orgInvitations',
  CONFIRMATIONS: 'attributionConfirmations',
  PERIODS: 'eprPeriods',
  COLLECTION: 'producerAuditLog',
  HEAD_COLLECTION: 'auditChainHeads',
  'passports.PASSPORTS': 'plasticPassports',
  'audit.COLLECTION': 'producerAuditLog',
  'declarations.DECLARATIONS': 'putOnMarketDeclarations',
};

function resolveName(raw) {
  return CONSTANTS[raw] ?? raw;
}

/** Whether a declared index covers this query. */
function isCovered(query) {
  const equality = query.filters
    .filter((f) => f.op === '==' && f.field)
    .map((f) => f.field);
  const ranges = query.filters
    .filter((f) => f.op !== '==' && f.field)
    .map((f) => f.field);
  const ordered = query.orders.filter(Boolean);

  const needed = [...new Set([...equality, ...ranges, ...ordered])];

  // A single-field query is served by the automatic single-field index.
  if (needed.length <= 1) return true;

  // `__name__` is appended to every composite index implicitly, so a query
  // ordering by it needs the rest covered.
  const required = needed.filter((f) => f !== '__name__');
  if (required.length <= 1) return true;

  return declared.some((index) => {
    if (index.collectionGroup !== query.collection) return false;
    const fields = index.fields.map((f) => f.fieldPath);
    return required.every((f) => fields.includes(f));
  });
}

const MODULES = fs
  .readdirSync(SRC)
  .filter((f) => f.endsWith('.js'))
  .sort();

test('the index file parses and is not empty', () => {
  // The canary. Every assertion below passes vacuously against an empty list.
  expect(Array.isArray(declared)).toBe(true);
  expect(declared.length).toBeGreaterThan(20);
  for (const index of declared) {
    expect(index.queryScope).toBe('COLLECTION');
    expect(index.fields.length).toBeGreaterThan(0);
  }
});

test('the query parser actually finds queries', () => {
  // The second canary. If the parser stops matching — a refactor to a query
  // builder, a formatting change — the coverage test would pass on nothing.
  const found = MODULES.flatMap((m) =>
    queriesIn(fs.readFileSync(path.join(SRC, m), 'utf8')),
  );
  expect(found.length).toBeGreaterThan(20);
  expect(found.some((q) => q.collection === 'reportJobs')).toBe(true);
  expect(found.some((q) => q.collection === 'plasticPassports')).toBe(true);
});

describe('every composite query is indexed', () => {
  for (const module of MODULES) {
    const queries = queriesIn(fs.readFileSync(path.join(SRC, module), 'utf8'));
    const composite = queries.filter((q) => !isCovered(q));

    test(`${module}`, () => {
      const uncovered = composite.map((q) => {
        const fields = [
          ...q.filters.map((f) => `${f.field} ${f.op}`),
          ...q.orders.map((o) => `orderBy ${o}`),
        ].join(', ');
        return `${q.collection}: ${fields}`;
      });

      // A missing index does not fail any other test in this repository: the
      // fake filters in JavaScript, and the route's catch turns the production
      // FAILED_PRECONDITION into a 503.
      expect(uncovered).toEqual([]);
    });
  }
});
