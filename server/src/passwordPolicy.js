/**
 * Chokro — the server-side password policy for producer portal accounts
 * (EPR-5, SEC-8).
 *
 * WHY THIS IS ENFORCED HERE AND NOT IN THE FORM
 * A client-side check is a courtesy to the person typing. This one is the
 * control: invitation redemption is the only path that creates a producer
 * account, and it is a public endpoint by necessity — the person redeeming has
 * no account yet, so there is no token to authenticate them with. Everything
 * that endpoint accepts has to be validated by something the caller cannot
 * skip, and a form is not that.
 *
 * WHY THE POLICY IS STRICTER THAN THE CONSUMER APP'S
 * Firebase Auth's own floor is six characters. A producer account reads a
 * company's compliance position and can, at owner level, attest a legal
 * declaration. MFA is not available without Identity Platform (§4.4), so until
 * it is, the password is the only factor — and a single factor with a six
 * character floor is not a corporate control.
 *
 * WHY NOT A CHARACTER-CLASS MAZE
 * Composition rules push people toward `Password1!` and away from length, which
 * is the property that actually resists guessing. So the floor is length, the
 * classes requirement is deliberately mild, and the rest of the policy is aimed
 * at the passwords that are actually chosen in practice: the company name, the
 * user's own email, a keyboard run, a single repeated character.
 *
 * Pure: no network, no Firebase, no clock. Every branch is unit-testable.
 */

/** Minimum length. Length is the property that resists guessing. */
const MIN_LENGTH = 12;

/**
 * Maximum length.
 *
 * Not a security limit — it is a denial-of-service one. bcrypt-class hashing on
 * an unbounded input is a way to spend a server's CPU from an unauthenticated
 * endpoint.
 */
const MAX_LENGTH = 128;

/** Sequences long enough to be a pattern rather than a coincidence. */
const RUNS = Object.freeze([
  'abcdefghijklmnopqrstuvwxyz',
  '01234567890',
  'qwertyuiop',
  'asdfghjkl',
  'zxcvbnm',
]);

const RUN_LENGTH = 4;

/** Passwords that are common enough to be tried first, whatever the length. */
const FORBIDDEN = Object.freeze([
  'password',
  'passw0rd',
  'letmein',
  'welcome',
  'chokro',
  'administrator',
  'changeme',
  'iloveyou',
  'qwerty',
]);

/**
 * The alphanumeric skeleton of a string.
 *
 * Same normalisation as `brandKey` in `organizations.js`, and for the same
 * reason: the thing being compared is the word somebody had in mind, not the
 * punctuation they happened to put in it.
 */
function alphanumeric(value) {
  return String(value).replace(/[^a-z0-9]+/gi, '').toLowerCase();
}

function containsRun(lowered) {
  for (const run of RUNS) {
    for (let i = 0; i + RUN_LENGTH <= run.length; i += 1) {
      const forward = run.slice(i, i + RUN_LENGTH);
      const backward = forward.split('').reverse().join('');
      if (lowered.includes(forward) || lowered.includes(backward)) return true;
    }
  }
  return false;
}

/**
 * Every reason this password is refused.
 *
 * All of them, not the first — a form that reveals one rule at a time makes a
 * person guess their way through the policy, and each failed attempt is another
 * round trip on the one endpoint an attacker is also using.
 *
 * @param {string} password
 * @param {object} context   values the password must not simply restate
 * @param {string} [context.email]
 * @param {string} [context.name]
 * @param {string} [context.organizationName]
 * @returns {string[]} human-readable problems; empty means acceptable
 */
function validatePassword(password, context = {}) {
  const problems = [];

  if (typeof password !== 'string' || password.length === 0) {
    return ['Choose a password.'];
  }

  if (password.length < MIN_LENGTH) {
    problems.push(`Use at least ${MIN_LENGTH} characters.`);
  }
  if (password.length > MAX_LENGTH) {
    problems.push(`Use at most ${MAX_LENGTH} characters.`);
  }

  if (password.trim() !== password) {
    // A leading or trailing space is almost always a paste artefact, and it is
    // one the person will not reproduce when they next sign in.
    problems.push('Remove the space at the start or end.');
  }

  const lowered = password.toLowerCase();

  // Mild on purpose. Two classes out of three, not all of them.
  const classes = [/[a-z]/, /[A-Z]/, /[0-9]/, /[^A-Za-z0-9]/].filter((re) =>
    re.test(password),
  ).length;
  if (classes < 2) {
    problems.push('Mix letters with numbers or symbols.');
  }

  if (/^(.)\1*$/.test(password)) {
    problems.push('Use more than one repeated character.');
  }

  if (containsRun(lowered)) {
    problems.push('Avoid keyboard or alphabet runs such as "abcd" or "1234".');
  }

  for (const bad of FORBIDDEN) {
    if (lowered.includes(bad)) {
      problems.push(`Avoid common words such as "${bad}".`);
      break;
    }
  }

  // The three values an attacker already knows about this specific account.
  //
  // Compared on the *alphanumeric skeleton* of both sides, not the raw strings.
  // A plain substring test misses exactly what people actually type: "Coca-Cola"
  // becomes "cocacola", "Coca.Cola" and "Coca Cola 2026", and a check that only
  // catches the one spelling with the hyphen in the right place is a check that
  // catches nobody.
  const skeleton = alphanumeric(lowered);

  const localPart = alphanumeric(
    String(context.email || '').toLowerCase().split('@')[0],
  );
  if (localPart.length >= 4 && skeleton.includes(localPart)) {
    problems.push('Do not use your email address in your password.');
  }

  for (const [value, label] of [
    [context.name, 'your name'],
    [context.organizationName, 'your company name'],
  ]) {
    const candidate = alphanumeric(String(value || '').toLowerCase());
    if (candidate.length >= 4 && skeleton.includes(candidate)) {
      problems.push(`Do not use ${label} in your password.`);
    }
  }

  return problems;
}

function isAcceptablePassword(password, context = {}) {
  return validatePassword(password, context).length === 0;
}

/** The policy, in the words a form should show before anyone types. */
function describePolicy() {
  return [
    `At least ${MIN_LENGTH} characters.`,
    'A mix of letters and numbers or symbols.',
    'Not your name, email address or company name.',
    'No keyboard runs or common words.',
  ];
}

module.exports = {
  MIN_LENGTH,
  MAX_LENGTH,
  FORBIDDEN,
  validatePassword,
  isAcceptablePassword,
  describePolicy,
};
