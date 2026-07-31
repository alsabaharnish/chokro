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
 */

const admin = require('firebase-admin');

let app;

function initFirebase() {
  if (app) return app;

  const raw = process.env.FIREBASE_SERVICE_ACCOUNT;
  if (!raw) {
    throw new Error(
      'FIREBASE_SERVICE_ACCOUNT is not set. Paste the full service account ' +
        'JSON into that environment variable (locally, into server/.env).',
    );
  }

  let serviceAccount;
  try {
    serviceAccount = JSON.parse(raw);
  } catch (err) {
    throw new Error(
      'FIREBASE_SERVICE_ACCOUNT is not valid JSON. It must be the entire ' +
        'file contents, including the outer braces.',
    );
  }

  // Render's dashboard and most .env formats mangle the literal "\n" sequences
  // inside the private key. Restoring them here is less error-prone than asking
  // a human to paste a multi-line PEM into a single-line form field.
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
  serverTimestamp,
  increment,
};
