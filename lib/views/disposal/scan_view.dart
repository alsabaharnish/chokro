import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../controllers/scan_controller.dart';

/// Step 1 of the disposal flow (F2.2): scan the code on a bin.
///
/// Deliberately does nothing beyond resolving the bin. Photo capture, the
/// location fix and the submission itself are later steps — keeping them apart
/// means a failure on a borrowed phone points at one thing rather than four.
///
/// Camera permission is handled by `mobile_scanner` itself: the plugin requests
/// it when the controller starts. If the user denies it, [MobileScanner]'s
/// `errorBuilder` renders instead of the preview.
class ScanView extends ConsumerStatefulWidget {
  const ScanView({super.key});

  @override
  ConsumerState<ScanView> createState() => _ScanViewState();
}

class _ScanViewState extends ConsumerState<ScanView> {
  late final MobileScannerController _controller;

  /// Guards against the camera firing the same code repeatedly while the
  /// resolved result is on screen.
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
      formats: const [BarcodeFormat.qrCode],
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;

    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .firstWhere((value) => value != null && value.isNotEmpty,
            orElse: () => null);

    if (raw == null) return;

    _handled = true;
    ref.read(scanControllerProvider.notifier).resolve(raw);
  }

  void _scanAgain() {
    _handled = false;
    ref.read(scanControllerProvider.notifier).reset();
  }

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(scanControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan bin code'),
        actions: [
          IconButton(
            tooltip: 'Toggle torch',
            icon: const Icon(Icons.flashlight_on_outlined),
            onPressed: () => _controller.toggleTorch(),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  errorBuilder: (context, error) => _CameraError(error: error),
                ),
                // Simple aiming frame. Purely visual — the scanner reads the
                // whole frame, not just this box.
                Center(
                  child: Container(
                    width: 240,
                    height: 240,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.white70, width: 2),
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ],
            ),
          ),
          _ResultPanel(
            scan: scan,
            theme: theme,
            onScanAgain: _scanAgain,
          ),
        ],
      ),
    );
  }
}

class _ResultPanel extends StatelessWidget {
  final ScanState scan;
  final ThemeData theme;
  final VoidCallback onScanAgain;

  const _ResultPanel({
    required this.scan,
    required this.theme,
    required this.onScanAgain,
  });

  @override
  Widget build(BuildContext context) {
    final isProblem = scan.outcome == ScanOutcome.unknownCode ||
        scan.outcome == ScanOutcome.binClosed ||
        scan.outcome == ScanOutcome.error;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (scan.isBusy)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  Icon(
                    scan.canProceed
                        ? Icons.check_circle_outline
                        : isProblem
                            ? Icons.error_outline
                            : Icons.qr_code_scanner,
                    color: scan.canProceed
                        ? Colors.green
                        : isProblem
                            ? theme.colorScheme.error
                            : theme.colorScheme.onSurfaceVariant,
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    scan.displayMessage,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            if (scan.canProceed) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 30),
                child: Text(
                  'Radius ${scan.bin!.radiusMeters.round()} m',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (scan.canProceed)
              FilledButton.icon(
                // Step 2 wires this to photo capture.
                onPressed: null,
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Continue (next step)'),
              )
            else if (isProblem)
              OutlinedButton(
                onPressed: onScanAgain,
                child: const Text('Scan again'),
              ),
          ],
        ),
      ),
    );
  }
}

class _CameraError extends StatelessWidget {
  final MobileScannerException error;

  const _CameraError({required this.error});

  @override
  Widget build(BuildContext context) {
    final isPermission =
        error.errorCode == MobileScannerErrorCode.permissionDenied;

    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.no_photography_outlined,
                  color: Colors.white70, size: 48),
              const SizedBox(height: 16),
              Text(
                isPermission
                    ? 'Camera permission is needed to scan bin codes. '
                        'Enable it in Settings and return here.'
                    : 'The camera could not be started.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
