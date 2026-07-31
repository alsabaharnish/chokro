import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../models/bin_model.dart';
import '../models/disposal_model.dart';

/// The submission being composed, held across the steps of the flow.
///
/// A disposal is assembled over several screens — scan, photograph, locate,
/// declare — and only becomes a Firestore document at the end. Keeping the draft
/// in one controller means a user who backs out of the count screen does not
/// lose the photo they just took standing over a bin.
class DisposalDraft {
  final BinModel? bin;

  /// Local path to the compressed photo, before upload.
  final String? photoPath;

  /// Size in bytes before and after compression. Shown to the user, and useful
  /// evidence in the viva that compression actually happens (NFR-2).
  final int? originalBytes;
  final int? compressedBytes;

  final bool isCapturing;
  final String? error;

  final int declaredItemCount;
  final DisposalItemType itemType;

  const DisposalDraft({
    this.bin,
    this.photoPath,
    this.originalBytes,
    this.compressedBytes,
    this.isCapturing = false,
    this.error,
    this.declaredItemCount = 1,
    this.itemType = DisposalItemType.plasticBottle,
  });

  bool get hasPhoto => photoPath != null;

  /// Percentage saved by compression, for display. Null when nothing to compare.
  int? get compressionSavingPercent {
    final before = originalBytes;
    final after = compressedBytes;
    if (before == null || after == null || before == 0) return null;
    return (100 - (after / before * 100)).round();
  }

  DisposalDraft copyWith({
    BinModel? bin,
    String? photoPath,
    int? originalBytes,
    int? compressedBytes,
    bool? isCapturing,
    String? error,
    int? declaredItemCount,
    DisposalItemType? itemType,
    bool clearPhoto = false,
    bool clearError = false,
  }) {
    return DisposalDraft(
      bin: bin ?? this.bin,
      photoPath: clearPhoto ? null : (photoPath ?? this.photoPath),
      originalBytes: clearPhoto ? null : (originalBytes ?? this.originalBytes),
      compressedBytes:
          clearPhoto ? null : (compressedBytes ?? this.compressedBytes),
      isCapturing: isCapturing ?? this.isCapturing,
      error: clearError ? null : (error ?? this.error),
      declaredItemCount: declaredItemCount ?? this.declaredItemCount,
      itemType: itemType ?? this.itemType,
    );
  }
}

class DisposalDraftController extends Notifier<DisposalDraft> {
  @override
  DisposalDraft build() => const DisposalDraft();

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
        source: ImageSource.camera,
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

      final originalFile = File(shot.path);
      final originalBytes = await originalFile.length();

      final Uint8List? compressed =
          await FlutterImageCompress.compressWithFile(
        shot.path,
        quality: 70,
        minWidth: 1080,
        minHeight: 1080,
        // Explicit, though it is the default. Do not carry EXIF forward.
        keepExif: false,
      );

      if (compressed == null) {
        state = state.copyWith(
          isCapturing: false,
          error: 'The photo could not be processed. Try taking it again.',
        );
        return false;
      }

      // Write beside the original, which already sits in a temporary directory
      // the OS manages. Avoids a path_provider dependency for a file that only
      // needs to survive until upload.
      final outPath =
          '${originalFile.parent.path}/chokro_${DateTime.now().millisecondsSinceEpoch}.jpg';
      final outFile = File(outPath);
      await outFile.writeAsBytes(compressed, flush: true);

      state = state.copyWith(
        isCapturing: false,
        photoPath: outPath,
        originalBytes: originalBytes,
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
        error: 'Could not open the camera. Check that camera permission is '
            'granted in Settings, then try again.',
      );
      return false;
    }
  }
}

final disposalDraftProvider =
    NotifierProvider<DisposalDraftController, DisposalDraft>(
  DisposalDraftController.new,
);
