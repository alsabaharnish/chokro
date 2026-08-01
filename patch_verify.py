"""Wire F2.11 / F2.12 — hashing, screening and the two-lane decision.

Run from the repository root:  python3 patch_verify.py

Four files, all-or-nothing. Idempotent.

NOTE: this adds `photoPublicId` to the disposal document. The hash is computed
from a Cloudinary transform of the stored image, which needs the public_id, and
the upload endpoint currently returns it to the client without it ever being
persisted. `firestore.rules` uses hasOnly on disposal creation, so the new key
must be listed there or every submission is refused.
"""

import sys

# ---------------------------------------------------------------------------
# 1. server/src/index.js — the verify endpoint
# ---------------------------------------------------------------------------

SERVER = 'server/src/index.js'

REQUIRE_ANCHOR = "const binsModule = require('./bins');"
REQUIRE_NEW = "const { verifyDisposal } = require('./verify');"

ROUTE_ANCHOR = """// ---------------------------------------------------------------------------
// Bins (F2.1)
// ---------------------------------------------------------------------------"""

ROUTE_NEW = """// ---------------------------------------------------------------------------
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

"""

# ---------------------------------------------------------------------------
# 2. firestore.rules — photoPublicId joins the permitted key set
# ---------------------------------------------------------------------------

RULES = 'firestore.rules'
RULES_ANCHOR = "'photoUrl',"
RULES_NEW = "'photoUrl', 'photoPublicId',"

# ---------------------------------------------------------------------------
# 3. lib/models/disposal_model.dart — carry the public id
# ---------------------------------------------------------------------------

MODEL = 'lib/models/disposal_model.dart'
MODEL_FIELD_ANCHOR = "  final String photoUrl;"
MODEL_FIELD_NEW = """  final String photoUrl;

  /// Cloudinary public_id for the stored image.
  ///
  /// Needed server-side: the perceptual hash is computed from an 8x8 grayscale
  /// transform of this image, and the transform URL is built from the public
  /// id. Written by the client because only the client sees the upload
  /// response, and harmless in its hands — it names an image that is already
  /// public at an unguessable URL.
  final String photoPublicId;"""

MODEL_PARAM_ANCHOR = "    required this.photoUrl,"
MODEL_PARAM_NEW = """    required this.photoUrl,
    this.photoPublicId = '',"""

EDITS = [
    (SERVER, [
        (REQUIRE_ANCHOR, REQUIRE_ANCHOR + '\n' + REQUIRE_NEW, 'bins require'),
        (ROUTE_ANCHOR, ROUTE_NEW + ROUTE_ANCHOR, 'bins section header'),
    ]),
    (MODEL, [
        (MODEL_FIELD_ANCHOR, MODEL_FIELD_NEW, 'photoUrl field'),
        (MODEL_PARAM_ANCHOR, MODEL_PARAM_NEW, 'photoUrl constructor param'),
    ]),
]

SENTINEL = (SERVER, REQUIRE_NEW)


def main() -> int:
    sources = {}

    for path, edits in EDITS:
        try:
            source = open(path).read()
        except FileNotFoundError:
            print(f'not found: {path} — run from the repository root')
            return 1

        if path == SENTINEL[0] and SENTINEL[1] in source:
            print('already patched, nothing to do')
            return 0

        for anchor, _, description in edits:
            if anchor not in source:
                print(f'anchor missing in {path}: {description}')
                print('nothing was written — the file has diverged')
                return 1
            if source.count(anchor) > 1 and path == RULES:
                print(f'anchor is ambiguous in {path}: {description}')
                print(f'  found {source.count(anchor)} occurrences of {anchor!r}')
                print('nothing was written — patch this one by hand')
                return 1
        sources[path] = source

    for path, edits in EDITS:
        source = sources[path]
        for anchor, replacement, _ in edits:
            source = source.replace(anchor, replacement, 1)
        open(path, 'w').write(source)

    print('patched:')
    print('  server/src/index.js        POST /disposals/:id/verify')
    print('  firestore.rules            photoPublicId permitted on create')
    print('  disposal_model.dart        photoPublicId field')
    print()
    print('STILL TO DO BY HAND:')
    print('  1. disposal_model.dart — add photoPublicId to fromJson and')
    print('     toCreateJson, following how photoUrl is handled there.')
    print('  2. disposal_controller.dart — store publicId from the upload')
    print('     response, and call the verify endpoint after')
    print('     createPendingDisposal.')
    print('  3. Deploy rules:  firebase deploy --only firestore:rules')
    return 0


if __name__ == '__main__':
    sys.exit(main())
