/**
 * Every EPR route carries the guards it needs (SEC-1, SEC-2, EPR-3).
 *
 * ===========================================================================
 * WHY THIS IS A SOURCE-LEVEL TEST
 * ===========================================================================
 *
 * The tenancy boundary in this system is a middleware chain. `requireOrgRole`
 * is what resolves the caller's membership and puts `req.orgMembership` on the
 * request, and every producer route reads its own organisation from there
 * rather than from a path parameter or a body field — which is the whole
 * mechanism by which one producer cannot read another's compliance position.
 *
 * A route that forgets it does not fail. `req.orgMembership` is `undefined`,
 * `req.orgMembership.orgId` throws, and the handler's own `catch` turns that
 * into a 503 — so the fault presents as a flaky endpoint rather than as a
 * missing authorisation check. Worse, a route that uses `requireProducer`
 * *without* `requireOrgRole` authenticates that the caller is some producer and
 * never establishes which one.
 *
 * There is no express test harness in this project (no supertest), so these
 * assertions read the route table out of the source. That is a weaker test than
 * exercising the app, and it is a much stronger test than none — it catches the
 * omission that actually happens, which is a new route pasted from a neighbour
 * with a guard dropped.
 */

const fs = require('fs');
const path = require('path');

const SOURCE = fs.readFileSync(
  path.resolve(__dirname, '../src/index.js'),
  'utf8',
);

/**
 * The route table, read out of the source.
 *
 * Matches `app.<method>('<path>', <middleware...>, async (req, res)` and
 * captures everything between the path and the handler. Comments inside the
 * chain are stripped, so a route explaining *why* it omits a guard is not
 * credited with having it.
 */
function routeTable() {
  const routes = [];
  const pattern =
    /app\.(get|post|put|patch|delete)\(\s*'([^']+)'\s*,([\s\S]*?)(?:async\s*)?\(req,\s*res\)/g;

  let match = pattern.exec(SOURCE);
  while (match !== null) {
    const [, method, routePath, rawChain] = match;
    const chain = rawChain
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/\/\/[^\n]*/g, '');

    routes.push({
      method: method.toUpperCase(),
      path: routePath,
      chain,
      has: (guard) => new RegExp(`\\b${guard}\\b`).test(chain),
    });
    match = pattern.exec(SOURCE);
  }
  return routes;
}

const ROUTES = routeTable();

const eprRoutes = () => ROUTES.filter((r) => r.path.startsWith('/epr/'));

/**
 * A route is an admin route because it carries `requireAdmin`, not because of
 * where it sits in the path.
 *
 * `POST /epr/config/policy` is admin-guarded and lives outside `/epr/admin/`,
 * so classifying by path would have called it a producer route and then failed
 * it for not resolving an organisation membership it correctly never resolves.
 * The guard is the authority on what a route is.
 */
const adminRoutes = () => eprRoutes().filter((r) => r.has('requireAdmin'));

/**
 * The routes that are reachable before a membership exists.
 *
 * Both are deliberate and neither can resolve an organisation:
 *
 *  - `/epr/password-policy` is read by the registration form to show the
 *    password rules, which has to happen before there is an account.
 *  - `/epr/invitations/redeem` is how an invited person becomes a member in
 *    the first place, so requiring membership would make it unreachable. It
 *    carries `redeemLimit`, a limiter of its own.
 *
 * Listed here rather than pattern-matched, so adding a third public EPR route
 * is a decision somebody has to write down.
 */
const PRE_MEMBERSHIP = Object.freeze([
  'GET /epr/password-policy',
  'POST /epr/invitations/redeem',
]);

const producerRoutes = () =>
  eprRoutes().filter(
    (r) => !r.has('requireAdmin') && !PRE_MEMBERSHIP.includes(`${r.method} ${r.path}`),
  );

test('the pre-membership allowlist has not silently grown', () => {
  // The list above is only meaningful if something checks that the routes on
  // it are still the only unauthenticated ones under `/epr/`.
  const open = eprRoutes()
    .filter((r) => !r.has('requireAuth'))
    .map((r) => `${r.method} ${r.path}`)
    .sort();
  expect(open).toEqual([...PRE_MEMBERSHIP].sort());
});

test('the route table was actually parsed', () => {
  // If the parser stops matching — a formatting change, a refactor to a
  // router — every assertion below would pass on an empty list. This is the
  // canary.
  expect(ROUTES.length).toBeGreaterThan(30);
  expect(eprRoutes().length).toBeGreaterThan(15);
  expect(adminRoutes().length).toBeGreaterThan(4);
  expect(ROUTES.some((r) => r.path === '/passports/verify/:serial')).toBe(true);
});

describe('every producer EPR route', () => {
  test('establishes which organisation is calling', () => {
    // `requireProducer` alone authenticates that the caller is *a* producer and
    // never says which one; `requireOrgRole` is what resolves the membership and
    // puts `req.orgMembership` on the request.
    //
    // Two routes legitimately have no organisation to resolve, because neither
    // returns tenant data:
    //
    //  - `GET /epr/me` answers "which organisations am I in", which is the
    //    question asked *before* a membership has been chosen.
    //  - `GET /epr/config/policy` returns the shared EPR policy — thresholds
    //    and tolerances that are the same for every producer.
    //
    // Asserted as an exact list rather than filtered out, so a third route
    // joining them is a change somebody has to justify here.
    const missing = producerRoutes()
      .filter((r) => !r.has('requireOrgRole'))
      .map((r) => `${r.method} ${r.path}`)
      .sort();
    expect(missing).toEqual(['GET /epr/config/policy', 'GET /epr/me']);
  });

  test('reads its organisation from the resolved membership, never from the path', () => {
    // The tenancy boundary. A producer route that took `orgId` from a path
    // parameter or a body field would let any member of any organisation name
    // another one (SEC-1).
    const offenders = producerRoutes()
      .filter((r) => /:orgId/.test(r.path))
      .map((r) => `${r.method} ${r.path}`);
    expect(offenders).toEqual([]);
  });

  test('is authenticated', () => {
    const missing = producerRoutes()
      .filter((r) => !r.has('requireAuth'))
      .map((r) => `${r.method} ${r.path}`);
    expect(missing).toEqual([]);
  });

  test('is rate limited', () => {
    // QA-10's bounded reads have a matching requirement here: an unbounded
    // endpoint on a free instance is a denial of service against every other
    // tenant.
    const missing = producerRoutes()
      .filter(
        (r) =>
          !r.has('readLimit')
          && !r.has('writeLimit')
          && !r.has('eprWriteLimit')
          && !r.has('rateLimit'),
      )
      .map((r) => `${r.method} ${r.path}`);
    expect(missing).toEqual([]);
  });
});

describe('every admin EPR route', () => {
  test('requires an admin', () => {
    const missing = adminRoutes()
      .filter((r) => !r.has('requireAdmin'))
      .map((r) => `${r.method} ${r.path}`);
    expect(missing).toEqual([]);
  });

  test('never uses requireOrgRole, which would resolve the admin as a member', () => {
    // An Admin is not a member of the organisation it is acting on.
    // An Admin is not a member of the organisation it is acting on, so
    // `requireOrgRole` would refuse — and a route that had both would be
    // unreachable rather than doubly guarded.
    const wrong = adminRoutes()
      .filter((r) => r.has('requireOrgRole'))
      .map((r) => `${r.method} ${r.path}`);
    expect(wrong).toEqual([]);
  });
});

/**
 * POST routes that READ rather than write.
 *
 * A verb is not a good classifier for what a route does to stored state, and
 * these two genuinely do not create or change a compliance record:
 *
 *  - `/epr/reports/:jobId/download` mints a short-lived signed URL for an
 *    artefact that already exists. It must NOT require a writable workspace:
 *    suspension makes a workspace read-only and "existing records and
 *    documents stay available", and a producer that has just been suspended is
 *    precisely the one who needs to download its own records to answer
 *    questions about them. Locking that behind `requireActiveOrganization`
 *    would turn suspension into evidence destruction.
 *  - `/epr/reports/:jobId/resume` restarts a job that already exists, and
 *    `runJob` is idempotent on the job document. It does keep
 *    `requireActiveOrganization`, because it can still produce a new artefact.
 *
 * Listed rather than pattern-matched, so adding a third read-only POST is a
 * decision somebody has to write down here.
 */
const READ_ONLY_POSTS = Object.freeze(['POST /epr/reports/:jobId/download']);

describe('every producer EPR write route', () => {
  const writes = () =>
    producerRoutes().filter(
      (r) =>
        r.method !== 'GET' && !READ_ONLY_POSTS.includes(`${r.method} ${r.path}`),
    );

  test('uses the stricter EPR write limiter', () => {
    // `eprWriteLimit` is 20/minute against `writeLimit`'s 30. EPR writes are
    // compliance records, and a burst of them is far more likely to be a script
    // than a person filling in a form.
    const wrong = writes()
      .filter((r) => !r.has('eprWriteLimit'))
      .map((r) => `${r.method} ${r.path}`);
    expect(wrong).toEqual([]);
  });

  test('refuses a suspended workspace', () => {
    // A suspended organisation is read-only: existing records and certificates
    // stay available, and nothing new can be filed or issued. Without this a
    // suspended producer could keep changing the denominator its already-issued
    // certificates were computed against.
    const wrong = writes()
      .filter((r) => !r.has('requireActiveOrganization'))
      .map((r) => `${r.method} ${r.path}`);
    expect(wrong).toEqual([]);
  });

  test('requires a verified address', () => {
    const wrong = writes()
      .filter((r) => !r.has('requireVerifiedEmail'))
      .map((r) => `${r.method} ${r.path}`);
    expect(wrong).toEqual([]);
  });
});

describe('the read-only POST routes', () => {
  test('still resolve a membership and are still rate limited', () => {
    // Being a read does not make them ungoverned: each one still has to know
    // which organisation is asking, and each one writes an audit entry, which
    // makes it worth a limit.
    for (const key of READ_ONLY_POSTS) {
      const [method, path] = key.split(' ');
      const r = ROUTES.find((x) => x.method === method && x.path === path);
      expect(r).toBeTruthy();
      expect(r.has('requireAuth')).toBe(true);
      expect(r.has('requireOrgRole')).toBe(true);
      expect(r.has('eprWriteLimit') || r.has('writeLimit') || r.has('readLimit'))
        .toBe(true);
    }
  });

  test('are the only producer POSTs without requireActiveOrganization', () => {
    // The inverse of the exception list, so the list cannot quietly stop
    // matching reality.
    const missing = producerRoutes()
      .filter((r) => r.method !== 'GET' && !r.has('requireActiveOrganization'))
      .map((r) => `${r.method} ${r.path}`)
      .sort();
    // `/epr/invitations/redeem` is not in this set: it is already excluded by
    // PRE_MEMBERSHIP, having no membership to resolve at all.
    expect(missing).toEqual([...READ_ONLY_POSTS].sort());
  });
});

// ---------------------------------------------------------------------------
// The routes this phase added
// ---------------------------------------------------------------------------

const route = (method, routePath) => {
  const found = ROUTES.find((r) => r.method === method && r.path === routePath);
  if (!found) throw new Error(`No route registered for ${method} ${routePath}`);
  return found;
};

describe('declaration routes (EPR-40 to EPR-43)', () => {
  test('drafting is a reporter action', () => {
    expect(route('PUT', '/epr/declarations/:periodId').chain)
      .toMatch(/requireOrgRole\('orgReporter'\)/);
  });

  test('attesting is an owner action, and needs a verified address', () => {
    // Submitting is signing. The attestation names a person and states that a
    // false figure may cost the company its registration, so it is not a
    // data-entry step — and the person signing must have proved the address
    // the record will name.
    for (const p of [
      '/epr/declarations/:periodId/submit',
      '/epr/declarations/:periodId/correct',
    ]) {
      const r = route('POST', p);
      expect(r.chain).toMatch(/requireOrgRole\('orgOwner'\)/);
      expect(r.has('requireVerifiedEmail')).toBe(true);
      expect(r.has('requireActiveOrganization')).toBe(true);
    }
  });

  test('correcting needs a fresh session, because it invalidates certificates', () => {
    // EPR-30: a correction supersedes every passport issued for the period,
    // including copies already in a customer's or a regulator's hands.
    expect(route('POST', '/epr/declarations/:periodId/correct').has('requireFreshAuth'))
      .toBe(true);
  });

  test('reading is open to a viewer', () => {
    expect(route('GET', '/epr/declarations').chain)
      .toMatch(/requireOrgRole\('orgViewer'\)/);
    expect(route('GET', '/epr/declarations/:periodId').chain)
      .toMatch(/requireOrgRole\('orgViewer'\)/);
  });

  test('the review queue is admin-only', () => {
    const r = route('GET', '/epr/admin/declarations/review');
    expect(r.has('requireAdmin')).toBe(true);
    expect(r.has('requireOrgRole')).toBe(false);
  });
});

describe('passport routes (EPR-28 to EPR-31)', () => {
  test('a producer can list and download its own, as a viewer', () => {
    expect(route('GET', '/epr/passports').chain)
      .toMatch(/requireOrgRole\('orgViewer'\)/);
    expect(route('GET', '/epr/passports/:serial.pdf').chain)
      .toMatch(/requireOrgRole\('orgViewer'\)/);
  });

  test('the download checks the certificate’s own organisation', () => {
    // SEC-1. A serial is unguessable but NOT secret — it is printed on a
    // document that gets emailed around — so possession of one must not be
    // authorisation to read another tenant's certificate. Membership is
    // checked against the passport's stored `orgId`, not against the serial.
    const chain = SOURCE.slice(
      SOURCE.indexOf("app.get(\n  '/epr/passports/:serial.pdf'"),
      SOURCE.indexOf("app.post(\n  '/epr/admin/passports/:orgId/:periodId/issue'"),
    );
    expect(chain).toMatch(/passport\.orgId !== req\.orgMembership\.orgId/);
    expect(chain).toMatch(/404/);
  });

  test('issuing and revoking need an admin and a fresh session', () => {
    // Issuance is Chokro putting its name to a figure a third party will rely
    // on; revocation invalidates a document already in circulation.
    for (const p of [
      '/epr/admin/passports/:orgId/:periodId/issue',
      '/epr/admin/passports/:serial/revoke',
    ]) {
      const r = route('POST', p);
      expect(r.has('requireAdmin')).toBe(true);
      expect(r.has('requireFreshAuth')).toBe(true);
    }
  });
});

describe('the public verification endpoint (EPR-29, SEC-7)', () => {
  const verify = () => route('GET', '/passports/verify/:serial');

  test('is deliberately unauthenticated', () => {
    // A certificate's whole value is that a third party can check it without a
    // Chokro account. Requiring one would make verification a
    // Chokro-relationship gate rather than a check.
    expect(verify().has('requireAuth')).toBe(false);
    expect(verify().has('requireOrgRole')).toBe(false);
    expect(verify().has('requireAdmin')).toBe(false);
  });

  test('is rate limited harder than an authenticated read', () => {
    // It is reachable by anybody, and the 40-bit serial space is only a control
    // if guessing is slow.
    expect(verify().chain).toMatch(/rateLimit\(/);
    const max = /max:\s*(\d+)/.exec(verify().chain);
    expect(max).toBeTruthy();
    expect(Number(max[1])).toBeLessThanOrEqual(30);
  });

  test('is the only unauthenticated route under a passport path', () => {
    const open = ROUTES.filter(
      (r) => /passport/i.test(r.path) && !r.has('requireAuth'),
    ).map((r) => `${r.method} ${r.path}`);
    expect(open).toEqual(['GET /passports/verify/:serial']);
  });
});

// ---------------------------------------------------------------------------
// EPR-30's supersession triggers are wired, not merely written
// ---------------------------------------------------------------------------

describe('the events that must supersede a certificate (EPR-30)', () => {
  const SRC = path.resolve(__dirname, '../src');
  const readCode = (name) =>
    fs
      .readFileSync(path.join(SRC, name), 'utf8')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/\/\/[^\n]*/g, '');

  test('every trigger has a production caller', () => {
    // THE GAP THIS EXISTS FOR.
    //
    // `supersedeForPeriod` was written, exported, documented and tested — and
    // called by nothing but its own test file. Three of EPR-30's four triggers
    // were therefore documented rather than implemented, and nothing failed:
    // the function was covered, the requirement was cited in a comment, and no
    // certificate was ever superseded by a reversal.
    //
    // A unit test cannot catch that, because the unit worked. This reads the
    // call graph instead.
    const production = [
      readCode('index.js'),
      readCode('declarations.js'),
      readCode('passports.js'),
      readCode('eprPeriods.js'),
      readCode('producerSkus.js'),
    ].join('\n');

    // A corrected declaration — inside `openCorrection`'s own transaction.
    expect(readCode('declarations.js')).toMatch(/status:\s*'superseded'/);

    // A reversed attribution above the materiality threshold.
    expect(production).toMatch(/supersedeForReversal\(/);

    // A re-verified unit mass.
    expect(production).toMatch(/supersedeForMassChange\(/);
  });

  test('the reversal route supersedes after it reverses', () => {
    const code = readCode('index.js');
    const route = code.slice(
      code.indexOf("'/epr/admin/attributions/:attributionId/reverse'"),
      code.indexOf("'/epr/admin/passports/:orgId/:periodId/issue'"),
    );

    expect(route).toMatch(/reverseAttribution\(/);
    expect(route).toMatch(/supersedeForReversal\(/);
    // Ordering matters: the supersession must not be able to roll back a
    // reversal an Admin has decided on and recorded a reason for.
    expect(route.indexOf('reverseAttribution('))
      .toBeLessThan(route.indexOf('supersedeForReversal('));
  });

  test('the verified-mass route supersedes after it changes the mass', () => {
    const code = readCode('index.js');
    const route = code.slice(
      code.indexOf("'/epr/admin/skus/:skuId/verified-mass'"),
      code.indexOf("'/epr/admin/skus/:skuId/reject'"),
    );

    expect(route).toMatch(/setVerifiedMass\(/);
    expect(route).toMatch(/supersedeForMassChange\(/);
    expect(route.indexOf('setVerifiedMass('))
      .toBeLessThan(route.indexOf('supersedeForMassChange('));
  });

  test('issuance reads the denominator inside its transaction', () => {
    // The other confirmed defect: `assembleFigures` runs outside the
    // transaction, so without a re-check a correction landing mid-issue
    // produces a certificate stating a percentage over a withdrawn
    // denominator — and nothing ever sweeps it up.
    const code = readCode('passports.js');
    const issue = code.slice(
      code.indexOf('async function issuePassport'),
      code.indexOf('async function revokePassport'),
    );

    expect(issue).toMatch(/txn\.get\(declarationRef\)/);
    expect(issue).toMatch(/declarationFingerprint/);
    // Inside the transaction, not before it.
    expect(issue.indexOf('runTransaction'))
      .toBeLessThan(issue.indexOf('txn.get(declarationRef)'));
  });
});
