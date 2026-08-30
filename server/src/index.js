/**
 * Chokro trusted service — entry point.
 *
 *   GET  /health              no auth   — is the process alive?
 *   GET  /whoami              auth      — token verification and Firestore reach
 *   GET  /admin/ping          admin     — role gating
 *   POST /photos/disposal     auth      — upload a disposal photograph
 *   POST /photos/claim        auth      — upload claim evidence
 *   POST /photos/profile      auth      — replace the Champion profile picture
 *   GET  /photos/limits       no auth   — the upload size ceiling
 *   POST /disposals/:id/review   admin  — approve or reject (F2.8)
 *   POST /disposals/:id/verify   auth   — the two-lane decision (F2.5, F2.10-12)
 *   GET  /config/points       auth      — the points policy, with provenance
 *   POST /config/points       admin     — validated policy write (F3.3)
 *   POST /bins                admin     — register a bin (F2.1)
 *   POST /bins/:id/active     admin     — take a bin in or out of service
 *   POST /claims/:id/review   admin     — approve or reject a claim (F6.3)
 *   POST /photos/product      seller    — upload a listing photograph (F4.1)
 *   POST /checkout            auth      — place the cart as orders (F4.4, F4.5)
 *   POST /orders/:id/status   seller    — ship or deliver (F4.6, F4.8)
 *   POST /orders/:id/confirm  auth      — buyer confirms receipt (F4.7)
 *   POST /donations           auth      — donate points to a green initiative
 *   POST /donations/prototype-payments auth — simulate an online donation
 *   POST /sellers/:uid/listings  admin  — hide or restore a catalogue (§7.4)
 *
 * Every wallet credit goes through `award.js`, which is the single path.
 */

require('dotenv').config();

const express = require('express');
const cors = require('cors');

const { initFirebase } = require('./firebase');
const { requireAuth, requireAdmin, requireSeller } = require('./auth');
const { uploadImage, MAX_BYTES } = require('./cloudinary');
const { uploadAndSaveProfilePhoto } = require('./profilePhoto');
const { approveDisposal, rejectDisposal } = require('./award');
const policyModule = require('./pointsPolicy');
const binsModule = require('./bins');
const { verifyDisposal } = require('./verify');
const claimsModule = require('./claims');
const checkoutModule = require('./checkout');
const ordersModule = require('./orders');
const donationsModule = require('./donations');
const listingsModule = require('./listings');
const { rateLimit } = require('./rateLimit');
const { parseAllowedOrigins, isAllowedOrigin } = require('./cors');
const { requestBodyErrorResponse } = require('./httpErrors');

const app = express();

// Baseline browser protections for this JSON API. The Flutter web client does
// not need responses to be framed, MIME-sniffed or to propagate referrers.
app.disable('x-powered-by');
app.use((req, res, next) => {
  res.set({
    'X-Content-Type-Options': 'nosniff',
    'X-Frame-Options': 'DENY',
    'Referrer-Policy': 'no-referrer',
    'Permissions-Policy': 'camera=(), microphone=(), geolocation=()',
  });
  next();
});

// Render terminates TLS in front of the app; without this, request IPs and
// protocol are wrong in logs.
app.set('trust proxy', 1);


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
const allowedOrigins = parseAllowedOrigins(process.env.ALLOWED_ORIGINS);

/**
 * Whether loopback origins are accepted on top of the explicit list.
 *
 * ## Why this exists
 *
 * `ALLOWED_ORIGINS` has to name an exact origin, scheme and port. In local
 * development that port is not stable: `flutter run -d chrome` picks a fresh one
 * on every launch, and a pinned one can simply be taken — which is exactly what
 * happened here, with an unrelated project holding 5000 for hours while the only
 * allowlisted dev origin was `http://localhost:5000`.
 *
 * The failure is silent and expensive to diagnose. Every call to this service
 * from the browser is refused, while Firestore reads keep working because they
 * do not come through here — so the app looks *mostly* fine and precisely the
 * screens that need the server break. That is a confusing signal to hand
 * somebody, and it has now cost time twice.
 *
 * ## Why it is opt-in and not a `NODE_ENV !== 'production'` default
 *
 * A CORS allowlist is a real control: it is what stops a page on the open
 * internet making authenticated calls with a token it tricked out of a user.
 * Defaulting it open whenever an environment variable happens to be unset means
 * one missing variable on a deploy silently removes the control — and nothing
 * would report it.
 *
 * So this is off unless explicitly enabled, and `npm run dev` enables it. A
 * production start never does, whatever `NODE_ENV` says.
 */
const allowLoopbackOrigins = process.env.ALLOW_LOOPBACK_ORIGINS === 'true';

/** The predicate itself lives in `cors.js`, where it is unit-tested. */
const originAllowed = (origin) =>
  isAllowedOrigin(origin, {
    allowedOrigins,
    allowLoopback: allowLoopbackOrigins,
  });

app.use(
  cors({
    origin(origin, callback) {
      // No origin: a native app, curl, or a same-origin request. Allowed.
      if (!origin) return callback(null, true);
      if (originAllowed(origin)) return callback(null, true);

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
          `${allowedOrigins.join(', ') || '(empty)'}` +
          `${allowLoopbackOrigins ? ' (+ any loopback)' : ''}. ` +
          'For local development, start the server with `npm run dev`, which ' +
          'accepts any localhost port.',
      );
      return callback(null, false);
    },
  }),
);

// ---------------------------------------------------------------------------
// Rate limits
// ---------------------------------------------------------------------------
//
// Applied per authenticated uid. The numbers are set well above what the app
// does in normal use and well below what it costs to be abused — a disposal
// takes four screens to compose, so twenty verifications an hour is generous for
// a person and useless for a script.
//
// `verify` and the photo routes are the ones that matter: each verification is a
// billed Groq vision call and each upload is a Cloudinary write, so without a
// limit one authenticated account could spend the project's whole quota. The
// others are here to keep a single account from monopolising a free instance.

const verifyLimit = rateLimit({ name: 'verify', windowMs: 60 * 60 * 1000, max: 20 });
const photoLimit = rateLimit({ name: 'photos', windowMs: 60 * 60 * 1000, max: 40 });
const writeLimit = rateLimit({ name: 'writes', windowMs: 60 * 1000, max: 30 });

// ---------------------------------------------------------------------------
// Body parsing
// ---------------------------------------------------------------------------
//
// Registered AFTER cors and, for the photo routes, after authentication and the
// per-user rate limit.
//
// A single global `express.json({ limit: '12mb' })` used to sit above
// everything, which meant an **unauthenticated** POST to any path — including
// one that would 404 — made this free-tier instance buffer and parse up to 12 MB
// before anything looked at who was asking. The ceiling has to be that high for
// photo uploads (base64 inflates a payload by about a third), but only the
// purpose-specific photo routes need it.
//
// Each exact photo POST attaches these in the order auth -> rate limit -> parser.
// That ordering matters twice: a rate-limited account does not get to make the
// process decode another 12 MB body, and an unauthenticated GET/PUT/unknown path
// below `/photos` never inherits the large ceiling. OPTIONS does not match a POST
// route, so browser preflights remain unauthenticated.
const photoJson = express.json({ limit: '12mb' });
const regularJson = express.json({ limit: '64kb' });

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
    version: '0.4.0',
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
function photoUploadHandler(kind, { saveAsProfile = false } = {}) {
  return async (req, res) => {
    try {
      const { imageBase64 } = req.body || {};

      // A profile reference is identity data, not claim evidence. Its helper
      // persists through the Admin SDK and cleans up the just-uploaded public
      // image if that write fails. Other kinds remain upload-only.
      const result = saveAsProfile
        ? await uploadAndSaveProfilePhoto({
            base64: imageBase64,
            uid: req.user.uid,
          })
        : await uploadImage({
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

app.post(
  '/photos/disposal',
  requireAuth,
  photoLimit,
  photoJson,
  photoUploadHandler('disposals'),
);
app.post(
  '/photos/claim',
  requireAuth,
  photoLimit,
  photoJson,
  photoUploadHandler('claims'),
);
app.post(
  '/photos/profile',
  requireAuth,
  photoLimit,
  photoJson,
  photoUploadHandler('profiles', { saveAsProfile: true }),
);

/**
 * A listing photograph (F4.1).
 *
 * Gated on the seller role as well as authentication, unlike the evidence and
 * profile routes. Nobody who cannot list a product has any reason to fill the
 * product folder, and that folder is exactly what `firestore.rules` checks a
 * stored image URL against.
 *
 * Reachable from the web build as well as mobile: `image_picker` returns bytes
 * on both and nothing in this path touches `dart:io`. The seller console is
 * web-primary (§5.5), so an upload that only worked on a phone would be the
 * wrong way round.
 */
app.post(
  '/photos/product',
  requireAuth,
  requireSeller,
  photoLimit,
  photoJson,
  photoUploadHandler('products'),
);

/** Lets the client show a sensible limit without hard-coding it twice. */
app.get('/photos/limits', (req, res) => {
  res.json({ maxBytes: MAX_BYTES });
});

// All remaining request bodies are small decisions, settings or checkout
// intent. Photo bodies have already terminated in their exact routes above.
app.use(regularJson);

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
app.post('/disposals/:id/review', requireAuth, requireAdmin, writeLimit, async (req, res) => {
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
app.post('/disposals/:id/verify', requireAuth, verifyLimit, async (req, res) => {
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
app.post('/claims/:id/review', requireAuth, requireAdmin, writeLimit, async (req, res) => {
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
// Marketplace (F4.4-F4.8)
// ---------------------------------------------------------------------------

/**
 * Places the caller's cart (F4.4, F4.5).
 *
 * The body carries a points figure and a settlement method and nothing else.
 * Prices, stock, seller ids and the wallet balance are all read inside the
 * transaction from stored documents — the client's own quote is what the buyer
 * saw, not what they are charged.
 *
 * Not idempotent, and deliberately so. A checkout consumes the cart, so a retry
 * finds an empty one and fails with "Your cart is empty" rather than placing a
 * second set of orders. That is the safe direction to fail in: a duplicate
 * checkout would decrement stock twice and debit points twice.
 */
app.post('/checkout', requireAuth, writeLimit, async (req, res) => {
  const { pointsRequested, settlementMethod } = req.body || {};

  const points = Number.isFinite(pointsRequested)
    ? Math.trunc(pointsRequested)
    : 0;

  try {
    const result = await checkoutModule.checkout({
      buyerUid: req.user.uid,
      pointsRequested: points,
      settlementMethod: settlementMethod || 'cashOnDelivery',
    });
    return res.status(201).json({ ok: true, ...result });
  } catch (err) {
    // These messages are written for the buyer to read: an empty cart, a
    // delisted product, "only 2 left", a seller who is not trading. Surfaced
    // verbatim, because a generic failure at checkout leaves nothing to act on.
    console.error(`Checkout for ${req.user.uid} failed:`, err.message);
    return res
      .status(409)
      .json({ error: 'checkout_failed', message: err.message });
  }
});

/**
 * Donates Champion reward points to a named 3ZERO initiative.
 *
 * `donationId` is generated by the client and makes retries idempotent. The
 * server reads the live wallet and performs the debit; no balance comes from
 * the request body.
 */
app.post('/donations', requireAuth, writeLimit, async (req, res) => {
  const { donationId, initiative, points } = req.body || {};

  try {
    const result = await donationsModule.donatePoints({
      uid: req.user.uid,
      donationId,
      initiative,
      points,
    });
    return res.status(result.repeated ? 200 : 201).json({ ok: true, ...result });
  } catch (err) {
    const known = err instanceof donationsModule.DonationError;
    console.error(`Donation for ${req.user.uid} failed:`, err.message);
    return res.status(known ? err.status : 500).json({
      error: known ? err.code : 'donation_failed',
      message: known
        ? err.message
        : 'The donation could not be completed. No points were taken.',
    });
  }
});

/**
 * Simulates an online donation for product-flow testing.
 *
 * No real payment credentials are accepted and no processor is contacted. The
 * receipt is permanently labelled as a prototype so it cannot be confused
 * with verified income.
 */
app.post(
  '/donations/prototype-payments',
  requireAuth,
  writeLimit,
  async (req, res) => {
    const { donationId, initiative, amountTaka, settlementMethod } =
      req.body || {};

    try {
      const result = await donationsModule.donatePrototypePayment({
        uid: req.user.uid,
        donationId,
        initiative,
        amountTaka,
        settlementMethod,
      });
      return res.status(result.repeated ? 200 : 201).json({ ok: true, ...result });
    } catch (err) {
      const known = err instanceof donationsModule.DonationError;
      console.error(`Prototype donation for ${req.user.uid} failed:`, err.message);
      return res.status(known ? err.status : 500).json({
        error: known ? err.code : 'prototype_donation_failed',
        message: known
          ? err.message
          : 'The payment simulation could not be completed. No real money was taken.',
      });
    }
  },
);

/**
 * The seller ships or delivers (F4.6, F4.8).
 *
 * Body: { status: 'shipped' | 'delivered' }
 *
 * The target status is named rather than implied, so a stale screen cannot
 * replay a transition: the server refuses anything that is not the exact next
 * step for this order.
 */
app.post('/orders/:id/status', requireAuth, requireSeller, writeLimit, async (req, res) => {
  const { status } = req.body || {};

  if (!ordersModule.STATUSES.includes(status)) {
    return res.status(400).json({
      error: 'bad_status',
      message: "status must be 'shipped' or 'delivered'.",
    });
  }

  try {
    const result = await ordersModule.advanceOrder({
      orderId: req.params.id,
      actorUid: req.user.uid,
      status,
    });
    return res.json({ ok: true, ...result });
  } catch (err) {
    console.error(`Order ${req.params.id} update failed:`, err.message);
    return res.status(409).json({ error: 'order_failed', message: err.message });
  }
});

/**
 * The buyer confirms receipt, which is the only transition that pays (F4.7).
 *
 * No seller gate and no admin gate: the buyer is the party here, and
 * `confirmOrder` checks the caller is the one named on the order. Idempotent
 * through the status check — a confirmed order refuses a second confirmation,
 * so a retry after a lost response cannot credit twice.
 */
app.post('/orders/:id/confirm', requireAuth, writeLimit, async (req, res) => {
  try {
    const result = await ordersModule.confirmOrder({
      orderId: req.params.id,
      buyerUid: req.user.uid,
    });
    return res.json({ ok: true, ...result });
  } catch (err) {
    console.error(`Order ${req.params.id} confirmation failed:`, err.message);
    return res.status(409).json({ error: 'order_failed', message: err.message });
  }
});

/**
 * Hides or restores a seller's catalogue alongside a suspension (§7.4).
 *
 * Called by the administrator's screen straight after it writes the suspension
 * to Firestore. Two operations rather than one, because the suspension itself is
 * a client write that rules can police and this one is not — so the screen has
 * to report a partial failure honestly rather than pretend the pair was atomic.
 */
app.post('/sellers/:uid/listings', requireAuth, requireAdmin, async (req, res) => {
  const { visible } = req.body || {};

  if (typeof visible !== 'boolean') {
    return res.status(400).json({
      error: 'bad_request',
      message: 'visible must be true or false.',
    });
  }

  try {
    const result = await listingsModule.setSellerListingsVisible({
      sellerUid: req.params.uid,
      visible,
    });
    return res.json({ ok: true, ...result });
  } catch (err) {
    console.error(`Listing sweep for ${req.params.uid} failed:`, err.message);
    return res.status(409).json({ error: 'sweep_failed', message: err.message });
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

  // The whole handler is wrapped, and that is not defensive habit.
  //
  // Express 4 does not await a handler's return value, so a rejected promise
  // from an async route never reaches the error handler at the bottom of this
  // file — for async routes that handler is dead code. Node then treats the
  // unhandled rejection as an uncaught exception and **exits the process**.
  //
  // This endpoint is the worst possible place for that: the Flutter client
  // calls it routinely, because every award figure it displays depends on the
  // live policy. One transient Firestore error on a read the client makes on
  // every launch would take the whole service down until Render restarted it.
  try {
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

    return res.json({ ...policy, updatedAt, updatedBy, updatedByName });
  } catch (err) {
    console.error('Policy read failed:', err.message);
    return res.status(503).json({
      error: 'policy_unavailable',
      message: 'The points policy could not be read. Try again.',
    });
  }
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
  //
  // Wrapped for the same reason as the read above: an unguarded `await` in an
  // Express 4 async route exits the process rather than returning a 500.
  try {
    await db()
      .collection('config')
      .doc('points')
      .set({
        ...proposed,
        updatedAt: serverTimestamp(),
        updatedBy: req.user.uid,
      });

    return res.json({ ok: true, policy: proposed });
  } catch (err) {
    console.error('Policy write failed:', err.message);
    return res.status(503).json({
      error: 'policy_write_failed',
      message: 'The policy could not be saved. Nothing was changed.',
    });
  }
});

// ---------------------------------------------------------------------------
// Fallbacks
// ---------------------------------------------------------------------------

app.use((req, res) => {
  res.status(404).json({ error: 'not_found', path: req.path });
});

// Express error handler. Four arguments is what marks it as one.
app.use((err, req, res, next) => {
  if (res.headersSent) return next(err);

  const requestError = requestBodyErrorResponse(err);
  if (requestError) {
    // Do not log `err.message`: JSON parse errors can echo a fragment of the
    // request body. The type and path are enough to diagnose this class.
    console.warn(
      `[request] ${req.method} ${req.path} rejected: ${requestError.error}`,
    );
    return res.status(requestError.status).json({
      error: requestError.error,
      message: requestError.message,
    });
  }

  console.error('Unhandled error:', err);
  return res.status(500).json({
    error: 'internal',
    message: 'Something went wrong. Check the server logs.',
  });
});

// ---------------------------------------------------------------------------
// Startup
// ---------------------------------------------------------------------------

/**
 * Last-resort backstops.
 *
 * Every async route in this file now has its own try/catch, and that is the
 * real fix — these exist so that the *next* route added without one degrades to
 * a logged error instead of a dead service. Node's default behaviour for an
 * unhandled rejection is to terminate, which on a single free-tier instance
 * means every user is offline until Render notices.
 *
 * A fatal exception can leave arbitrary module state corrupted. Stop accepting
 * new work, give in-flight responses a short window to finish, then let the
 * platform restart a clean process. Wallet writes remain transaction-safe.
 */
let server;
let shuttingDown = false;

function shutdown(reason, exitCode) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.error(`[shutdown] ${reason}`);

  const forceExit = setTimeout(() => {
    console.error('[shutdown] grace period expired; forcing exit.');
    process.exit(exitCode);
  }, 10000);
  forceExit.unref();

  if (!server) {
    clearTimeout(forceExit);
    process.exit(exitCode);
    return;
  }

  server.close(() => {
    clearTimeout(forceExit);
    process.exit(exitCode);
  });
}

process.on('unhandledRejection', (reason) => {
  shutdown(
    `Unhandled promise rejection: ${
      reason instanceof Error ? reason.message : reason
    }`,
    1,
  );
});

process.on('uncaughtException', (err) => {
  shutdown(`Uncaught exception: ${err.message}`, 1);
});

process.on('SIGTERM', () => shutdown('SIGTERM received.', 0));
process.on('SIGINT', () => shutdown('SIGINT received.', 0));

const port = process.env.PORT || 8787;

// Fail loudly at boot rather than on the first request. A missing service
// account should stop the deploy, not surface later as a mysterious 500.
try {
  initFirebase();
} catch (err) {
  console.error('FATAL:', err.message);
  process.exit(1);
}

server = app.listen(port, () => {
  console.log(`chokro-server listening on ${port}`);

  if (allowLoopbackOrigins) {
    console.log(
      '[cors] loopback origins accepted (ALLOW_LOOPBACK_ORIGINS=true). This ' +
        'must not be set in production.',
    );
  }

  if (allowedOrigins.length === 0 && !allowLoopbackOrigins) {
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
