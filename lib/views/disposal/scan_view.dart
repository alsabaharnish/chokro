import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../controllers/disposal_controller.dart';
import '../../controllers/scan_controller.dart';
import '../../core/theme.dart';
import '../shared/flow_progress.dart';

/// Step 1 of the disposal flow (F2.2): scan the code on a bin.
///
/// Resolves the bin and hands off. Photo capture, the location fix and the
/// submission itself are later steps — keeping them apart means a failure on a
/// borrowed phone points at one thing rather than four.
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
        .firstWhere(
          (value) => value != null && value.isNotEmpty,
          orElse: () => null,
        );

    if (raw == null) return;

    _handled = true;
    ref.read(scanControllerProvider.notifier).resolve(raw);
  }

  void _scanAgain() {
    _handled = false;
    ref.read(scanControllerProvider.notifier).reset();
  }

  void _continueToPhoto() {
    final bin = ref.read(scanControllerProvider).bin;
    if (bin == null) return;

    // Opens a fresh draft here rather than on the photo screen: backing out and
    // scanning a different bin must not leave a photo attached to the old one.
    ref.read(disposalDraftProvider.notifier).startForBin(bin);
    context.push('/dispose/photo');
  }

  @override
  Widget build(BuildContext context) {
    final scan = ref.watch(scanControllerProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Scan bin code'),
        bottom: const FlowProgress(current: 1, total: 4, label: 'Scan'),
        actions: [
          // The icon used to be a fixed `flashlight_on_outlined` regardless of
          // the actual torch state, so after tapping it there was no way to tell
          // from the button whether the torch was on — and bin codes are often
          // scanned after dark, which is when it matters.
          ValueListenableBuilder<MobileScannerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              final isOn = state.torchState == TorchState.on;
              return IconButton(
                tooltip: isOn ? 'Turn off torch' : 'Turn on torch',
                isSelected: isOn,
                icon: const Icon(Icons.flashlight_off_outlined),
                selectedIcon: const Icon(Icons.flashlight_on),
                // Unavailable means no torch on this camera — a front-facing
                // one, or a desktop webcam. Disabled beats a no-op tap.
                onPressed: state.torchState == TorchState.unavailable
                    ? null
                    : () => _controller.toggleTorch(),
              );
            },
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
            onContinue: _continueToPhoto,
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
  final VoidCallback onContinue;

  const _ResultPanel({
    required this.scan,
    required this.theme,
    required this.onScanAgain,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    final isProblem =
        scan.outcome == ScanOutcome.unknownCode ||
        scan.outcome == ScanOutcome.binClosed ||
        scan.outcome == ScanOutcome.error;

    // Kept separate from `isProblem`, and not because of the colour. A lockout
    // is a wait rather than a fault: nothing is wrong with the code, the bin or
    // the account, and the user's next move is to walk to another bin or come
    // back later. Folding it in with "this code is not a Chokro bin" would tell
    // them the wrong thing. It also has to be handled *somewhere* — an outcome
    // that is neither `canProceed` nor `isProblem` rendered no icon and no
    // button, leaving the scanner with no way forward at all.
    final isLockedOut = scan.outcome == ScanOutcome.lockedOut;

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
                        : isLockedOut
                        ? Icons.schedule
                        : isProblem
                        ? Icons.error_outline
                        : Icons.qr_code_scanner,
                    // `colorScheme.success`, not `Colors.green`: the literal
                    // was the same mid-green in dark mode, where it glared
                    // against the dark surface.
                    color: scan.canProceed
                        ? theme.colorScheme.success
                        : isLockedOut
                        ? theme.colorScheme.warning
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
            if (isLockedOut && scan.bin != null) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 30),
                child: Text(scan.bin!.label, style: theme.textTheme.bodySmall),
              ),
            ],
            const SizedBox(height: 16),
            if (scan.canProceed)
              FilledButton.icon(
                onPressed: onContinue,
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Continue'),
              )
            else if (isProblem || isLockedOut)
              OutlinedButton(
                onPressed: onScanAgain,
                child: Text(isLockedOut ? 'Scan another bin' : 'Scan again'),
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
              const Icon(
                Icons.no_photography_outlined,
                color: Colors.white70,
                size: 48,
              ),
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
