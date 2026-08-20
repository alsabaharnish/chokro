/**
 * Per-identity rate limiting.
 *
 * ## Why this is written rather than installed
 *
 * `express-rate-limit` would do this, and on a multi-instance deployment backed
 * by Redis it would do it properly. This service is one free Render instance
 * with no shared store, so a package would give the same in-memory behaviour
 * behind a dependency, a lockfile entry and a configuration surface. Thirty
 * lines that can be read in full is the better trade at this scale — and the
 * limitation is then obvious rather than hidden: **these counters are
 * per-process.** A second instance would double every limit, and a restart
 * clears them. That is acceptable for a limit whose job is to stop one account
 * hammering a paid API, and it would not be acceptable for anything that decides
 * a payout — which is why nothing here does.
 *
 * ## Why the identity is the uid, not the IP
 *
 * Every route this guards is authenticated, and the cost being protected is
 * per-user: a Groq vision call, a Cloudinary upload, a Firestore transaction.
 * Mobile users share carrier NAT addresses, so an IP limit would punish a
 * neighbourhood for one person's behaviour. Unauthenticated requests fall back
 * to the IP, which is the best identity available for them.
 */

/** windowMs -> Map<identity, {count, resetAt}> */
const buckets = new Map();

/**
 * Drops expired entries.
 *
 * Called on each request against the bucket being touched rather than on a
 * timer, because an interval would keep the event loop alive and hold the
 * process up during a Render spin-down. The scan is bounded by how many distinct
 * identities used this limiter inside one window.
 */
function sweep(bucket, now) {
  for (const [key, entry] of bucket) {
    if (entry.resetAt <= now) bucket.delete(key);
  }
}

/**
 * Builds a middleware permitting [max] requests per [windowMs] per identity.
 *
 * Fixed window rather than sliding: it is one integer per identity instead of a
 * list of timestamps, and the worst case — 2× the limit across a window
 * boundary — is irrelevant for a limit set to stop sustained abuse rather than
 * to meter precisely.
 *
 * @param {object} options
 * @param {number} options.windowMs
 * @param {number} options.max
 * @param {string} options.name     appears in the log line, so a trip is
 *                                  attributable to a route rather than to
 *                                  "the limiter"
 */
function rateLimit({ windowMs, max, name }) {
  if (!buckets.has(name)) buckets.set(name, new Map());
  const bucket = buckets.get(name);

  return function limiter(req, res, next) {
    const now = Date.now();
    sweep(bucket, now);

    const identity = req.user?.uid || req.ip || 'anonymous';
    const entry = bucket.get(identity);

    if (!entry || entry.resetAt <= now) {
      bucket.set(identity, { count: 1, resetAt: now + windowMs });
      return next();
    }

    entry.count += 1;

    if (entry.count > max) {
      const retryAfter = Math.ceil((entry.resetAt - now) / 1000);
      // Logged, because a trip is either abuse worth knowing about or a limit
      // set too low — and both are invisible otherwise.
      console.warn(`[rateLimit] ${name} tripped by ${identity}`);
      res.set('Retry-After', String(retryAfter));
      return res.status(429).json({
        error: 'rate_limited',
        message: `Too many requests. Try again in ${retryAfter} seconds.`,
      });
    }

    return next();
  };
}

/** Test seam. Nothing in production calls this. */
function _reset() {
  buckets.clear();
}

module.exports = { rateLimit, _reset };
