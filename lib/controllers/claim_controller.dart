import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../core/constants.dart';
import '../models/claim_model.dart';
import '../models/user_model.dart';
import '../services/claim_service.dart';
import '../services/photo_upload_service.dart';
import 'auth_controller.dart' show currentUserProvider, userServiceProvider;
import 'current_user_provider.dart';
import 'disposal_controller.dart' show photoUploadServiceProvider;

final claimServiceProvider = Provider<ClaimService>((ref) => ClaimService());

/// The signed-in user's own claims, newest first.
final userClaimsProvider = StreamProvider.autoDispose<List<ClaimModel>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) return Stream.value(const <ClaimModel>[]);
  return ref.watch(claimServiceProvider).watchUserClaims(uid);
});

/// This week's quota position (F6.4).
///
/// Server-side, because the count that matters is over *approved* claims and
/// the quota document is server-owned. The client shows it so a user is not
/// invited to photograph something they cannot submit.
final claimQuotaProvider = FutureProvider.autoDispose<ClaimQuotaStatus>((ref) {
  return ref.watch(claimServiceProvider).fetchQuota();
});

/// Everything awaiting a decision, for the admin queue (F6.3).
final pendingClaimsProvider = StreamProvider<List<ClaimModel>>((ref) {
  return ref.watch(claimServiceProvider).watchPendingClaims();
});

/// Approved eco-actions available for permission-aware public photocards.
final approvedClaimsProvider = StreamProvider<List<ClaimModel>>((ref) {
  final limit = ref.watch(approvedClaimLimitProvider);
  return ref.watch(claimServiceProvider).watchApprovedClaims(limit: limit);
});

class ApprovedClaimLimit extends Notifier<int> {
  @override
  int build() => QueryLimits.photocardPage;

  void loadOlder() => state += QueryLimits.photocardPage;
}

final approvedClaimLimitProvider = NotifierProvider<ApprovedClaimLimit, int>(
  ApprovedClaimLimit.new,
);

/// Submitter details for a queue row.
final claimSubmitterProvider = FutureProvider.family<UserModel?, String>((
  ref,
  uid,
) async {
  return ref.watch(userServiceProvider).getUser(uid);
});

/// A user's earlier claims, shown beside the pending one under review.
///
/// The review screen must show this: with no geofence and no cross-user hash
/// index, an administrator's view of the same person's previous claims is one
/// of the few real defences against a recycled photograph (§7.4).
final claimHistoryForReviewProvider =
    StreamProvider.family<List<ClaimModel>, String>((ref, uid) {
      return ref.watch(claimServiceProvider).watchUserClaims(uid);
    });

// ---------------------------------------------------------------------------
// Submission
// ---------------------------------------------------------------------------

/// The claim being composed.
class ClaimDraft {
  const ClaimDraft({
    this.actionType,
    this.photoBytes,
    this.story = '',
    this.publicationMode,
    this.isCapturing = false,
    this.isSubmitting = false,
    this.submittedId,
    this.submittedPublicationMode,
    this.error,
  });

  final ClaimActionType? actionType;
  final Uint8List? photoBytes;
  final String story;
  final ClaimPublicationMode? publicationMode;
  final bool isCapturing;
  final bool isSubmitting;
  final String? submittedId;
  final ClaimPublicationMode? submittedPublicationMode;
  final String? error;

  bool get hasPhoto => photoBytes != null && photoBytes!.isNotEmpty;
  bool get isReadyToSubmit =>
      actionType != null &&
      hasPhoto &&
      publicationMode != null &&
      story.trim().length <= 800;

  ClaimDraft copyWith({
    ClaimActionType? actionType,
    Uint8List? photoBytes,
    String? story,
    ClaimPublicationMode? publicationMode,
    bool? isCapturing,
    bool? isSubmitting,
    String? submittedId,
    ClaimPublicationMode? submittedPublicationMode,
    String? error,
    bool clearError = false,
    bool clearPhoto = false,
  }) {
    return ClaimDraft(
      actionType: actionType ?? this.actionType,
      photoBytes: clearPhoto ? null : (photoBytes ?? this.photoBytes),
      story: story ?? this.story,
      publicationMode: publicationMode ?? this.publicationMode,
      isCapturing: isCapturing ?? this.isCapturing,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      submittedId: submittedId ?? this.submittedId,
      submittedPublicationMode:
          submittedPublicationMode ?? this.submittedPublicationMode,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ClaimDraftController extends Notifier<ClaimDraft> {
  @override
  ClaimDraft build() {
    // Riverpod 3 auto-disposes by default, and this draft outlives the
    // widget that creates it: the flow spans four screens, and the draft is
    // seeded with `ref.read` (which takes no subscription) immediately before
    // the route is pushed. Between those two statements nothing watches it, so
    // without this its survival depends on frame timing rather than on a
    // guarantee — and losing it drops the captured photograph and the chosen
    // action type, sending the user back to an empty form.
    //
    // The same trap already cost this codebase its auth gate; see the note on
    // `_authGateProvider` in routing/router.dart.
    ref.keepAlive();
    return const ClaimDraft();
  }

  void reset() {
    if (state.isSubmitting) return;
    state = const ClaimDraft();
  }

  void setActionType(ClaimActionType type) {
    if (state.isSubmitting) return;
    state = state.copyWith(actionType: type, clearError: true);
  }

  void setStory(String value) {
    if (state.isSubmitting) return;
    state = state.copyWith(story: value, clearError: true);
  }

  void setPublicationMode(ClaimPublicationMode mode) {
    if (state.isSubmitting) return;
    state = state.copyWith(publicationMode: mode, clearError: true);
  }

  /// Takes a photograph and compresses it.
  ///
  /// Mirrors the disposal capture path deliberately, including `keepExif:
  /// false`. Re-encoding strips the GPS coordinates most cameras embed — and a
  /// claim has no location fields at all, so any location data in the file
  /// would be leaked rather than recorded.
  Future<bool> capturePhoto() async {
    if (state.isSubmitting || state.isCapturing) return false;
    state = state.copyWith(isCapturing: true, clearError: true);

    try {
      final shot = await ImagePicker().pickImage(
        // Browsers cannot reliably launch a physical camera, but their file
        // chooser can select a fresh mobile capture as well as an existing
        // image. Native targets keep the direct camera flow.
        source: kIsWeb ? ImageSource.gallery : ImageSource.camera,
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
        clearError: true,
      );
      return true;
    } catch (err) {
      state = state.copyWith(
        isCapturing: false,
        error: kIsWeb
            ? 'Could not open the photo picker. Choose a supported image and '
                  'try again.'
            : 'Could not open the camera. Check the app has permission.',
      );
      return false;
    }
  }

  /// Uploads the photo and writes the pending claim.
  ///
  /// Nothing is verified afterwards: there is no auto-approve lane for claims,
  /// so the document simply waits for an administrator.
  Future<String?> submit() async {
    if (state.isSubmitting) return null;
    final draft = state;
    final uid = ref.read(currentUidProvider);
    final user = ref.read(currentUserProvider).value;
    final type = draft.actionType;
    final bytes = draft.photoBytes;
    final publicationMode = draft.publicationMode;

    if (uid == null ||
        user == null ||
        type == null ||
        bytes == null ||
        bytes.isEmpty) {
      state = state.copyWith(error: 'Choose an action and take a photo first.');
      return null;
    }
    if (publicationMode == null) {
      state = state.copyWith(
        error: 'Choose how Chokro may credit this story publicly.',
      );
      return null;
    }
    if (draft.story.trim().length > 800) {
      state = state.copyWith(error: 'Keep your story to 800 characters.');
      return null;
    }
    if (publicationMode == ClaimPublicationMode.named &&
        !user.hasProfilePhoto) {
      state = state.copyWith(
        error:
            'Add a profile picture before sharing with your name, or choose anonymous.',
      );
      return null;
    }

    state = state.copyWith(isSubmitting: true, clearError: true);

    try {
      final photo = await ref
          .read(photoUploadServiceProvider)
          .uploadClaimPhoto(bytes);

      final id = await ref
          .read(claimServiceProvider)
          .createPendingClaim(
            ClaimModel(
              userId: uid,
              actionType: type,
              photoUrl: photo.url,
              photoPublicId: photo.publicId,
              story: draft.story.trim(),
              publicationMode: publicationMode,
              championName: publicationMode == ClaimPublicationMode.named
                  ? user.name
                  : null,
              championPhotoUrl: publicationMode == ClaimPublicationMode.named
                  ? user.profilePhotoUrl
                  : null,
            ),
          );

      // Rebuild success from the immutable snapshot submitted above. Even if a
      // future caller bypasses the UI while the request is in flight, the
      // confirmation can never describe a different privacy choice from the
      // one stored in Firestore.
      state = draft.copyWith(
        isSubmitting: false,
        submittedId: id,
        submittedPublicationMode: publicationMode,
        clearError: true,
      );
      // No `ref.invalidate(claimQuotaProvider)` here. The quota counts
      // *approvals*, which a create cannot move — so this only ever re-fetched
      // an identical body over a 90-second-timeout HTTP call, on the frame that
      // renders the confirmation.
      return id;
    } on PhotoUploadException catch (err) {
      state = state.copyWith(isSubmitting: false, error: err.message);
      return null;
    } on FirebaseException catch (err) {
      // Only `permission-denied` means the rules refused this. Every failure
      // used to be reported as a quota or suspension problem, so a user who had
      // simply lost signal was told they had used up their week — and stopped
      // trying. A rules rejection carries no reason (rules cannot return one),
      // so for that case list what the rules actually check.
      final message = err.code == 'permission-denied'
          ? 'This claim was refused. Check that your account is active and '
                'that the evidence is complete.'
          : 'Could not submit this claim. Check your connection and try again.';

      state = state.copyWith(isSubmitting: false, error: message);
      return null;
    } catch (err) {
      state = state.copyWith(
        isSubmitting: false,
        error:
            'Could not submit this claim. Check your connection and try '
            'again.',
      );
      return null;
    }
  }
}

final claimDraftProvider = NotifierProvider<ClaimDraftController, ClaimDraft>(
  ClaimDraftController.new,
);

// ---------------------------------------------------------------------------
// Admin review
// ---------------------------------------------------------------------------

class ClaimReviewUiState {
  const ClaimReviewUiState({this.busyClaimId, this.error, this.lastMessage});

  final String? busyClaimId;
  final String? error;
  final String? lastMessage;

  bool isBusy(String claimId) => busyClaimId == claimId;
}

class ClaimReviewController extends Notifier<ClaimReviewUiState> {
  @override
  ClaimReviewUiState build() => const ClaimReviewUiState();

  void clearMessages() =>
      state = ClaimReviewUiState(busyClaimId: state.busyClaimId);

  // Both actions below need a bare `catch` as well as the typed one.
  //
  // Without it, anything that is not a `ClaimException` — a dropped connection
  // mid-request, a JSON shape the service did not expect, a timeout — escapes
  // while `busyClaimId` is still set. The state never leaves "busy", so the row
  // spins forever with no message and no way back short of leaving the screen.
  // The disposal queue's controller already guards this; this one did not, and
  // the two are otherwise the same shape.

  Future<void> approve(String claimId) async {
    state = ClaimReviewUiState(busyClaimId: claimId);
    try {
      final outcome = await ref.read(claimServiceProvider).approve(claimId);
      state = ClaimReviewUiState(
        lastMessage:
            'Approved — ${outcome.pointsAwarded ?? 0} points credited.',
      );
    } on ClaimException catch (err) {
      state = ClaimReviewUiState(error: err.message);
    } catch (_) {
      state = const ClaimReviewUiState(
        error:
            'Could not approve this claim. Check your connection and try '
            'again.',
      );
    }
  }

  Future<void> reject(String claimId, String reason) async {
    if (reason.trim().isEmpty) {
      state = const ClaimReviewUiState(
        error: 'A rejection needs a reason — the user is shown it.',
      );
      return;
    }

    state = ClaimReviewUiState(busyClaimId: claimId);
    try {
      await ref.read(claimServiceProvider).reject(claimId, reason.trim());
      state = const ClaimReviewUiState(
        lastMessage: 'Rejected, and the user told why.',
      );
    } on ClaimException catch (err) {
      state = ClaimReviewUiState(error: err.message);
    } catch (_) {
      state = const ClaimReviewUiState(
        error:
            'Could not reject this claim. Check your connection and try '
            'again.',
      );
    }
  }
}

final claimReviewControllerProvider =
    NotifierProvider<ClaimReviewController, ClaimReviewUiState>(
      ClaimReviewController.new,
    );
