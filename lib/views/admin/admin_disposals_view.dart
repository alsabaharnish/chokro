import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/admin_review_controller.dart';
import '../../core/geo.dart';
import '../../core/label_format.dart';
import '../../core/submitter_record.dart';
import '../../core/theme.dart';
import '../../models/disposal_model.dart';
import '../shared/app_shell.dart';
import '../shared/rejection_reason_dialog.dart';
import '../shared/error_retry.dart';

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
        messenger.showSnackBar(
          SnackBar(
            content: Text(next.error!),
            backgroundColor: theme.colorScheme.error,
          ),
        );
      } else if (next.lastMessage != null) {
        messenger.showSnackBar(SnackBar(content: Text(next.lastMessage!)));
      }
    });

    return AppShell(
      title: 'Review queue',
      child: pending.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (err, _) => ErrorRetry(
          error: err,
          title: 'The review queue',
          onRetry: () => ref.invalidate(pendingDisposalsProvider),
        ),
        data: (disposals) {
          if (disposals.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.inbox_outlined,
                      size: 56,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
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
          // `CachedNetworkImage`, not `Image.network`. A reviewer scrolls this
          // queue repeatedly, and `Image.network` re-fetched every full-size
          // photograph each time a card scrolled back into view. The rest of the
          // app already caches; this screen was the one that did not, and it is
          // the screen that loads the most images.
          AspectRatio(
            aspectRatio: 4 / 3,
            child: CachedNetworkImage(
              imageUrl: disposal.photoUrl,
              fit: BoxFit.cover,
              placeholder: (_, _) => ColoredBox(
                color: theme.colorScheme.surfaceContainerHighest,
                child: const Center(child: CircularProgressIndicator()),
              ),
              errorWidget: (_, _, _) => ColoredBox(
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
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),

                // The submitter's prior record (F2.7).
                //
                // The queue showed the photograph, the distance and the flags,
                // and left the reviewer to judge every borderline case in
                // isolation. An ambiguous photo from an account with thirty
                // clean approvals is almost certainly a bad angle; the same
                // photo from one with four rejections in its last ten is not.
                // Nothing on this screen could tell those apart.
                _SubmitterRecordLine(
                  record: ref.watch(submitterRecordProvider(disposal.userId)),
                ),

                const SizedBox(height: 12),

                // ── Evidence ──────────────────────────────────────────────
                _Fact(
                  icon: Icons.category_outlined,
                  label: 'Declared',
                  value:
                      '${disposal.declaredItemCount} × '
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
                  value:
                      '${formatDistance(disposal.distanceMeters)} (reported)',
                ),
                if (disposal.createdAt != null)
                  _Fact(
                    icon: Icons.schedule,
                    label: 'Submitted',
                    // `formatAge` from core/label_format, rather than the
                    // private copy that used to live here. Two relative-time
                    // formatters that disagreed past a week — this one fell back
                    // to "d ago" forever, the shared one switches to a date.
                    value: formatAge(disposal.createdAt),
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
                          Icon(
                            Icons.flag_outlined,
                            size: 18,
                            color: theme.colorScheme.error,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              flag.explanation,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                if (!disposal.verificationCompleted) ...[
                  const SizedBox(height: 12),
                  Card(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: ListTile(
                      leading: const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      title: const Text('Verification is still running'),
                      subtitle: const Text(
                        'Approval will unlock when the server evidence arrives.',
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
                          onPressed: disposal.verificationCompleted
                              ? () => controller.approve(disposal.id ?? '')
                              : null,
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
  ///
  /// The dialog is shared with the claim queue and the applications list. Each
  /// used to have its own copy, and each leaked the controller behind it.
  Future<void> _askReason(
    BuildContext context,
    AdminReviewController controller,
  ) async {
    final reason = await showRejectionReasonDialog(
      context,
      title: 'Why are you rejecting this?',
      hintText: 'The photo does not show the declared items.',
    );

    // Already trimmed and length-checked by the dialog; null means cancelled.
    if (reason == null) return;
    await controller.reject(disposal.id ?? '', reason);
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
          Expanded(child: Text(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

// `_QueueError` was deleted in favour of the shared `ErrorRetry`.
//
// It knew something worth keeping — that a missing composite index is the
// overwhelmingly likely cause the first time this screen runs — but it detected
// that by substring-matching `error.toString()` for 'index', and it printed the
// raw exception underneath. That knowledge now lives in `friendlyErrorMessage`,
// keyed on Firestore's actual `failed-precondition` code rather than on the
// wording of a message. It also had no retry, which was the other half of the
// problem: the queue is the screen an administrator sits on all shift.

/// One line describing how this submitter has fared before (F2.7).
class _SubmitterRecordLine extends StatelessWidget {
  const _SubmitterRecordLine({required this.record});

  final AsyncValue<SubmitterRecord> record;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // A record that has not arrived, or failed to, says nothing rather than
    // guessing. "First submission" would be a claim, and on a screen that
    // decides payouts a wrong claim is worse than a blank.
    final value = record.value;
    if (value == null) return const SizedBox.shrink();

    final flagged = value.hasRejections;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Icon(
            flagged ? Icons.history_toggle_off : Icons.history,
            size: 14,
            color: flagged
                ? theme.colorScheme.warning
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value.summary,
              style: theme.textTheme.bodySmall?.copyWith(
                color: flagged
                    ? theme.colorScheme.warning
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: flagged ? FontWeight.w600 : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
