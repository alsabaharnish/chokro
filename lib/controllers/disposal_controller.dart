import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../core/geo.dart' as geo;
import '../models/bin_model.dart';
import '../models/disposal_model.dart';
import '../services/disposal_service.dart';
import '../services/photo_upload_service.dart';
import '../services/verification_service.dart';
import '../services/location_service.dart';

final locationServiceProvider = Provider<LocationService>(
  (ref) => LocationService(),
);

final disposalServiceProvider = Provider<DisposalService>(
  (ref) => DisposalService(),
);

final photoUploadServiceProvider = Provider<PhotoUploadService>(
  (ref) => PhotoUploadService(),
);

final verificationServiceProvider = Provider<VerificationService>(
  (ref) => VerificationService(),
);

/// The submission being composed, held across the steps of the flow.
///
/// A disposal is assembled over several screens — scan, photograph, locate,
/// declare — and only becomes a Firestore document at the end. Keeping the draft
/// in one controller means a user who backs out of the count screen does not
/// lose the photo they just took standing over a bin.
class DisposalDraft {
  final BinModel? bin;

  /// Compressed photo bytes, held only until upload.
  ///
  /// Bytes work on every Flutter target. A local `File` path does not exist in
  /// a browser, and trying to preview one made the web flow fail after capture.
  final Uint8List? photoBytes;

  /// Size in bytes before and after compression. Shown to the user, and useful
  /// evidence in the viva that compression actually happens (NFR-2).
  final int? originalBytes;
  final int? compressedBytes;

  final bool isCapturing;

  final LocationResult? location;
  final bool isLocating;

  final String? error;

  final int declaredItemCount;
  final DisposalItemType itemType;

  /// Submission progress. [submittedId] is set once the pending document exists.
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
  final bool isVerifying;

  const DisposalDraft({
    this.bin,
    this.photoBytes,
    this.originalBytes,
    this.compressedBytes,
    this.isCapturing = false,
    this.location,
    this.isLocating = false,
    this.error,
    this.declaredItemCount = 1,
    this.itemType = DisposalItemType.plasticBottle,
    this.isSubmitting = false,
    this.submittedId,
    this.verification,
    this.isVerifying = false,
  });

  bool get hasPhoto => photoBytes != null && photoBytes!.isNotEmpty;
  bool get hasLocation => location?.hasFix ?? false;

  /// Distance from the bin in metres, computed on device.
  ///
  /// **Feedback only.** The server recomputes this from the stored coordinates
  /// when it decides, and does not trust the value the client sends (F2.5).
  double? get distanceMeters {
    final b = bin;
    final loc = location;
    if (b == null || loc == null || !loc.hasFix) return null;
    return geo.haversineDistance(
      lat1: b.lat,
      lng1: b.lng,
      lat2: loc.latitude!,
      lng2: loc.longitude!,
    );
  }

  bool get isWithinRadius {
    final b = bin;
    final loc = location;
    if (b == null || loc == null || !loc.hasFix) return false;
    return geo.isWithinRadius(
      binLat: b.lat,
      binLng: b.lng,
      capturedLat: loc.latitude!,
      capturedLng: loc.longitude!,
      radiusMeters: b.radiusMeters,
    );
  }

  /// Everything needed before the submission can be written.
  bool get isReadyToSubmit =>
      bin != null && hasPhoto && hasLocation && isWithinRadius;

  /// Percentage saved by compression, for display. Null when nothing to compare.
  int? get compressionSavingPercent {
    final before = originalBytes;
    final after = compressedBytes;
    if (before == null || after == null || before == 0) return null;
    return (100 - (after / before * 100)).round();
  }

  DisposalDraft copyWith({
    BinModel? bin,
    Uint8List? photoBytes,
    int? originalBytes,
    int? compressedBytes,
    bool? isCapturing,
    LocationResult? location,
    bool? isLocating,
    String? error,
    int? declaredItemCount,
    DisposalItemType? itemType,
    bool? isSubmitting,
    String? submittedId,
    VerificationOutcome? verification,
    bool? isVerifying,
    bool clearPhoto = false,
    bool clearError = false,
    bool clearVerification = false,
  }) {
    return DisposalDraft(
      bin: bin ?? this.bin,
      photoBytes: clearPhoto ? null : (photoBytes ?? this.photoBytes),
      originalBytes: clearPhoto ? null : (originalBytes ?? this.originalBytes),
      compressedBytes: clearPhoto
          ? null
          : (compressedBytes ?? this.compressedBytes),
      isCapturing: isCapturing ?? this.isCapturing,
      location: location ?? this.location,
      isLocating: isLocating ?? this.isLocating,
      error: clearError ? null : (error ?? this.error),
      declaredItemCount: declaredItemCount ?? this.declaredItemCount,
      itemType: itemType ?? this.itemType,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      submittedId: submittedId ?? this.submittedId,
      verification: clearVerification
          ? null
          : (verification ?? this.verification),
      isVerifying: isVerifying ?? this.isVerifying,
    );
  }
}

class DisposalDraftController extends Notifier<DisposalDraft> {
  @override
  DisposalDraft build() {
    // Riverpod 3 auto-disposes by default, and this draft outlives the
    // widget that creates it: the flow spans four screens, and the draft is
    // seeded with `ref.read` (which takes no subscription) immediately before
    // the route is pushed. Between those two statements nothing watches it, so
    // without this its survival depends on frame timing rather than on a
    // guarantee — and losing it drops the photo and the resolved bin, landing
    // the user on "This submission is incomplete. Start again."
    //
    // The same trap already cost this codebase its auth gate; see the note on
    // `_authGateProvider` in routing/router.dart.
    ref.keepAlive();
    return const DisposalDraft();
  }

  void startForBin(BinModel bin) {
    state = DisposalDraft(bin: bin);
  }

  void setItemCount(int count) {
    if (count < 1) return;
    state = state.copyWith(declaredItemCount: count);
  }

  void setItemType(DisposalItemType type) {
    state = state.copyWith(itemType: type);
  }

  void clearPhoto() {
    state = state.copyWith(clearPhoto: true, clearError: true);
  }

  void reset() => state = const DisposalDraft();

  // ---------------------------------------------------------------------------
  // Photo (F2.3)
  // ---------------------------------------------------------------------------

  /// Takes a photograph and compresses it.
  ///
  /// Compression is not only about upload size. `FlutterImageCompress` re-encodes
  /// the image, which **strips EXIF metadata** — including the GPS coordinates
  /// most cameras embed. The submission records location deliberately, in its own
  /// fields, from a fix the app requested; it should not also leak whatever the
  /// camera happened to stamp into the file (§7.4).
  ///
  /// Returns true if a photo was captured. False means the user cancelled, which
  /// is not an error.
  Future<bool> capturePhoto() async {
    state = state.copyWith(isCapturing: true, clearError: true);

    try {
      final picker = ImagePicker();
      final shot = await picker.pickImage(
        source: kIsWeb ? ImageSource.gallery : ImageSource.camera,
        // Cap the long edge before compression. A 12 MP phone photo is far more
        // detail than either the screening model or an administrator needs.
        maxWidth: 1600,
        maxHeight: 1600,
        imageQuality: 90,
      );

      if (shot == null) {
        state = state.copyWith(isCapturing: false);
        return false;
      }

      final original = await shot.readAsBytes();

      final compressed = await FlutterImageCompress.compressWithList(
        original,
        quality: 70,
        minWidth: 1080,
        minHeight: 1080,
        // Explicit, though it is the default. Do not carry EXIF forward.
        keepExif: false,
      );

      if (compressed.isEmpty) {
        state = state.copyWith(
          isCapturing: false,
          error: 'The photo could not be processed. Try taking it again.',
        );
        return false;
      }

      state = state.copyWith(
        isCapturing: false,
        photoBytes: compressed,
        originalBytes: original.length,
        compressedBytes: compressed.length,
        clearError: true,
      );
      return true;
    } catch (err) {
      // The common cause is a denied camera permission. Declaring CAMERA in the
      // manifest changes image_picker's behaviour: without the declaration it
      // delegates to the system camera and needs no grant; with it, the app must
      // hold the grant itself (§4.1).
      state = state.copyWith(
        isCapturing: false,
        error: kIsWeb
            ? 'Could not open the photo picker. Choose a supported image and '
                  'try again.'
            : 'Could not open the camera. Check that camera permission is '
                  'granted in Settings, then try again.',
      );
      return false;
    }
  }

  // ---------------------------------------------------------------------------
  // Location (F2.4, F2.5)
  // ---------------------------------------------------------------------------

  /// Requests a location fix and stores the result.
  ///
  /// Does not judge the outcome — [DisposalDraft.isWithinRadius] derives that
  /// from the fix and the bin. Keeping capture and evaluation separate means the
  /// same fix can be re-evaluated if the user scans a different bin.
  Future<void> captureLocation() async {
    state = state.copyWith(
      isLocating: true,
      location: const LocationResult(outcome: LocationOutcome.locating),
      clearError: true,
    );

    final result = await ref.read(locationServiceProvider).getCurrentLocation();

    state = state.copyWith(isLocating: false, location: result);
  }

  Future<void> openLocationSettings() async {
    final service = ref.read(locationServiceProvider);
    final outcome = state.location?.outcome;

    // Two different settings pages: one for a permission the user must grant,
    // one for a device-wide switch they must flip.
    if (outcome == LocationOutcome.serviceDisabled) {
      await service.openLocationSettings();
    } else {
      await service.openSettings();
    }
  }

  // ---------------------------------------------------------------------------
  // Submission
  // ---------------------------------------------------------------------------

  /// Uploads the photograph and writes the pending submission.
  ///
  /// Returns the new document ID, or null if it failed — [DisposalDraft.error]
  /// carries the reason in that case.
  ///
  /// Upload happens here rather than at capture time. Uploading eagerly would
  /// leave an orphaned file in Storage every time a user backed out, and Storage
  /// has no automatic cleanup for that.
  ///
  /// The wallet is untouched by all of this. The document lands as `pending`,
  /// and only the trusted server can move it anywhere else.
  Future<String?> submit({required String uid}) async {
    final draft = state;
    final bin = draft.bin;
    final photoBytes = draft.photoBytes;
    final location = draft.location;

    if (bin == null ||
        photoBytes == null ||
        photoBytes.isEmpty ||
        location == null ||
        !location.hasFix) {
      state = state.copyWith(
        error: 'Something is missing from this submission. Start again.',
      );
      return null;
    }

    state = state.copyWith(isSubmitting: true, clearError: true);

    try {
      final service = ref.read(disposalServiceProvider);

      // Uploads via the trusted service, not to a bucket. See
      // PhotoUploadService for why, and §4.3 of the brief.
      final photo = await ref
          .read(photoUploadServiceProvider)
          .uploadDisposalPhoto(photoBytes);

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
      return id;
    } on PhotoUploadException catch (err) {
      state = state.copyWith(isSubmitting: false, error: err.message);
      return null;
    } on FirebaseException catch (err) {
      // A rules rejection arrives as permission-denied with no explanation of
      // which condition failed — rules cannot return a reason. So list what the
      // rules actually check, rather than guessing at one cause.
      final message = err.code == 'permission-denied'
          ? 'This submission was refused. You may have submitted at this bin '
                'recently, the bin may be closed, or your account may be '
                'suspended. Try again later or use another bin.'
          : 'Could not submit: ${err.message ?? err.code}';

      state = state.copyWith(isSubmitting: false, error: message);
      return null;
    } catch (err) {
      state = state.copyWith(
        isSubmitting: false,
        error: 'Could not submit. Check your connection and try again.',
      );
      return null;
    }
  }
}

final disposalDraftProvider =
    NotifierProvider<DisposalDraftController, DisposalDraft>(
      DisposalDraftController.new,
    );
