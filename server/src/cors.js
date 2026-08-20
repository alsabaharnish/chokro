/**
 * Which browser origins may call this service.
 *
 * Extracted from `index.js` so it can be tested directly. It is a security
 * control — it is what stops a page on the open internet making authenticated
 * calls with a token it tricked out of a user — and the bypass cases worth
 * pinning (`localhost.evil.com`, `notlocalhost`) are exactly the ones a regex
 * gets wrong when nobody is asserting on it.
 */

/**
 * `http://localhost:1234` and `http://127.0.0.1:1234`, any port, and nothing
 * that merely contains those words.
 *
 * Anchored at both ends, which is the whole point: unanchored, this would accept
 * `http://localhost.evil.com` and `http://notlocalhost:5000`.
 */
const LOOPBACK_ORIGIN = /^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/;

/**
 * Parses a comma-separated `ALLOWED_ORIGINS` value.
 *
 * @param {string|undefined} raw
 * @returns {string[]}
 */
function parseAllowedOrigins(raw) {
  return (raw || '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

/**
 * Whether [origin] may call this service.
 *
 * @param {string} origin
 * @param {object} options
 * @param {string[]} options.allowedOrigins  exact matches from ALLOWED_ORIGINS
 * @param {boolean} options.allowLoopback    ALLOW_LOOPBACK_ORIGINS, dev only
 */
function isAllowedOrigin(origin, { allowedOrigins = [], allowLoopback = false } = {}) {
  if (typeof origin !== 'string' || origin.length === 0) return false;
  if (allowedOrigins.includes(origin)) return true;
  return allowLoopback && LOOPBACK_ORIGIN.test(origin);
}

module.exports = { LOOPBACK_ORIGIN, parseAllowedOrigins, isAllowedOrigin };
