import 'dart:typed_data';

import 'package:chokro/controllers/claim_controller.dart';
import 'package:chokro/controllers/disposal_controller.dart';
import 'package:chokro/models/claim_model.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('cross-platform photo drafts', () {
    test('empty byte arrays are not accepted as evidence', () {
      expect(ClaimDraft(photoBytes: Uint8List(0)).hasPhoto, isFalse);
      expect(DisposalDraft(photoBytes: Uint8List(0)).hasPhoto, isFalse);
    });

    test('captured bytes are accepted without a local file path', () {
      final bytes = Uint8List.fromList([0xff, 0xd8, 0xff]);

      expect(ClaimDraft(photoBytes: bytes).hasPhoto, isTrue);
      expect(DisposalDraft(photoBytes: bytes).hasPhoto, isTrue);
    });

    test('a claim needs an explicit publication choice before submission', () {
      final bytes = Uint8List.fromList([0xff, 0xd8, 0xff]);
      final base = ClaimDraft(
        actionType: ClaimActionType.composting,
        photoBytes: bytes,
      );

      expect(base.isReadyToSubmit, isFalse);
      expect(
        base
            .copyWith(publicationMode: ClaimPublicationMode.anonymous)
            .isReadyToSubmit,
        isTrue,
      );
    });

    test('a submitted claim remembers the permission that was persisted', () {
      final draft = ClaimDraft(
        actionType: ClaimActionType.treePlanting,
        photoBytes: Uint8List.fromList([1, 2, 3]),
        publicationMode: ClaimPublicationMode.named,
      );

      final submitted = draft.copyWith(
        isSubmitting: false,
        submittedId: 'claim-1',
        submittedPublicationMode: ClaimPublicationMode.named,
      );

      expect(submitted.submittedPublicationMode, ClaimPublicationMode.named);
      expect(submitted.submittedId, 'claim-1');
    });

    test('clearing a disposal photo also clears its size metadata', () {
      final draft = DisposalDraft(
        photoBytes: Uint8List.fromList([1, 2, 3]),
        originalBytes: 8,
        compressedBytes: 3,
      );

      final cleared = draft.copyWith(clearPhoto: true);
      expect(cleared.hasPhoto, isFalse);
      expect(cleared.originalBytes, isNull);
      expect(cleared.compressedBytes, isNull);
    });
  });
}
