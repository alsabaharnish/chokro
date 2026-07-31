import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/admin_review_controller.dart';
import '../../core/geo.dart';
import '../../models/disposal_model.dart';
import '../shared/app_shell.dart';

/// Administrator review queue (F2.7, F2.8).
///
/// Shows every pending submission with the evidence needed to decide: the
/// photograph, what the user declared, how far from the bin they were, and any
/// flags the server raised. A queue that shows a photo and nothing else forces
/// the administrator to guess, which is how rubber-stamping starts.
///
/// Both buttons call the trusted service. Nothing on this screen writes
/// Firestore — an administrator cannot credit a wallet from a client, and there
/// is a rules test asserting exactly that.
class AdminDisposalsView extends ConsumerWidget {
  const AdminDisposalsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingDisposalsProvider);
    final ui = ref.watch(adminReviewControllerProvider);
    final theme = Theme.of(context);

    ref.listen(adminReviewControllerProvider, (previous, next) {
      final messenger = ScaffoldMessenger.of(context);
      if (next.error != null) {
        messenger.showSnackBar(SnackBar(
          content: Text(next.error!),
          backgroundColor: theme.colorScheme.error,
        ));
      } else if (next.lastMessage != null) {
        messenger.showSnackBar(SnackBar(content: Text(next.lastMessage!)));
      }
    });

    return AppShell(
      title: 'Review queue',
      child: pending.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => _QueueError(error: err, theme: theme),
        data: (disposals) {
          if (disposals.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.inbox_outlined,
                        size: 56, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(height: 16),
                    Text('Nothing waiting', style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Submissions needing a human decision appear here.',
                      style: theme.textTheme.bodySmall,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: disposals.length,
            itemBuilder: (context, index) => Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: _DisposalCard(
                  disposal: disposals[index],
                  isBusy: ui.isBusy(disposals[index].id ?? ''),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _DisposalCard extends ConsumerWidget {
  final DisposalModel disposal;
  final bool isBusy;

  const _DisposalCard({required this.disposal, required this.isBusy});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final controller = ref.read(adminReviewControllerProvider.notifier);
    final submitter = ref.watch(submitterProvider(disposal.userId));
    final bin = ref.watch(binForReviewProvider(disposal.binId));

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Photograph ────────────────────────────────────────────────────
          AspectRatio(
            aspectRatio: 4 / 3,
            child: Image.network(
              disposal.photoUrl,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, progress) => progress == null
                  ? child
                  : const Center(child: CircularProgressIndicator()),
              errorBuilder: (context, error, stack) => ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: const Center(child: Icon(Icons.broken_image_outlined)),
              ),
            ),
          ),

          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  submitter.maybeWhen(
                    data: (user) => user?.name ?? disposal.userId,
                    orElse: () => disposal.userId,
                  ),
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),

                // ── Evidence ──────────────────────────────────────────────
                _Fact(
                  icon: Icons.category_outlined,
                  label: 'Declared',
                  value: '${disposal.declaredItemCount} × '
                      '${disposal.itemType.label}',
                ),
                _Fact(
                  icon: Icons.delete_outline,
                  label: 'Bin',
                  value: bin.maybeWhen(
                    data: (b) => b?.label ?? disposal.binId,
                    orElse: () => disposal.binId,
                  ),
                ),
                _Fact(
                  icon: Icons.straighten,
                  label: 'Distance',
                  // The client's figure. The server recomputed it from the
                  // stored coordinates before this row appeared — a discrepancy
                  // between the two is itself a signal.
                  value: '${formatDistance(disposal.distanceMeters)} (reported)',
                ),
                if (disposal.createdAt != null)
                  _Fact(
                    icon: Icons.schedule,
                    label: 'Submitted',
                    value: _relative(disposal.createdAt!),
                  ),

                // ── Flags ─────────────────────────────────────────────────
                if (disposal.hasFlags) ...[
                  const SizedBox(height: 12),
                  ...disposal.flags.map(
                    (flag) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.flag_outlined,
                              size: 18, color: theme.colorScheme.error),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              flag.explanation,
                              style: theme.textTheme.bodySmall
                                  ?.copyWith(color: theme.colorScheme.error),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 16),

                if (isBusy)
                  const Center(child: CircularProgressIndicator())
                else
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => _askReason(context, controller),
                          icon: const Icon(Icons.close),
                          label: const Text('Reject'),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: theme.colorScheme.error,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () =>
                              controller.approve(disposal.id ?? ''),
                          icon: const Icon(Icons.check),
                          label: const Text('Approve'),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Rejection requires a reason, and the user is shown it. A rejection with no
  /// explanation is indistinguishable from the system being broken, and it makes
  /// an appeal impossible to answer.
  Future<void> _askReason(
    BuildContext context,
    AdminReviewController controller,
  ) async {
    final textController = TextEditingController();

    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Why are you rejecting this?'),
        content: TextField(
          controller: textController,
          autofocus: true,
          maxLines: 3,
          decoration: const InputDecoration(
            hintText: 'The photo does not show the declared items.',
            border: OutlineInputBorder(),
            helperText: 'This is shown to the user.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(textController.text),
            child: const Text('Reject'),
          ),
        ],
      ),
    );

    if (reason != null && reason.trim().isNotEmpty) {
      await controller.reject(disposal.id ?? '', reason);
    }
  }

  static String _relative(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    return '${diff.inDays} d ago';
  }
}

class _Fact extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _Fact({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          SizedBox(
            width: 78,
            child: Text(label, style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: Text(value, style: theme.textTheme.bodyMedium),
          ),
        ],
      ),
    );
  }
}

class _QueueError extends StatelessWidget {
  final Object error;
  final ThemeData theme;

  const _QueueError({required this.error, required this.theme});

  @override
  Widget build(BuildContext context) {
    // A missing composite index is the overwhelmingly likely cause the first
    // time this screen runs: the query filters on status and orders by
    // createdAt, which Firestore cannot serve from single-field indexes.
    final text = error.toString();
    final needsIndex = text.contains('index');

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              needsIndex
                  ? 'This query needs a Firestore composite index. Open the '
                      'console link in the debug output to create it — it takes '
                      'about a minute to build.'
                  : 'Could not load the queue.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
