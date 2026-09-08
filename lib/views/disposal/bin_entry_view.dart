import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/disposal_controller.dart';
import '../../controllers/scan_controller.dart';
import '../../core/bin_link.dart';
import '../../core/theme.dart';

/// Entry point carried by the QR on a physical bin.
///
/// The route is protected by the normal active-account gate. An anonymous web
/// visitor is asked to sign in or create the existing small account; the router
/// then restores this exact URL and this view resolves the bin. No location,
/// photo, lockout, or verification rule is bypassed by entering here.
class BinEntryView extends ConsumerStatefulWidget {
  const BinEntryView({super.key, required this.payload});

  final String payload;

  @override
  ConsumerState<BinEntryView> createState() => _BinEntryViewState();
}

class _BinEntryViewState extends ConsumerState<BinEntryView> {
  String? _resolvedPayload;

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(() => _resolve(widget.payload));
  }

  @override
  void didUpdateWidget(covariant BinEntryView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.payload == widget.payload) return;
    _resolvedPayload = null;
    Future<void>.microtask(() => _resolve(widget.payload));
  }

  Future<void> _resolve(String payload) async {
    await ref.read(scanControllerProvider.notifier).resolve(payload);
    if (!mounted || widget.payload != payload) return;
    setState(() => _resolvedPayload = payload);
  }

  Future<void> _continue() async {
    final bin = ref.read(scanControllerProvider).bin;
    final expectedPayload = BinLink.payloadFromScannedValue(widget.payload);
    if (bin == null || bin.qrPayload != expectedPayload) return;

    final draft = ref.read(disposalDraftProvider);
    final isReusable =
        draft.bin?.qrPayload == bin.qrPayload && draft.submittedId == null;
    if (!isReusable) {
      ref.read(disposalDraftProvider.notifier).startForBin(bin);
    }
    await context.push('/dispose/photo');
  }

  @override
  Widget build(BuildContext context) {
    final resolvedScan = ref.watch(scanControllerProvider);
    // A route can change from one `/b/...` link to another without destroying
    // this State. Never render the previous bin as actionable during the new
    // lookup, even for a single frame.
    final scan = _resolvedPayload == widget.payload
        ? resolvedScan
        : const ScanState(outcome: ScanOutcome.resolving);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Chokro bin')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppTheme.gapLg),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppTheme.maxFormWidth,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    scan.canProceed
                        ? Icons.recycling
                        : scan.isBusy
                        ? Icons.qr_code_2
                        : Icons.error_outline,
                    size: 56,
                    color: scan.canProceed
                        ? scheme.primary
                        : scheme.onSurfaceVariant,
                  ),
                  const SizedBox(height: AppTheme.gapMd),
                  Text(
                    scan.isBusy ? 'Checking this bin…' : scan.displayMessage,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall,
                  ),
                  if (scan.isBusy) ...[
                    const SizedBox(height: AppTheme.gapLg),
                    const Center(child: CircularProgressIndicator()),
                  ] else if (scan.canProceed) ...[
                    const SizedBox(height: AppTheme.gapSm),
                    Text(
                      kIsWeb
                          ? 'Choose a clear, current photo of the waste in this '
                                'bin, allow location access, and confirm what '
                                'you disposed of.'
                          : 'Take a clear photo of the waste in this bin, allow '
                                'location access, and confirm what you disposed '
                                'of.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: AppTheme.gapLg),
                    Card(
                      color: scheme.surfaceContainerHighest,
                      child: const Padding(
                        padding: EdgeInsets.all(AppTheme.gapMd),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.location_on_outlined),
                            SizedBox(width: AppTheme.gapSm),
                            Expanded(
                              child: Text(
                                'You must still be at the bin. The same '
                                'location, photo-content, duplicate, lockout, '
                                'and daily-limit checks apply on the website '
                                'and in the app.',
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: AppTheme.gapLg),
                    FilledButton.icon(
                      onPressed: _continue,
                      icon: Icon(
                        kIsWeb
                            ? Icons.add_photo_alternate_outlined
                            : Icons.photo_camera_outlined,
                      ),
                      label: const Text('Continue with this bin'),
                    ),
                  ] else ...[
                    const SizedBox(height: AppTheme.gapLg),
                    OutlinedButton.icon(
                      onPressed: () => _resolve(widget.payload),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try this code again'),
                    ),
                    const SizedBox(height: AppTheme.gapSm),
                    TextButton(
                      onPressed: () => context.go('/home'),
                      child: const Text('Go to Chokro home'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
