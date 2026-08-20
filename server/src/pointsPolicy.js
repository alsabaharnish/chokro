/**
 * Points policy — Node port of `lib/core/points_policy.dart` (§7.3).
 *
 * The client reads the policy to display "this is worth 50 points". The server
 * reads it to decide what to actually credit, and is the only side whose reading
 * matters. Both parse the same `config/points` document with the same per-field
 * fallbacks, so a malformed document degrades identically on both.
 *
 * Reads are forgiving; writes are strict. `validate()` runs here before any
 * policy is persisted, because Firestore rules cannot express a cross-field
 * invariant like "the claim award must stay below the disposal award".
 */

const DEFAULTS = Object.freeze({
  disposalAward: 50,
  claimAward: 15,
  claimQuotaPerWeek: 3,
  purchaseAwardPercent: 5,
  redemptionPointsPerBlock: 100,
  redemptionTakaPerBlock: 10,
  maxRedemptionPercentOfSubtotal: 50,
  lockoutHours: 6,
  dailyDisposalCap: 3,
});

function readInt(source, key) {
  const value = source ? source[key] : undefined;
  if (Number.isSafeInteger(value)) return value;
  return DEFAULTS[key];
}

/**
 * Builds a policy from a `config/points` document.
 * Missing, null or wrongly-typed fields fall back to their defaults rather than
 * throwing — a broken config must never be able to take the service down.
 */
function fromDoc(data) {
  const source = data || {};
  const policy = {};
  for (const key of Object.keys(DEFAULTS)) {
    policy[key] = readInt(source, key);
  }
  return policy;
}

function defaults() {
  return { ...DEFAULTS };
}

/**
 * Builds a policy from a client request, STRICTLY.
 *
 * The counterpart to `fromDoc`, and the distinction is the whole point. This
 * module's own comment says "reads are forgiving, writes are strict" — but the
 * write path called `fromDoc`, the forgiving reader, whose contract is that a
 * missing or wrongly-typed field silently becomes its default.
 *
 * The consequence: `POST /config/points` with a body of `{}` produced a complete
 * policy of pure defaults, passed `validate()` cleanly because defaults are
 * valid, and overwrote the entire live economy. An empty request, a truncated
 * one, or a client that sent strings instead of numbers would silently reset
 * every award and quota an administrator had tuned.
 *
 * Every field must be present and numeric. Defaults are still filled in for the
 * offending keys so `validate()` has a complete object to reason about, but the
 * problems are reported and the caller must refuse the write.
 *
 * @returns {{policy: object, problems: string[]}}
 */
function fromRequest(body) {
  const source = body && typeof body === 'object' ? body : {};
  const problems = [];
  const policy = {};

  for (const key of Object.keys(DEFAULTS)) {
    const value = source[key];

    if (!Number.isSafeInteger(value)) {
      problems.push(`${key} is required and must be a whole safe integer.`);
      policy[key] = DEFAULTS[key];
    } else {
      policy[key] = value;
    }
  }

  return { policy, problems };
}

/**
 * Human-readable problems with a policy. Empty array means it is safe to save.
 *
 * The load-bearing rule is the last one: award value must track verification
 * strength. A claim rests on an administrator's reading of a photograph; a
 * disposal is geofenced, time-locked and hash-checked. If a claim ever pays more
 * than a disposal, users optimise into the weaker route and the whole
 * verification design stops meaning anything.
 */
function validate(policy) {
  const problems = [];

  for (const [key, value] of Object.entries(policy)) {
    if (!Number.isSafeInteger(value)) {
      problems.push(`${key} must be a whole safe integer.`);
    }
  }

  const positive = (label, value) => {
    if (!(value > 0)) problems.push(`${label} must be greater than zero.`);
  };

  positive('Disposal award', policy.disposalAward);
  positive('Claim award', policy.claimAward);
  positive('Claim quota per week', policy.claimQuotaPerWeek);
  positive('Redemption points per block', policy.redemptionPointsPerBlock);
  positive('Redemption taka per block', policy.redemptionTakaPerBlock);
  positive('Lockout window', policy.lockoutHours);
  positive('Daily disposal cap', policy.dailyDisposalCap);

  if (policy.purchaseAwardPercent < 0 || policy.purchaseAwardPercent > 100) {
    problems.push('Purchase award percent must be between 0 and 100.');
  }
  if (
    policy.maxRedemptionPercentOfSubtotal < 0 ||
    policy.maxRedemptionPercentOfSubtotal > 100
  ) {
    problems.push('Max redemption percent must be between 0 and 100.');
  }
  if (policy.lockoutHours > 24 * 7) {
    problems.push('Lockout window may not exceed one week.');
  }
  if (policy.claimAward >= policy.disposalAward) {
    problems.push(
      `Claim award (${policy.claimAward}) must be lower than disposal award ` +
        `(${policy.disposalAward}): the weaker verification route must pay less.`,
    );
  }

  return problems;
}

/** Points required to buy one taka of value. With the defaults, 10. */
function pointsPerTaka(policy) {
  const ratio = Math.trunc(
    policy.redemptionPointsPerBlock / policy.redemptionTakaPerBlock,
  );
  return ratio < 1 ? 1 : ratio;
}

/** Taka value of a points amount, rounded down. */
function takaForPoints(policy, points) {
  if (points <= 0) return 0;
  return Math.trunc(points / pointsPerTaka(policy));
}

/**
 * Points deducted to deliver a whole-taka discount.
 *
 * Always an exact multiple of `pointsPerTaka`, so the ledger never records a
 * partial block (§7.3). Without this, 100 points = 10 taka eventually produces
 * an entry worth 2.7 taka and the ledger stops reconciling.
 */
function pointsToSpendForTaka(policy, taka) {
  if (taka <= 0) return 0;
  return taka * pointsPerTaka(policy);
}

/**
 * The most points a buyer may apply to an order of this subtotal.
 *
 * Bounded by three things at once: the wallet balance, the
 * `maxRedemptionPercentOfSubtotal` ceiling, and whole-taka granularity. Points
 * supplement payment, they do not replace it.
 */
function maxRedeemablePoints(policy, { subtotal, balance }) {
  if (subtotal <= 0 || balance <= 0) return 0;

  const takaCeiling = Math.trunc(
    (subtotal * policy.maxRedemptionPercentOfSubtotal) / 100,
  );
  if (takaCeiling <= 0) return 0;

  const pointsCeiling = pointsToSpendForTaka(policy, takaCeiling);
  const usable = Math.min(balance, pointsCeiling);
  const perTaka = pointsPerTaka(policy);

  return Math.trunc(usable / perTaka) * perTaka;
}

/**
 * Applies a points request to an order and returns the resulting split.
 *
 * Clamps rather than throws, matching `PointsPolicy.applyRedemption` in Dart.
 * The checkout screen should prevent an over-request; this is the side that has
 * to be safe when it does not, because the request comes from a client.
 *
 * @returns {{subtotal: number, pointsApplied: number, discount: number, payable: number}}
 */
function applyRedemption(policy, { subtotal, balance, pointsRequested }) {
  const cap = maxRedeemablePoints(policy, { subtotal, balance });
  const perTaka = pointsPerTaka(policy);

  let pointsApplied = Number.isFinite(pointsRequested)
    ? Math.trunc(pointsRequested)
    : 0;
  if (pointsApplied < 0) pointsApplied = 0;
  if (pointsApplied > cap) pointsApplied = cap;
  pointsApplied = Math.trunc(pointsApplied / perTaka) * perTaka;

  const discount = takaForPoints(policy, pointsApplied);
  return { subtotal, pointsApplied, discount, payable: subtotal - discount };
}

/** Points credited when an order is confirmed received. */
function purchaseAward(policy, payable) {
  if (payable <= 0) return 0;
  return Math.trunc((payable * policy.purchaseAwardPercent) / 100);
}

/** When a lockout opened at [from] (a Date) expires. */
function lockoutExpiry(policy, from) {
  return new Date(from.getTime() + policy.lockoutHours * 60 * 60 * 1000);
}

/**
 * Calendar-day key, e.g. `2026-08-20`, used as the document id for
 * `dailyCaps/{userId}_{dayKey}`.
 *
 * ## Why a counter document rather than a query
 *
 * The daily cap used to be enforced by querying disposals with
 * `createdAt >= today's UTC midnight` and counting the approved ones. That
 * counts submissions **created** today, not approvals **performed** today — and
 * the client chooses when to call `/verify`. Nothing opens the per-bin lockout
 * until an approval, so a user could bank ten pending submissions on Monday and
 * verify all ten on Tuesday: every call looked at Tuesday's window, found zero
 * approvals in it, and passed. The cap was defeated by waiting.
 *
 * Keying on the day the *decision* is made removes the choice from the client
 * entirely. This is the shape `claimQuotas` has always used, and that route was
 * never vulnerable for exactly this reason.
 *
 * ## Why UTC
 *
 * Anchored to UTC, like `isoWeekKey` above, so the two rate-limit windows agree
 * with each other. In Dhaka (UTC+6, no DST) that means the daily cap resets at
 * 06:00 local rather than at midnight — a real consequence, stated rather than
 * accidental. Moving it to local time is a one-line offset here, but it would
 * leave the daily cap and the weekly quota anchored to different boundaries,
 * which is a worse thing to have to explain than a documented 06:00 reset.
 */
function dayKey(date) {
  const year = date.getUTCFullYear();
  const month = String(date.getUTCMonth() + 1).padStart(2, '0');
  const day = String(date.getUTCDate()).padStart(2, '0');
  return `${year}-${month}-${day}`;
}

/** ISO week key, e.g. `2026-W31`. Mirrors IsoWeek in the Dart implementation. */
function isoWeekKey(date) {
  const utc = new Date(
    Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()),
  );
  // ISO weekday: Monday 1 … Sunday 7.
  const weekday = utc.getUTCDay() === 0 ? 7 : utc.getUTCDay();
  const thursday = new Date(utc);
  thursday.setUTCDate(utc.getUTCDate() + 4 - weekday);

  const firstOfYear = new Date(Date.UTC(thursday.getUTCFullYear(), 0, 1));
  const week =
    Math.floor((thursday - firstOfYear) / (7 * 24 * 60 * 60 * 1000)) + 1;

  return `${thursday.getUTCFullYear()}-W${String(week).padStart(2, '0')}`;
}

module.exports = {
  fromRequest,
  DEFAULTS,
  defaults,
  fromDoc,
  validate,
  pointsPerTaka,
  takaForPoints,
  pointsToSpendForTaka,
  maxRedeemablePoints,
  applyRedemption,
  purchaseAward,
  lockoutExpiry,
  isoWeekKey,
  dayKey,
};
