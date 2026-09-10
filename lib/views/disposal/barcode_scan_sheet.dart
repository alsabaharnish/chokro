import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/theme.dart';
import '../shared/notice_card.dart';

/// An optional barcode scan during a disposal (EPR-18).
///
/// ## Why this exists when the AI already recognises products
///
/// "Visual brand recognition of a crushed bottle in a dim bin at dusk is a
/// hard computer-vision problem. Reading a GTIN barcode is a solved one."
/// Where a Champion scans, accuracy stops being probabilistic — a scanned
/// GTIN that resolves to a registered product is a high-confidence attribution
/// with no model involvement at all.
///
/// ## Why nothing is looked up here
///
/// NFR-E-6: "a disposal that fails at the bin because a barcode lookup timed
/// out is a worse product than no barcode path at all". So this sheet reads
/// digits and closes. It does not tell the person whether the product is
/// registered, because finding that out means a network call while they are
/// standing at a bin — and the answer would be "no" for almost every barcode,
/// which is information that helps nobody and costs a spinner.
///
/// ## Why it is skippable and says so
///
/// Most items carry no readable barcode, most barcodes belong to products no
/// obligated producer has registered, and a Champion's points do not depend on
/// this in any way (EPR-27). Presenting it as a required step would imply
/// otherwise and would make people hunt for a barcode that is not there.
class BarcodeScanSheet extends StatefulWidget {
  const BarcodeScanSheet({super.key});

  /// Opens the sheet and returns the scanned digits, or null if skipped.
  static Future<String?> show(BuildContext context) =>
      showModalBottomSheet<String>(
        context: context,
        isScrollControlled: true,
        builder: (context) => const BarcodeScanSheet(),
      );

  @override
  State<BarcodeScanSheet> createState() => _BarcodeScanSheetState();
}

class _BarcodeScanSheetState extends State<BarcodeScanSheet> {
  late final MobileScannerController _controller;

  /// Guards against the detector firing repeatedly for one barcode.
  ///
  /// `mobile_scanner` emits on every frame it can read a code, so without this
  /// a single hold produces dozens of pops and the second one closes a sheet
  /// that is already gone.
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      // The product-barcode formats, not QR. The bin scanner reads QR; asking
      // for both here would let a bin label be mistaken for a product code.
      formats: const [
        BarcodeFormat.ean13,
        BarcodeFormat.ean8,
        BarcodeFormat.upcA,
        BarcodeFormat.upcE,
        BarcodeFormat.itf14,
      ],
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;

    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;

      final digits = raw.replaceAll(RegExp(r'\s'), '');
      // The GTIN-8, GTIN-12, GTIN-13 and GTIN-14 lengths. Anything else is a
      // misread rather than a product code, and is ignored so the camera keeps
      // looking instead of closing on a wrong answer.
      if (!RegExp(r'^\d{8,14}$').hasMatch(digits)) continue;

      _handled = true;
      Navigator.of(context).pop(digits);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Scan the product barcode',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                  tooltip: 'Skip',
                ),
              ],
            ),
            const SizedBox(height: AppTheme.gapSm),
            const NoticeCard(
              icon: Icons.info_outline,
              message:
                  'Optional, and it does not change your points. Scanning helps '
                  'the company that made the packaging report it accurately.',
            ),
            const SizedBox(height: AppTheme.gapMd),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 240,
                child: MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  errorBuilder: (context, error) => Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppTheme.gapMd),
                      child: Text(
                        'The camera could not be opened. Skip this step — it is '
                        'optional and nothing depends on it.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppTheme.gapMd),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Skip — no barcode on this item'),
            ),
          ],
        ),
      ),
    );
  }
}
