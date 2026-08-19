/**
 * Chokro trusted service — entry point.
 *
 *   GET  /health              no auth   — is the process alive?
 *   GET  /whoami              auth      — token verification and Firestore reach
 *   GET  /admin/ping          admin     — role gating
 *   POST /photos/disposal     auth      — upload a disposal photograph
 *   POST /photos/claim        auth      — upload claim evidence
 *   GET  /photos/limits       no auth   — the upload size ceiling
 *   POST /disposals/:id/review   admin  — approve or reject (F2.8)
 *   POST /disposals/:id/verify   auth   — the two-lane decision (F2.5, F2.10-12)
 *   GET  /config/points       auth      — the points policy, with provenance
 *   POST /config/points       admin     — validated policy write (F3.3)
 *   POST /bins                admin     — register a bin (F2.1)
 *   POST /bins/:id/active     admin     — take a bin in or out of service
 *   POST /claims/:id/review   admin     — approve or reject a claim (F6.3)
 *
 * Every wallet credit goes through `award.js`, which is the single path.
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
const { verifyDisposal } = require('./verify');
const claimsModule = require('./claims');

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

      // Refused, NOT an error.
      //
      // This used to `callback(new Error(...))`, which Express turned into a
      // 500 carrying "Something went wrong. Check the server logs." An origin
      // that is simply not on the list is not a server fault, and reporting it
      // as one is actively misleading: the preflight failed with a 500 and no
      // CORS header, so the browser blamed the network, the Flutter client
      // reported "check your connection", and the actual cause — a port missing
      // from ALLOWED_ORIGINS — was invisible from either end.
      //
      // Passing `false` omits the Access-Control-Allow-Origin header and lets
      // the request complete normally. The browser then refuses it with the
      // accurate message, naming the missing header.
      //
      // Logged unconditionally, because this line is how you find out which
      // origin to add.
      console.warn(
        `[cors] refused origin ${origin}; ALLOWED_ORIGINS = ` +
          `${allowedOrigins.join(', ') || '(empty)'}`,
      );
      return callback(null, false);
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
function photoUploadHandler(kind) {
  return async (req, res) => {
    try {
      const { imageBase64 } = req.body || {};

      const result = await uploadImage({
        base64: imageBase64,
        uid: req.user.uid,
        kind,
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
  };
}

app.post('/photos/disposal', requireAuth, photoUploadHandler('disposals'));
app.post('/photos/claim', requireAuth, photoUploadHandler('claims'));

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
// Disposal verification (F2.5, F2.10, F2.11, F2.12)
// ---------------------------------------------------------------------------

/**
 * Verifies a pending submission: recomputes the distance from stored
 * coordinates, hashes the photograph, checks it against the user's own history,
 * screens it, and either credits the award or routes it to the review queue.
 *
 * Called by the submitting user, not by an administrator. The caller must own
 * the submission — verified inside verifyDisposal.
 *
 * Idempotent: a submission that has already been decided returns its existing
 * outcome rather than being reconsidered. The client cannot distinguish a lost
 * response from a lost request, so it will retry, and a retry must not credit
 * twice.
 */
app.post('/disposals/:id/verify', requireAuth, async (req, res) => {
  try {
    const result = await verifyDisposal({
      disposalId: req.params.id,
      callerUid: req.user.uid,
    });
    return res.json({ ok: true, ...result });
  } catch (err) {
    console.error(`Verification of ${req.params.id} failed:`, err.message);
    return res.status(409).json({
      error: 'verify_failed',
      message: err.message,
    });
  }
});

// ---------------------------------------------------------------------------
// Claims (F6.1-F6.4)
// ---------------------------------------------------------------------------

/**
 * A user's remaining claim allowance for the current ISO week.
 *
 * Read before composing a claim, so someone at their limit is told before they
 * photograph something rather than after.
 */
app.get('/claims/quota', requireAuth, async (req, res) => {
  try {
    const status = await claimsModule.claimQuotaStatus(req.user.uid);
    return res.json({ ok: true, ...status });
  } catch (err) {
    console.error('Claim quota lookup failed:', err.message);
    return res.status(500).json({
      error: 'quota_failed',
      message: 'Could not read your claim allowance.',
    });
  }
});

/**
 * Approves or rejects a claim.
 *
 * There is no automatic lane and no verify endpoint for claims: the
 * auto-approve path exists only where mechanical checks can pass, and a
 * self-reported action has none. Every claim is decided by a person.
 *
 * The weekly quota is enforced inside the approval transaction rather than at
 * submission, and it increments on approval rather than submission — otherwise
 * a user could exhaust their own week with rejected junk (§7.4).
 */
app.post('/claims/:id/review', requireAuth, requireAdmin, async (req, res) => {
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
        ? await claimsModule.approveClaim({
            claimId: req.params.id,
            adminUid: req.user.uid,
          })
        : await claimsModule.rejectClaim({
            claimId: req.params.id,
            adminUid: req.user.uid,
            reason,
          });

    return res.json({ ok: true, ...result });
  } catch (err) {
    // These messages are written for an administrator to read: already
    // decided, weekly quota reached, no wallet.
    console.error(`Claim review of ${req.params.id} failed:`, err.message);
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
/**
 * Reads the points policy, with the provenance of the last change (F3.3).
 *
 * The policy numbers are returned at the top level, exactly as before — the
 * Flutter client's `PointsPolicy.fromJson` reads the keys it knows and ignores
 * the rest, so the three extra fields are additive and no existing caller
 * changes.
 *
 * The provenance is the point. `POST /config/points` has always recorded
 * `updatedAt` and `updatedBy`, and `policyModule.fromDoc` strips both because
 * `validate()` depends on an exact key set — so nothing ever surfaced them. This
 * is a setting that defines the economy and that any administrator can change,
 * and an administrator opening the editor could not see whether they were looking
 * at someone's deliberate settings from this morning or at untouched defaults.
 *
 * `updatedByName` is resolved here rather than on the client because the server
 * already holds Admin SDK access; a uid is not something to show a person.
 */
app.get('/config/points', requireAuth, async (req, res) => {
  const { db } = require('./firebase');
  const snap = await db().collection('config').doc('points').get();
  const data = snap.exists ? snap.data() : null;

  const policy = policyModule.fromDoc(data);

  // No document means nothing has ever been saved and these are the defaults
  // from §7.3. Reported as nulls rather than invented values.
  let updatedAt = null;
  let updatedBy = null;
  let updatedByName = null;

  if (data) {
    updatedAt = data.updatedAt?.toDate?.()?.toISOString() ?? null;
    updatedBy = data.updatedBy ?? null;

    if (updatedBy) {
      try {
        const editor = await db().collection('users').doc(updatedBy).get();
        updatedByName = editor.exists ? editor.data().name || null : null;
      } catch (err) {
        // A name is a convenience. Failing to resolve it must not fail the
        // policy read, which every award decision on the client depends on.
        console.error('Could not resolve the policy editor name:', err.message);
      }
    }
  }

  res.json({ ...policy, updatedAt, updatedBy, updatedByName });
});

/**
 * Writes the points policy after validation.
 *
 * Rules cannot express the invariant that matters here — that the claim award
 * stays below the disposal award — so the write goes where that check can run.
 */
app.post('/config/points', requireAuth, requireAdmin, async (req, res) => {
  const { db, serverTimestamp } = require('./firebase');

  // `fromRequest`, NOT `fromDoc`. The forgiving reader turned a body of `{}`
  // into a complete policy of defaults that validated cleanly and overwrote the
  // whole live economy — see the note on `fromRequest`.
  const { policy: proposed, problems: shapeProblems } =
    policyModule.fromRequest(req.body);

  const problems = [...shapeProblems, ...policyModule.validate(proposed)];

  if (problems.length > 0) {
    return res.status(400).json({ error: 'invalid_policy', problems });
  }

  // A full overwrite is deliberate and is only safe because `fromRequest` has
  // just guaranteed all nine fields are present — the editor always sends the
  // complete policy. A merge would let a partial payload leave the document in a
  // combination nothing validated as a whole.

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
