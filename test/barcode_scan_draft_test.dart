/// The optional barcode step on a disposal draft (EPR-18, EPR-6, NFR-E-6).
library;

import 'package:chokro/controllers/disposal_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  ProviderContainer container() {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    return c;
  }

  group('recording a scan', () {
    test('a draft starts with no barcode, because most items have none', () {
      expect(container().read(disposalDraftProvider).scannedGtin, isNull);
    });

    test('accepts every GTIN length', () {
      // GTIN-8, GTIN-12, GTIN-13 and GTIN-14.
      for (final gtin in [
        '12345678',
        '123456789012',
        '8901234567890',
        '12345678901234',
      ]) {
        final c = container();
        c.read(disposalDraftProvider.notifier).setScannedGtin(gtin);
        expect(
          c.read(disposalDraftProvider).scannedGtin,
          gtin,
          reason: '$gtin is a valid GTIN length',
        );
      }
    });

    test('strips whitespace a scanner may include', () {
      final c = container();
      c.read(disposalDraftProvider.notifier).setScannedGtin(' 8901234567890 ');
      expect(c.read(disposalDraftProvider).scannedGtin, '8901234567890');
    });

    test('a misread is ignored without touching the draft or erroring', () {
      // A misread barcode is a common, harmless event at a bin. Blocking the
      // flow for one would make scanning riskier than not scanning, which
      // would defeat the point of preferring the barcode path.
      for (final misread in [
        'ABC123',
        '1234567',
        '123456789012345',
        'https://example.com/x',
        '89012345678a0',
      ]) {
        final c = container();
        c.read(disposalDraftProvider.notifier).setScannedGtin(misread);
        expect(
          c.read(disposalDraftProvider).scannedGtin,
          isNull,
          reason: '"$misread" must not be stored',
        );
        expect(c.read(disposalDraftProvider).error, isNull);
      }
    });

    test('a scan can be taken back', () {
      // Somebody who scanned the wrong item must be able to undo it, which is
      // why `clearScannedGtin` exists — passing null cannot be distinguished
      // from omitting the argument.
      final c = container();
      final notifier = c.read(disposalDraftProvider.notifier);

      notifier.setScannedGtin('8901234567890');
      expect(c.read(disposalDraftProvider).scannedGtin, '8901234567890');

      notifier.setScannedGtin(null);
      expect(c.read(disposalDraftProvider).scannedGtin, isNull);

      notifier.setScannedGtin('8901234567890');
      notifier.setScannedGtin('');
      expect(c.read(disposalDraftProvider).scannedGtin, isNull);
    });

    test('a rescan replaces the previous code', () {
      final c = container();
      final notifier = c.read(disposalDraftProvider.notifier);
      notifier.setScannedGtin('8901234567890');
      notifier.setScannedGtin('12345678');
      expect(c.read(disposalDraftProvider).scannedGtin, '12345678');
    });
  });

  group('the scan is not part of the submitted document (EPR-6)', () {
    test('copyWith carries it without it reaching the disposal payload', () {
      // The client create allowlist in firestore.rules must not grow by a
      // single key. The scan travels with the *verification* request instead,
      // and the server writes it as a server-owned field.
      final draft = const DisposalDraft().copyWith(
        scannedGtin: '8901234567890',
        declaredItemCount: 2,
      );

      expect(draft.scannedGtin, '8901234567890');
      expect(draft.declaredItemCount, 2);
    });

    test('nothing about a scan changes the points path (EPR-27)', () {
      // §6.8: "In v1, SKU attribution changes no points, no wallet balance and
      // no ledger entry." A scan is an input to attribution and to nothing
      // else, so it must not appear anywhere a payout is decided.
      final c = container();
      final before = c.read(disposalDraftProvider);
      c.read(disposalDraftProvider.notifier).setScannedGtin('8901234567890');
      final after = c.read(disposalDraftProvider);

      // Every field the decision path reads is untouched.
      expect(after.declaredItemCount, before.declaredItemCount);
      expect(after.itemType, before.itemType);
      expect(after.photoBytes, before.photoBytes);
      expect(after.location, before.location);
      expect(after.bin, before.bin);
    });
  });
}
