"""Wire the client half of verification (F2.11, F2.12).

Run from the repository root:  python3 patch_verify_client.py

Three edits, all-or-nothing. Idempotent.

  1. PhotoUploadService returns the Cloudinary publicId alongside the URL.
     The server response already carries it; it was simply discarded.
  2. DisposalDraft gains verification fields.
  3. submit() stores the publicId and calls verify after the document exists.
"""

import sys

UPLOAD = 'lib/services/photo_upload_service.dart'
CONTROLLER = 'lib/controllers/disposal_controller.dart'

# ---------------------------------------------------------------------------
# 1. The upload service returns publicId too
# ---------------------------------------------------------------------------

UPLOAD_SIG_ANCHOR = """  /// Uploads [file] and returns its permanent URL.
  ///
  /// Throws [PhotoUploadException] with a message fit to show a user.
  Future<String> uploadDisposalPhoto(File file) async {"""

UPLOAD_SIG_NEW = """  /// Uploads [file] and returns its URL and Cloudinary public id.
  ///
  /// The public id is needed by the verification pipeline: the perceptual hash
  /// is computed from an 8x8 grayscale transform of the stored image, and that
  /// transform URL is built from the public id. The server has always returned
  /// it; it was previously discarded here.
  ///
  /// Throws [PhotoUploadException] with a message fit to show a user.
  Future<UploadedPhoto> uploadDisposalPhoto(File file) async {"""

UPLOAD_RETURN_ANCHOR = """    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final url = body['photoUrl'] as String?;
      if (url == null || url.isEmpty) {
        throw const PhotoUploadException(
          'The server did not return a photo URL.',
        );
      }
      return url;
    }"""

UPLOAD_RETURN_NEW = """    if (response.statusCode == 200) {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final url = body['photoUrl'] as String?;
      if (url == null || url.isEmpty) {
        throw const PhotoUploadException(
          'The server did not return a photo URL.',
        );
      }
      return UploadedPhoto(
        url: url,
        // Absent only from an older server build. An empty id means the hash
        // step is skipped and the submission routes to review — degraded, but
        // never wrongly approved.
        publicId: (body['publicId'] as String?) ?? '',
      );
    }"""

UPLOAD_CLASS_ANCHOR = """class PhotoUploadException implements Exception {"""

UPLOAD_CLASS_NEW = """/// A stored photograph: where it lives, and how the server can address it.
class UploadedPhoto {
  const UploadedPhoto({required this.url, required this.publicId});

  final String url;
  final String publicId;
}

class PhotoUploadException implements Exception {"""

# ---------------------------------------------------------------------------
# 2. Draft fields for the outcome
# ---------------------------------------------------------------------------

DRAFT_FIELD_ANCHOR = """  /// Submission progress. [submittedId] is set once the pending document exists.
  final bool isSubmitting;
  final String? submittedId;"""

DRAFT_FIELD_NEW = """  /// Submission progress. [submittedId] is set once the pending document exists.
  final bool isSubmitting;
  final String? submittedId;

  /// What verification decided, once it has been asked.
  ///
  /// Null while the submission is still being composed or verified. A non-null
  /// value with `needsReview` true is the normal outcome, not an error — the
  /// document exists either way.
  final VerificationOutcome? verification;

  /// True while the server is deciding. The document already exists at this
  /// point, so the user is never at risk of losing the submission.
  final bool isVerifying;"""

# ---------------------------------------------------------------------------
# 3. submit() passes the publicId and calls verify
# ---------------------------------------------------------------------------

SUBMIT_ANCHOR = """      final photoUrl = await ref
          .read(photoUploadServiceProvider)
          .uploadDisposalPhoto(File(photoPath));

      final disposal = DisposalModel(
        userId: uid,
        binId: bin.id ?? '',
        photoUrl: photoUrl,
        capturedLat: location.latitude!,
        capturedLng: location.longitude!,
        distanceMeters: draft.distanceMeters ?? 0,
        declaredItemCount: draft.declaredItemCount,
        itemType: draft.itemType,
      );

      final id = await service.createPendingDisposal(disposal);

      state = state.copyWith(isSubmitting: false, submittedId: id);
      return id;"""

SUBMIT_NEW = """      final photo = await ref
          .read(photoUploadServiceProvider)
          .uploadDisposalPhoto(File(photoPath));

      final disposal = DisposalModel(
        userId: uid,
        binId: bin.id ?? '',
        photoUrl: photo.url,
        photoPublicId: photo.publicId,
        capturedLat: location.latitude!,
        capturedLng: location.longitude!,
        distanceMeters: draft.distanceMeters ?? 0,
        declaredItemCount: draft.declaredItemCount,
        itemType: draft.itemType,
      );

      final id = await service.createPendingDisposal(disposal);

      // The submission now exists and is safe. Everything below is about
      // whether it can be credited immediately.
      state = state.copyWith(
        isSubmitting: false,
        submittedId: id,
        isVerifying: true,
      );

      // Never throws: a verification that cannot run reports the pending state,
      // which is exactly what the document says. A failed verify is not a
      // failed submission.
      final outcome = await ref.read(verificationServiceProvider).verify(id);

      state = state.copyWith(isVerifying: false, verification: outcome);
      return id;"""

PROVIDER_ANCHOR = """final photoUploadServiceProvider =
    Provider<PhotoUploadService>((ref) => PhotoUploadService());"""

PROVIDER_NEW = """final photoUploadServiceProvider =
    Provider<PhotoUploadService>((ref) => PhotoUploadService());

final verificationServiceProvider =
    Provider<VerificationService>((ref) => VerificationService());"""

IMPORT_ANCHOR = "import '../services/photo_upload_service.dart';"
IMPORT_NEW = "import '../services/verification_service.dart';"

EDITS = [
    (UPLOAD, [
        (UPLOAD_SIG_ANCHOR, UPLOAD_SIG_NEW, 'uploadDisposalPhoto signature'),
        (UPLOAD_RETURN_ANCHOR, UPLOAD_RETURN_NEW, 'success return'),
        (UPLOAD_CLASS_ANCHOR, UPLOAD_CLASS_NEW, 'PhotoUploadException class'),
    ]),
    (CONTROLLER, [
        (IMPORT_ANCHOR, IMPORT_ANCHOR + '\n' + IMPORT_NEW, 'photo upload import'),
        (PROVIDER_ANCHOR, PROVIDER_NEW, 'photoUploadServiceProvider'),
        (DRAFT_FIELD_ANCHOR, DRAFT_FIELD_NEW, 'draft submission fields'),
        (SUBMIT_ANCHOR, SUBMIT_NEW, 'submit body'),
    ]),
]

SENTINEL = (UPLOAD, 'class UploadedPhoto')


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
            count = source.count(anchor)
            if count == 0:
                print(f'anchor missing in {path}: {description}')
                print('nothing was written — the file has diverged')
                return 1
            if count > 1:
                print(f'anchor is ambiguous in {path}: {description}')
                print(f'  found {count} occurrences')
                print('nothing was written')
                return 1
        sources[path] = source

    for path, edits in EDITS:
        source = sources[path]
        for anchor, replacement, _ in edits:
            source = source.replace(anchor, replacement, 1)
        open(path, 'w').write(source)

    print('patched:')
    print('  photo_upload_service.dart  returns UploadedPhoto(url, publicId)')
    print('  disposal_controller.dart   stores publicId, calls verify')
    print()
    print('EXPECT ANALYZER ERRORS in DisposalDraft: the two new fields need')
    print('adding to its constructor and copyWith, which vary too much between')
    print('codebases to patch blind. The errors will name every line.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
