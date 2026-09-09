const policy = require('../src/passwordPolicy');

describe('the producer portal password policy (EPR-5, SEC-8)', () => {
  test('accepts a long passphrase with mixed classes', () => {
    expect(policy.validatePassword('MonsoonLedger42')).toEqual([]);
    expect(policy.isAcceptablePassword('correct-horse-99')).toBe(true);
  });

  test('rejects anything under the length floor', () => {
    // Firebase's own floor is six. A single-factor corporate credential at six
    // characters is not a control (§4.4 — MFA needs Identity Platform).
    expect(policy.validatePassword('Short1!')).toContain(
      'Use at least 12 characters.',
    );
  });

  test('caps length, to keep an unauthenticated endpoint cheap', () => {
    const problems = policy.validatePassword(`${'a1'.repeat(200)}`);
    expect(problems).toContain('Use at most 128 characters.');
  });

  test('reports every problem at once, not the first', () => {
    // A form that reveals one rule at a time makes the person guess their way
    // through the policy, and every failed attempt is another round trip on the
    // endpoint an attacker is also using.
    const problems = policy.validatePassword('abcd');
    expect(problems.length).toBeGreaterThan(1);
  });

  test('refuses the account values an attacker already knows', () => {
    expect(
      policy.validatePassword('compliance-2026x', {
        email: 'compliance@cola.test',
      }),
    ).toContain('Do not use your email address in your password.');

    expect(
      policy.validatePassword('rahmanRahman123', { name: 'Rahman' }),
    ).toContain('Do not use your name in your password.');

    expect(
      policy.validatePassword('cocacola-bottle9', {
        organizationName: 'Coca-Cola',
      }),
    ).toContain('Do not use your company name in your password.');
  });

  test('a short name or company name is not matched', () => {
    // Otherwise a two-letter trade name would forbid every password containing
    // those two letters in sequence.
    expect(
      policy.validatePassword('MonsoonLedger42', {
        name: 'Ki',
        organizationName: 'BD',
      }),
    ).toEqual([]);
  });

  test('refuses runs, repeats and common words', () => {
    expect(policy.validatePassword('xyz1234abcdefg')).toContain(
      'Avoid keyboard or alphabet runs such as "abcd" or "1234".',
    );
    expect(policy.validatePassword('qwertyMonsoon9')).toContain(
      'Avoid keyboard or alphabet runs such as "abcd" or "1234".',
    );
    expect(policy.validatePassword('aaaaaaaaaaaaaaa')).toContain(
      'Use more than one repeated character.',
    );
    expect(policy.validatePassword('MyPassword2026')).toContain(
      'Avoid common words such as "password".',
    );
  });

  test('a reversed run is still a run', () => {
    expect(policy.validatePassword('Monsoon4321Ledger')).toContain(
      'Avoid keyboard or alphabet runs such as "abcd" or "1234".',
    );
  });

  test('requires at least two character classes, and no more', () => {
    // Composition mazes push people toward Password1! and away from length.
    expect(policy.validatePassword('monsoonledgerx')).toContain(
      'Mix letters with numbers or symbols.',
    );
    expect(policy.validatePassword('monsoonledger9')).toEqual([]);
  });

  test('a pasted password with edge whitespace is refused, not trimmed', () => {
    // Trimming silently would store something the person will not reproduce.
    expect(policy.validatePassword(' MonsoonLedger42 ')).toContain(
      'Remove the space at the start or end.',
    );
  });

  test('an empty or non-string password is refused without throwing', () => {
    expect(policy.validatePassword('')).toEqual(['Choose a password.']);
    expect(policy.validatePassword(undefined)).toEqual(['Choose a password.']);
    expect(policy.validatePassword(null)).toEqual(['Choose a password.']);
    expect(policy.validatePassword(12345678901234)).toEqual([
      'Choose a password.',
    ]);
  });

  test('the policy can describe itself before anyone types', () => {
    const described = policy.describePolicy();
    expect(described.length).toBeGreaterThan(0);
    expect(described[0]).toContain('12');
  });
});
