/**
 * Chokro trusted service — entry point.
 *
 * Milestone 2, step 1: skeleton only. Two endpoints, no disposal logic yet.
 * The point of this step is to prove the deployment path works before any
 * business logic is entangled with it.
 *
 *   GET  /health   no auth   — is the process alive?
 *   GET  /whoami   auth      — can it verify a token and reach Firestore?
 *
 * /whoami is the real smoke test. If it returns your uid and role, then token
 * verification, the service account credentials and Firestore access are all
 * working, which is every piece of infrastructure the verification endpoints
 * will depend on.
 */

require('dotenv').config();

const express = require('express');
const cors = require('cors');

const { initFirebase } = require('./firebase');
const { requireAuth, requireAdmin } = require('./auth');

const app = express();

// Render terminates TLS in front of the app; without this, request IPs and
// protocol are wrong in logs.
app.set('trust proxy', 1);

app.use(express.json({ limit: '1mb' }));

/**
 * CORS.
 *
 * The Flutter web build calls this service from a browser, so the origin has to
 * be allowed explicitly. Android has no origin and is unaffected.
 *
 * ALLOWED_ORIGINS is a comma-separated list. Keep it to the hosting URL and
 * localhost for development — a wildcard would let any page on the internet
 * make authenticated calls with a token it tricked out of a user.
 */
const allowedOrigins = (process.env.ALLOWED_ORIGINS || '')
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);

app.use(
  cors({
    origin(origin, callback) {
      // No origin: a native app, curl, or a same-origin request. Allowed.
      if (!origin) return callback(null, true);
      if (allowedOrigins.includes(origin)) return callback(null, true);
      return callback(new Error(`Origin not allowed: ${origin}`));
    },
  }),
);

// ---------------------------------------------------------------------------
// Routes
// ---------------------------------------------------------------------------

/**
 * Liveness check. No authentication — Render pings this, and so will you when
 * the free tier has put the service to sleep and you want it warm before a demo.
 */
app.get('/health', (req, res) => {
  res.json({
    ok: true,
    service: 'chokro-server',
    version: '0.1.0',
    time: new Date().toISOString(),
  });
});

/** Confirms the whole auth path end to end. */
app.get('/whoami', requireAuth, (req, res) => {
  res.json({
    uid: req.user.uid,
    role: req.user.role,
    status: req.user.status,
  });
});

/** Confirms role gating works, separately from authentication. */
app.get('/admin/ping', requireAuth, requireAdmin, (req, res) => {
  res.json({ ok: true, admin: req.user.uid });
});

app.use((req, res) => {
  res.status(404).json({ error: 'not_found', path: req.path });
});

// Express error handler. Four arguments is what marks it as one — do not remove
// `next` even though it is unused.
// eslint-disable-next-line no-unused-vars
app.use((err, req, res, next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({
    error: 'internal',
    message: 'Something went wrong. Check the server logs.',
  });
});

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------

const port = process.env.PORT || 8787;

// Fail loudly at boot rather than on the first request. A missing service
// account should stop the deploy, not surface later as a mysterious 500.
try {
  initFirebase();
  console.log('Firebase Admin initialised.');
} catch (err) {
  console.error('FATAL:', err.message);
  process.exit(1);
}

app.listen(port, () => {
  console.log(`chokro-server listening on ${port}`);
  if (allowedOrigins.length === 0) {
    console.warn(
      'ALLOWED_ORIGINS is empty — browser calls will be refused. Set it to ' +
        'your hosting URL before testing the web build.',
    );
  }
});
