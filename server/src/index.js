/**
 * Chokro trusted service — entry point.
 *
 *   GET  /health              no auth   — is the process alive?
 *   GET  /whoami              auth      — token verification and Firestore reach
 *   GET  /admin/ping          admin     — role gating
 *   POST /photos/disposal     auth      — upload a disposal photograph
 *
 * Still to come (M2): /disposals/:id/verify, /disposals/:id/review,
 * /config/points, and award.js — the single wallet-credit path.
 */

require('dotenv').config();

const express = require('express');
const cors = require('cors');

const { initFirebase } = require('./firebase');
const { requireAuth, requireAdmin } = require('./auth');
const { uploadImage, MAX_BYTES } = require('./cloudinary');
const { approveDisposal, rejectDisposal } = require('./award');
const policyModule = require('./pointsPolicy');
const binsModule = require('./bins');

const app = express();

// Render terminates TLS in front of the app; without this, request IPs and
// protocol are wrong in logs.
app.set('trust proxy', 1);

// Base64 inflates a payload by about a third, so the ceiling here has to exceed
// the image ceiling with room to spare.
app.use(express.json({ limit: '12mb' }));

/**
 * CORS.
 *
 * The Flutter web build calls this service from a browser, so the origin has to
 * be allowed explicitly. Android and iOS have no origin and are unaffected.
 *
 * ALLOWED_ORIGINS is a comma-separated list. Keep it to the hosting URL and
 * localhost for development — a wildcard would let any page on the internet make
 * authenticated calls with a token it tricked out of a user.
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
// Health and diagnostics
// ---------------------------------------------------------------------------

/**
 * Liveness check. No authentication — Render pings this, and so will you when
 * the free tier has put the service to sleep and you want it warm before a demo.
 */
app.get('/health', (req, res) => {
  res.json({
    ok: true,
    service: 'chokro-server',
    version: '0.3.0',
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

// ---------------------------------------------------------------------------
// Photo upload
// ---------------------------------------------------------------------------

/**
 * Uploads a disposal photograph and returns its URL.
 *
 * The client compresses and strips EXIF before sending (§7.4); this endpoint
 * validates what arrives rather than trusting that it happened.
 *
 * Note the uid comes from the verified token, never from the request body. A
 * caller cannot upload into someone else's folder by asking nicely.
 */
app.post('/photos/disposal', requireAuth, async (req, res) => {
  try {
    const { imageBase64 } = req.body || {};

    const result = await uploadImage({
      base64: imageBase64,
      uid: req.user.uid,
      kind: 'disposals',
    });

    res.json({
      photoUrl: result.url,
      publicId: result.publicId,
      bytes: result.bytes,
    });
  } catch (err) {
    // decodeImage throws user-safe messages; anything else is ours to hide.
    const isValidation =
      typeof err.message === 'string' &&
      (err.message.includes('image') || err.message.includes('too large'));

    if (isValidation) {
      return res.status(400).json({ error: 'bad_image', message: err.message });
    }

    console.error('Photo upload failed:', err.message);
    return res.status(502).json({
      error: 'upload_failed',
      message: 'The photo could not be stored. Try again.',
    });
  }
});

/** Lets the client show a sensible limit without hard-coding it twice. */
app.get('/photos/limits', (req, res) => {
  res.json({ maxBytes: MAX_BYTES });
});

// ---------------------------------------------------------------------------
// Disposal review (F2.8)
// ---------------------------------------------------------------------------

/**
 * An administrator approves or rejects a pending submission.
 *
 * The admin's button calls this endpoint rather than writing Firestore directly,
 * because there must be exactly one code path that credits a wallet. Rules deny
 * an administrator every write to `wallets`, `transactions` and `disposals` —
 * that is what makes "no client writes a balance" true without qualification.
 *
 * Body: { decision: 'approve' | 'reject', reason?: string }
 */
app.post('/disposals/:id/review', requireAuth, requireAdmin, async (req, res) => {
  const { id } = req.params;
  const { decision, reason } = req.body || {};

  if (decision !== 'approve' && decision !== 'reject') {
    return res.status(400).json({
      error: 'bad_decision',
      message: "decision must be 'approve' or 'reject'.",
    });
  }

  try {
    const result =
      decision === 'approve'
        ? await approveDisposal({ disposalId: id, adminUid: req.user.uid })
        : await rejectDisposal({
            disposalId: id,
            adminUid: req.user.uid,
            reason,
          });

    return res.json({ ok: true, ...result });
  } catch (err) {
    // These throws carry messages written for an administrator to read — an
    // already-decided submission, a missing wallet, a daily cap reached.
    console.error(`Review of ${id} failed:`, err.message);
    return res.status(409).json({ error: 'review_failed', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Bins (F2.1)
// ---------------------------------------------------------------------------

/**
 * Registers a bin.
 *
 * Bins are server-owned because their coordinates and radius are inputs this
 * service trusts when deciding a payout. The QR payload is allocated here too:
 * it has to be unique, and a client cannot guarantee that.
 */
app.post('/bins', requireAuth, requireAdmin, async (req, res) => {
  const { label, lat, lng, radiusMeters } = req.body || {};

  const problems = binsModule.validateBin({ label, lat, lng, radiusMeters });
  if (problems.length > 0) {
    return res.status(400).json({ error: 'invalid_bin', problems });
  }

  try {
    const bin = await binsModule.createBin({
      label,
      lat,
      lng,
      radiusMeters,
      adminUid: req.user.uid,
    });
    return res.status(201).json({ ok: true, bin });
  } catch (err) {
    console.error('Bin registration failed:', err.message);
    return res.status(409).json({ error: 'bin_failed', message: err.message });
  }
});

/**
 * Takes a bin in or out of service.
 *
 * Never deletes: past disposals reference their bin, and a dangling reference
 * breaks a user's history and an administrator's ability to review it.
 */
app.post('/bins/:id/active', requireAuth, requireAdmin, async (req, res) => {
  const { active } = req.body || {};

  if (typeof active !== 'boolean') {
    return res.status(400).json({
      error: 'bad_request',
      message: 'active must be true or false.',
    });
  }

  try {
    const result = await binsModule.setBinActive({
      binId: req.params.id,
      active,
      adminUid: req.user.uid,
    });
    return res.json({ ok: true, ...result });
  } catch (err) {
    console.error(`Bin ${req.params.id} update failed:`, err.message);
    return res.status(409).json({ error: 'bin_failed', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Points policy (F3.3)
// ---------------------------------------------------------------------------

/** Current policy, with defaults filled in for anything the document omits. */
app.get('/config/points', requireAuth, async (req, res) => {
  const { db } = require('./firebase');
  const snap = await db().collection('config').doc('points').get();
  res.json(policyModule.fromDoc(snap.exists ? snap.data() : null));
});

/**
 * Writes the points policy after validation.
 *
 * Rules cannot express the invariant that matters here — that the claim award
 * stays below the disposal award — so the write goes where that check can run.
 */
app.post('/config/points', requireAuth, requireAdmin, async (req, res) => {
  const { db, serverTimestamp } = require('./firebase');

  const proposed = policyModule.fromDoc(req.body || {});
  const problems = policyModule.validate(proposed);

  if (problems.length > 0) {
    return res.status(400).json({ error: 'invalid_policy', problems });
  }

  await db()
    .collection('config')
    .doc('points')
    .set({ ...proposed, updatedAt: serverTimestamp(), updatedBy: req.user.uid });

  return res.json({ ok: true, policy: proposed });
});

// ---------------------------------------------------------------------------
// Fallbacks
// ---------------------------------------------------------------------------

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

  if (!process.env.CLOUDINARY_CLOUD_NAME) {
    console.warn(
      'Cloudinary is not configured — photo uploads will fail. Set ' +
        'CLOUDINARY_CLOUD_NAME, CLOUDINARY_API_KEY and CLOUDINARY_API_SECRET.',
    );
  }
});
