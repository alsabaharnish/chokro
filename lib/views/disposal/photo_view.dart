import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/disposal_controller.dart';
import '../shared/flow_progress.dart';

/// Step 2 of the disposal flow (F2.3): photograph the disposal.
///
/// The photo is captured and compressed here but **not uploaded** — upload
/// happens at submission, once the user has committed to the whole thing.
/// Uploading eagerly would leave orphaned files in Storage every time someone
/// backs out, and Storage has no automatic cleanup.
class DisposalPhotoView extends ConsumerWidget {
  const DisposalPhotoView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(disposalDraftProvider);
    final controller = ref.read(disposalDraftProvider.notifier);
    final theme = Theme.of(context);
    final bin = draft.bin;

    // Reached without a resolved bin — deep link, or a hot restart wiping state.
    if (bin == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Photograph disposal'),
          bottom: const FlowProgress(current: 2, total: 4, label: 'Photo'),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.qr_code_scanner, size: 48),
                const SizedBox(height: 16),
                const Text(
                  'Scan a bin code first.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Back to scanner'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Photograph disposal'),
        bottom: const FlowProgress(current: 2, total: 4, label: 'Photo'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.delete_outline),
                    title: Text(bin.label),
                    subtitle: Text('Radius ${bin.radiusMeters.round()} m'),
                  ),
                ),
                const SizedBox(height: 20),

                Text('Your photo', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Show the items and the bin in one frame. This is what an '
                  'administrator sees if your submission needs review.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),

                AspectRatio(
                  aspectRatio: 4 / 3,
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: theme.dividerColor),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: draft.hasPhoto
                        ? Image.memory(
                            draft.photoBytes!,
                            fit: BoxFit.cover,
                            key: ObjectKey(draft.photoBytes),
                          )
                        : Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.photo_camera_outlined,
                                  size: 40,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  'No photo yet',
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                  ),
                ),

                if (draft.compressionSavingPercent != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Compressed ${_kb(draft.originalBytes!)} → '
                    '${_kb(draft.compressedBytes!)} '
                    '(${draft.compressionSavingPercent}% smaller, '
                    'location metadata removed)',
                    style: theme.textTheme.bodySmall,
                  ),
                ],

                if (draft.error != null) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Icon(
                            Icons.error_outline,
                            color: theme.colorScheme.onErrorContainer,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              draft.error!,
                              style: TextStyle(
                                color: theme.colorScheme.onErrorContainer,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 20),

                if (draft.isCapturing)
                  const Center(child: CircularProgressIndicator())
                else if (draft.hasPhoto)
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: controller.capturePhoto,
                          icon: const Icon(Icons.refresh),
                          label: Text(kIsWeb ? 'Replace' : 'Retake'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => context.push('/dispose/location'),
                          icon: const Icon(Icons.my_location),
                          label: const Text('Continue'),
                        ),
                      ),
                    ],
                  )
                else
                  FilledButton.icon(
                    onPressed: controller.capturePhoto,
                    icon: Icon(
                      kIsWeb
                          ? Icons.add_photo_alternate_outlined
                          : Icons.photo_camera,
                    ),
                    label: Text(kIsWeb ? 'Choose photo' : 'Take photo'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _kb(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024).round()} KB';
  }
}
