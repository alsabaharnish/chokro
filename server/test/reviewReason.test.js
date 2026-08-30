const {
  MIN_REJECTION_REASON_LENGTH,
  MAX_REJECTION_REASON_LENGTH,
  normalizeRejectionReason,
} = require('../src/reviewReason');

describe('trusted rejection-reason validation', () => {
  test('trims and accepts a useful reason', () => {
    expect(normalizeRejectionReason('  The evidence is not clear.  ')).toBe(
      'The evidence is not clear.',
    );
  });

  test('rejects missing, non-string and blank values cleanly', () => {
    for (const value of [undefined, null, 123, {}, [], '   ']) {
      expect(() => normalizeRejectionReason(value)).toThrow(/record a reason/i);
    }
  });

  test('enforces the same useful minimum as the client', () => {
    expect(() =>
      normalizeRejectionReason('x'.repeat(MIN_REJECTION_REASON_LENGTH - 1)),
    ).toThrow(/at least/i);
    expect(() =>
      normalizeRejectionReason('x'.repeat(MIN_REJECTION_REASON_LENGTH)),
    ).not.toThrow();
  });

  test('enforces the storage and UI ceiling', () => {
    expect(() =>
      normalizeRejectionReason('x'.repeat(MAX_REJECTION_REASON_LENGTH)),
    ).not.toThrow();
    expect(() =>
      normalizeRejectionReason('x'.repeat(MAX_REJECTION_REASON_LENGTH + 1)),
    ).toThrow(/may not exceed/i);
  });
});
