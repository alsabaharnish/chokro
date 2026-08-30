/** Rejection-reason bounds shared by disposal and eco-action review. */

const MIN_REJECTION_REASON_LENGTH = 10;
const MAX_REJECTION_REASON_LENGTH = 500;

/**
 * Returns a trimmed, persistable reason or throws a message safe for an
 * administrator to read.
 *
 * These are the same bounds as `TextLimits` in the Flutter client. Repeating
 * them at the trusted boundary is intentional: a modified client can skip its
 * form validator, while this service is the actor that persists the decision.
 */
function normalizeRejectionReason(reason) {
  if (typeof reason !== 'string') {
    throw new Error('A rejection must record a reason.');
  }

  const normalized = reason.trim();
  if (normalized.length === 0) {
    throw new Error('A rejection must record a reason.');
  }
  if (normalized.length < MIN_REJECTION_REASON_LENGTH) {
    throw new Error(
      `A rejection reason must be at least ${MIN_REJECTION_REASON_LENGTH} characters.`,
    );
  }
  if (normalized.length > MAX_REJECTION_REASON_LENGTH) {
    throw new Error(
      `A rejection reason may not exceed ${MAX_REJECTION_REASON_LENGTH} characters.`,
    );
  }

  return normalized;
}

module.exports = {
  MIN_REJECTION_REASON_LENGTH,
  MAX_REJECTION_REASON_LENGTH,
  normalizeRejectionReason,
};
