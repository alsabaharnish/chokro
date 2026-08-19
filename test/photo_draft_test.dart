import 'dart:typed_data';

import 'package:chokro/controllers/claim_controller.dart';
import 'package:chokro/controllers/disposal_controller.dart';
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
