/**
 * Request authentication.
 *
 * Every endpoint that touches user data requires a Firebase ID token, which the
 * Flutter app obtains from `FirebaseAuth.instance.currentUser.getIdToken()` and
 * sends as `Authorization: Bearer <token>`.
 *
 * WHY THE ROLE IS READ FROM FIRESTORE, NOT FROM THE TOKEN
 * The ID token is signed by Firebase and cannot be forged, so `uid` is
 * trustworthy. But the role lives in the user document, and a token minted
 * before a role change would carry a stale claim. Reading `users/{uid}` on each
 * request costs one lookup and means a suspension takes effect immediately
 * rather than whenever the client happens to refresh its token.
 */

const { auth, db } = require('./firebase');
const { isActiveProfile, suspensionMessage } = require('./suspension');

/**
 * Verifies the bearer token and attaches `req.user = { uid, role, status }`.
 * Rejects with 401 for a missing or invalid token, 403 for a suspended account.
 */
async function requireAuth(req, res, next) {
  const header = req.get('Authorization') || '';
  const match = header.match(/^Bearer\s+(.+)$/i);

  if (!match) {
    return res.status(401).json({
      error: 'unauthenticated',
      message: 'Missing Authorization: Bearer <idToken> header.',
    });
  }

  let decoded;
  try {
    decoded = await auth().verifyIdToken(match[1]);
  } catch (err) {
    return res.status(401).json({
      error: 'invalid_token',
      message: 'The ID token could not be verified.',
    });
  }

  let snapshot;
  try {
    snapshot = await db().collection('users').doc(decoded.uid).get();
  } catch (err) {
    // Express 4 does not automatically turn a rejected async middleware
    // promise into a response. Letting this throw left callers waiting until
    // their own timeout and could surface as an unhandled rejection. A profile
    // service outage is retryable and is neither a bad token nor a suspension.
    console.error(`Profile lookup for ${decoded.uid} failed:`, err.message);
    return res.status(503).json({
      error: 'account_service_unavailable',
      message: 'The account service is temporarily unavailable. Try again.',
    });
  }
  if (!snapshot.exists) {
    // A valid token for a user with no profile document. Should not happen —
    // registration writes both atomically — but treat it as unauthorised rather
    // than assuming a default role.
    return res.status(403).json({
      error: 'no_profile',
      message: 'No user profile exists for this account.',
    });
  }

  const profile = snapshot.data();

  // Resolved through the shared rule, NOT `profile.status !== 'active'`.
  //
  // A temporary suspension is never rewritten back to `active` — nothing is
  // running that could do it — so a lapsed one is permanently
  // `status: 'suspended'` plus a past date. The string comparison this replaces
  // therefore refused every server call forever, while `firestore.rules` and the
  // Flutter UI both treated the same user as active. See `suspension.js`.
  if (!isActiveProfile(profile)) {
    return res.status(403).json({
      error: 'account_suspended',
      message: suspensionMessage(profile),
    });
  }

  req.user = {
    uid: decoded.uid,
    role: profile.role || 'buyer',
    // The stored value, which for a lapsed suspension still reads 'suspended'.
    // Nothing downstream should compare this to 'active' — that is the mistake
    // this change fixes. `isActiveProfile` is the only correct test.
    status: profile.status,
    suspendedUntil: profile.suspendedUntil || null,
  };

  return next();
}

/** Requires an administrator. Use after [requireAuth]. */
function requireAdmin(req, res, next) {
  if (!req.user || req.user.role !== 'admin') {
    return res.status(403).json({
      error: 'forbidden',
      message: 'This action requires an administrator.',
    });
  }
  return next();
}

module.exports = { requireAuth, requireAdmin };
