/**
 * Every client call reaches a route that exists, by the method it uses.
 *
 * ## WHY THIS TEST EXISTS
 *
 * `admin_oversight_service.dart` called `GET /epr/admin/organizations/{id}/view`
 * for weeks. The server registers that route as `app.post` — correctly, because
 * opening a producer's workspace appends an audit entry before it assembles
 * anything (EPR-46), so it is side-effecting however much it reads like a
 * fetch. Express matched no GET route and answered 404 every time. The
 * "Their view" tab could never have worked.
 *
 * Nothing caught it. The widget tests override `organizationViewProvider` and
 * never reach the service; the server tests exercise the handler directly and
 * never see the client's spelling of the path. Both sides were tested, and the
 * seam between them was not.
 *
 * It was found by curling the deployed routes and noticing that the timeline
 * beside it answered 401 while this one answered 404.
 *
 * ## WHAT IT CANNOT CHECK
 *
 * Paths built by string interpolation more elaborate than a bare `$id` — a
 * ternary inside the string, say. Those are counted and REPORTED rather than
 * skipped silently, because a scanner that quietly ignores what it cannot
 * parse reports full coverage of whatever it happened to understand.
 */

const fs = require('fs');
const path = require('path');

const SERVER = path.resolve(__dirname, '../src/index.js');
const SERVICES = path.resolve(__dirname, '../../lib/services');

function stripComments(source) {
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '');
}

/** `:orgId` and `$orgId` both become `{}`, so the two spellings compare. */
function normalise(route) {
  let p = route.split('?')[0];
  p = p.replace(/:[A-Za-z_]\w*/g, '{}');
  p = p.replace(/\$\{[^}]*\}/g, '{}');
  p = p.replace(/\$[A-Za-z_]\w*/g, '{}');
  // A `{}` glued to the end of a segment is an interpolated QUERY STRING
  // (`'/epr/admin/anomalies$query'`), not a path parameter.
  p = p.replace(/(?<=[^/]){}$/, '');
  return p.replace(/\/+$/, '');
}

function serverRoutes() {
  const source = stripComments(fs.readFileSync(SERVER, 'utf8'));
  const byPath = new Map();
  for (const m of source.matchAll(
    /app\.(get|post|put|patch|delete)\(\s*\n?\s*'([^']+)'/g,
  )) {
    const key = normalise(m[2]);
    if (!byPath.has(key)) byPath.set(key, new Set());
    byPath.get(key).add(m[1].toUpperCase());
  }
  return byPath;
}

function clientCalls() {
  const calls = [];
  const unparseable = [];

  for (const file of fs.readdirSync(SERVICES).filter((f) => f.endsWith('.dart'))) {
    const source = fs
      .readFileSync(path.join(SERVICES, file), 'utf8')
      .replace(/\/\/.*$/gm, '');

    for (const m of source.matchAll(
      /_authed(Get|Post|Put|Patch|Delete)\(\s*\n?\s*'([^']+)'/g,
    )) {
      calls.push({ method: m[1].toUpperCase(), route: m[2], file });
    }
    for (const m of source.matchAll(
      /_client\s*\.\s*(get|post|put|patch|delete)\(\s*\n?\s*ApiConfig\.path\(\s*'([^']+)'/g,
    )) {
      calls.push({ method: m[1].toUpperCase(), route: m[2], file });
    }
    // A `${` with a space after it is an expression, not a bare variable.
    for (const m of source.matchAll(/_authed\w+\(\s*\n?\s*'[^']*\$\{[^}]*\s[^}]*\}/g)) {
      unparseable.push({ file, snippet: m[0].slice(0, 70) });
    }
  }
  return { calls, unparseable };
}

describe('the client/server route seam', () => {
  const routes = serverRoutes();
  const { calls, unparseable } = clientCalls();

  test('the scan found both sides', () => {
    // Guards the guard. If either regex stops matching, every assertion below
    // passes over an empty list.
    expect(routes.size).toBeGreaterThan(50);
    expect(calls.length).toBeGreaterThan(30);
  });

  test('every client call uses a method the server registers', () => {
    const wrong = [];
    for (const { method, route, file } of calls) {
      const key = normalise(route);
      const methods = routes.get(key);
      // A path with no match is reported by the next test, not this one.
      if (!methods) continue;
      if (!methods.has(method)) {
        wrong.push(
          `${file}: client ${method} ${route} — server has ${[...methods].sort().join('/')}`,
        );
      }
    }
    expect(wrong).toEqual([]);
  });

  test('every client call reaches a route that exists', () => {
    const missing = [];
    for (const { method, route, file } of calls) {
      if (!routes.has(normalise(route))) {
        missing.push(`${file}: ${method} ${route} → ${normalise(route)}`);
      }
    }
    expect(missing).toEqual([]);
  });

  test('paths this scanner cannot parse are counted, not ignored', () => {
    // Reported so the number is visible in review. A scanner that silently
    // drops what it cannot read claims coverage it does not have — which is
    // exactly how the bug this file exists for survived.
    expect(unparseable.length).toBeLessThanOrEqual(2);
  });
});
