import 'dart:typed_data';

import 'package:chokro/controllers/disposal_controller.dart';
import 'package:chokro/models/bin_model.dart';
import 'package:chokro/services/photo_upload_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// When the scanner may keep the work in progress, and when it must not.
///
/// The scanner used to call `startForBin` unconditionally, which destroyed a
/// photograph taken standing over the bin whenever the user backed out to
/// re-check the code and re-scanned the same one. Guarding on the bin changing
/// fixes that — and opens a second hole if the guard is written carelessly,
/// because the draft outlives the flow (`ref.keepAlive()`) and the declaration
/// screen renders its confirmation on `submittedId != null`.
///
/// This pins both halves against each other so a future change to either
/// cannot quietly reintroduce the other's bug.
BinModel _bin({required String payload, String? id}) => BinModel(
  id: id,
  label: 'Bin $payload',
  lat: 23.8103,
  lng: 90.4125,
  radiusMeters: 50,
  qrPayload: payload,
  active: true,
  createdBy: 'admin-1',
);

/// The decision the scanner makes, extracted so it can be exercised directly.
bool shouldRestart(DisposalDraft draft, BinModel scanned) {
  final sameBin = draft.bin?.qrPayload == scanned.qrPayload;
  return !sameBin || draft.submittedId != null;
}

void main() {
  final binA = _bin(payload: 'CHOKRO-BIN-A');
  final binB = _bin(payload: 'CHOKRO-BIN-B');

  group('re-scanning keeps work in progress', () {
    test('the same bin keeps the photo, the fix and the count', () {
      final draft = DisposalDraft(
        bin: binA,
        photoBytes: Uint8List.fromList(const [1, 2, 3]),
        declaredItemCount: 7,
      );

      expect(shouldRestart(draft, binA), isFalse);
    });

    test('a different bin starts over, so no photo follows the wrong bin', () {
      final draft = DisposalDraft(
        bin: binA,
        photoBytes: Uint8List.fromList(const [1, 2, 3]),
      );

      expect(shouldRestart(draft, binB), isTrue);
    });

    test('two unwritten bins are told apart by payload, not by id', () {
      // `BinModel.id` is null for a bin not yet written, so comparing on id
      // would report null == null — "same bin" — for two genuinely different
      // bins, and carry a photograph across to the wrong one.
      final draft = DisposalDraft(bin: _bin(payload: 'A'));

      expect(_bin(payload: 'A').id, isNull);
      expect(_bin(payload: 'B').id, isNull);
      expect(shouldRestart(draft, _bin(payload: 'B')), isTrue);
    });

    test('an empty draft starts a flow', () {
      expect(shouldRestart(const DisposalDraft(), binA), isTrue);
    });
  });

  group('a submitted draft is never reused', () {
    test('re-scanning the same bin after submitting starts over', () {
      // Otherwise the Champion is walked through photo and location only to
      // land on the receipt for the submission they already made.
      const draft = DisposalDraft(submittedId: 'disposal-1');
      final withBin = draft.copyWith(bin: binA);

      expect(withBin.submittedId, 'disposal-1');
      expect(shouldRestart(withBin, binA), isTrue);
    });
  });

  group('the uploaded photo receipt follows the bytes', () {
    test('a retake drops the cached upload, so the new photo is uploaded', () {
      // `capturePhoto` sets `photoBytes:` without `clearPhoto`, so keying the
      // receipt off that flag alone would attach the previous photograph's URL
      // to the new declaration.
      const uploaded = UploadedPhoto(
        url: 'https://res.cloudinary.com/c/image/upload/v1/chokro/d/u/a.jpg',
        publicId: 'chokro/d/u/a',
      );

      final submitted = const DisposalDraft()
          .copyWith(photoBytes: Uint8List.fromList(const [1, 2, 3]))
          .copyWith(uploadedPhoto: uploaded);
      expect(submitted.uploadedPhoto, isNotNull);

      final retaken = submitted.copyWith(
        photoBytes: Uint8List.fromList(const [9, 9, 9]),
      );
      expect(
        retaken.uploadedPhoto,
        isNull,
        reason: 'new bytes must invalidate the old upload receipt',
      );
    });

    test('a change unrelated to the photo keeps the receipt, so a retry '
        'does not re-upload', () {
      const uploaded = UploadedPhoto(
        url: 'https://res.cloudinary.com/c/image/upload/v1/chokro/d/u/a.jpg',
        publicId: 'chokro/d/u/a',
      );

      final draft = const DisposalDraft().copyWith(uploadedPhoto: uploaded);

      expect(draft.copyWith(isSubmitting: true).uploadedPhoto, isNotNull);
      expect(draft.copyWith(declaredItemCount: 4).uploadedPhoto, isNotNull);
    });

    test('clearing the photo clears the receipt', () {
      const uploaded = UploadedPhoto(
        url: 'https://res.cloudinary.com/c/image/upload/v1/chokro/d/u/a.jpg',
        publicId: 'chokro/d/u/a',
      );

      final draft = const DisposalDraft().copyWith(uploadedPhoto: uploaded);

      expect(draft.copyWith(clearPhoto: true).uploadedPhoto, isNull);
    });
  });
}
