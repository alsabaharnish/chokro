/**
 * Firebase Admin SDK setup.
 *
 * The Admin SDK bypasses Firestore security rules entirely. That is the whole
 * reason this service exists: rules can check *who* is asking, but they cannot
 * check whether a photograph was screened, so the one actor allowed to write a
 * wallet balance has to sit outside them.
 *
 * It also means the credentials loaded here are the most dangerous thing in the
 * project. Anyone holding this key can read and rewrite every wallet in the
 * database, and no rule will stop them. The key is therefore read from an
 * environment variable and never from a file in the repository.
 *
 * FORMAT: FIREBASE_SERVICE_ACCOUNT accepts either
 *   (a) base64 of the service account JSON — preferred, and what Render uses, or
 *   (b) the raw JSON on one line — convenient locally.
 *
 * Base64 exists as an option because the raw JSON carries braces, quotes and
 * backslash-escaped newlines, all of which web forms and shell pipelines find
 * ways to mangle. Base64 is a single unbroken run of [A-Za-z0-9+/=] with nothing
 * for anything in the chain to interpret.
 */

const admin = require('firebase-admin');

let app;

/** Parses the credential from either supported encoding. */
function parseServiceAccount(raw) {
  const trimmed = raw.trim();

  // Raw JSON: starts with a brace.
  if (trimmed.startsWith('{')) {
    return JSON.parse(trimmed);
  }

  // Otherwise assume base64. Strip any whitespace a form or shell introduced.
  const cleaned = trimmed.replace(/\s+/g, '');
  const decoded = Buffer.from(cleaned, 'base64').toString('utf8');
  return JSON.parse(decoded);
}

function initFirebase() {
  if (app) return app;

  const raw = process.env.FIREBASE_SERVICE_ACCOUNT;
  if (!raw) {
    throw new Error(
      'FIREBASE_SERVICE_ACCOUNT is not set. Set it to the base64 of the ' +
        'service account JSON (locally, in server/.env).',
    );
  }

  let serviceAccount;
  try {
    serviceAccount = parseServiceAccount(raw);
  } catch (err) {
    // Deliberately reports shape, never content. Length and first character are
    // enough to tell a truncated paste from a wrong-format one, and neither
    // leaks any part of the key into the logs.
    const trimmed = raw.trim();

    // `err.message` is deliberately NOT interpolated, and the comment above used
    // to claim this already. `JSON.parse` embeds a fragment of the offending
    // input in its own message — and on the base64 branch the text being parsed
    // is the *decoded service-account JSON*, so the private key could appear
    // verbatim in a log line. `index.js` prints this at boot behind `FATAL:`,
    // which on Render means it lands in a log aggregator.
    //
    // Only the error's class is safe to report, and it is enough to tell a
    // malformed paste from a truncated one when combined with the length below.
    throw new Error(
      'FIREBASE_SERVICE_ACCOUNT could not be parsed. ' +
        `Length: ${trimmed.length}. Starts with: "${trimmed.slice(0, 1)}". ` +
        'Expected either base64 (a long run of letters and digits) or raw ' +
        'JSON starting with "{". A length far below 2000 means the value was ' +
        `truncated. Failure type: ${err.name || 'Error'}.`,
    );
  }

  if (!serviceAccount.private_key || !serviceAccount.client_email) {
    throw new Error(
      'FIREBASE_SERVICE_ACCOUNT parsed, but is missing private_key or ' +
        'client_email. This does not look like a service account file.',
    );
  }

  // Some .env formats and dashboards turn the literal "\n" sequences inside the
  // private key into something else. Restoring them here is less error-prone
  // than asking a human to paste a multi-line PEM into a single-line field.
  if (typeof serviceAccount.private_key === 'string') {
    serviceAccount.private_key = serviceAccount.private_key.replace(
      /\\n/g,
      '\n',
    );
  }

  app = admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
    storageBucket: process.env.FIREBASE_STORAGE_BUCKET || undefined,
  });

  console.log(`Firebase Admin initialised for ${serviceAccount.project_id}.`);

  return app;
}

function db() {
  initFirebase();
  return admin.firestore();
}

function auth() {
  initFirebase();
  return admin.auth();
}

function bucket() {
  initFirebase();
  return admin.storage().bucket();
}

/**
 * Cloud Messaging, for push on a decision (F7.1).
 *
 * Exists so the send path does not depend on something else having initialised
 * the app first. `admin.messaging()` called on an uninitialised app throws, and
 * `push.js` previously reached for it directly — which worked only because
 * `tokensFor` happens to call `db()` a few lines earlier. That is a real
 * ordering dependency hiding inside an unrelated function, and reordering the
 * two statements would have broken sending with an error about credentials.
 *
 * `firebase-admin ^13` already ships messaging, so this adds no dependency.
 */
function messaging() {
  initFirebase();
  return admin.messaging();
}

/** Server timestamp sentinel — never a clock value this process authored. */
const serverTimestamp = () => admin.firestore.FieldValue.serverTimestamp();

/** Atomic counter increment, for the stats document. */
const increment = (n) => admin.firestore.FieldValue.increment(n);

module.exports = {
  admin,
  initFirebase,
  db,
  auth,
  bucket,
  messaging,
  serverTimestamp,
  increment,
};
