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

  const snapshot = await db().collection('users').doc(decoded.uid).get();
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

  if (profile.status !== 'active') {
    return res.status(403).json({
      error: 'account_suspended',
      message: 'This account is not active.',
    });
  }

  req.user = {
    uid: decoded.uid,
    role: profile.role || 'buyer',
    status: profile.status,
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
