import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/claim_controller.dart';
import '../../core/label_format.dart';
import '../../models/claim_model.dart';
import '../shared/app_shell.dart';
import '../shared/rejection_reason_dialog.dart';
import '../shared/error_retry.dart';

/// The claims review queue (F6.3).
///
/// Every card shows the submitter's **earlier claims** alongside the pending
/// one. That is not a convenience: with no geofence, no distance check and no
/// cross-user hash index, an administrator noticing "this is the same compost
/// heap as last week" is one of the few real defences this route has (§7.4).
class AdminClaimsView extends ConsumerWidget {
  const AdminClaimsView({super.key});

  static const double _maxContentWidth = 820;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingClaimsProvider);
    final ui = ref.watch(claimReviewControllerProvider);
    final theme = Theme.of(context);

    ref.listen(claimReviewControllerProvider, (previous, next) {
      final message = next.error ?? next.lastMessage;
      if (message == null) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
      ref.read(claimReviewControllerProvider.notifier).clearMessages();
    });

    return AppShell(
      title: 'Claim review',
      child: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: AdminClaimsView._maxContentWidth),
          child: pending.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => ErrorRetry(
              error: error,
              title: 'The claim queue',
              onRetry: () => ref.invalidate(pendingClaimsProvider),
            ),
            data: (claims) {
              if (claims.isEmpty) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.done_all,
                            size: 44,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(height: 14),
                        Text('Nothing waiting',
                            style: theme.textTheme.titleMedium),
                        const SizedBox(height: 6),
                        Text(
                          'Self-reported eco-actions appear here for review.',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                itemCount: claims.length,
                separatorBuilder: (_, _) => const SizedBox(height: 12),
                itemBuilder: (context, index) => _ClaimCard(
                  claim: claims[index],
                  isBusy: ui.isBusy(claims[index].id ?? ''),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _ClaimCard extends ConsumerWidget {
  const _ClaimCard({required this.claim, required this.isBusy});

  final ClaimModel claim;
  final bool isBusy;

  Future<void> _reject(BuildContext context, WidgetRef ref) async {
    final reason = await showRejectionReasonDialog(
      context,
      title: 'Reject this claim',
      hintText: 'The photo does not show the action described.',
    );

    if (reason == null || !context.mounted) return;
    await ref
        .read(claimReviewControllerProvider.notifier)
        .reject(claim.id ?? '', reason);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final submitter = ref.watch(claimSubmitterProvider(claim.userId));

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: CachedNetworkImage(
                    imageUrl: claim.photoUrl,
                    width: 110,
                    height: 110,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => Container(
                      width: 110,
                      height: 110,
                      color: theme.colorScheme.surfaceContainerHighest,
                    ),
                    errorWidget: (_, _, _) => Container(
                      width: 110,
                      height: 110,
                      color: theme.colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        claim.actionType.label,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        claim.actionType.evidenceHint,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 8),
                      submitter.when(
                        loading: () => const SizedBox(height: 14),
                        error: (_, _) => const SizedBox.shrink(),
                        data: (user) => Text(
                          user == null
                              ? 'Unknown submitter'
                              : '${user.name} · ${user.email}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                      Text(
                        'Submitted ${formatAge(claim.createdAt)}',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _PreviousClaims(userId: claim.userId, currentId: claim.id),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (isBusy)
                  const Padding(
                    padding: EdgeInsets.only(right: 12),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                TextButton(
                  onPressed: isBusy ? null : () => _reject(context, ref),
                  style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error),
                  child: const Text('Reject'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: isBusy
                      ? null
                      : () => ref
                          .read(claimReviewControllerProvider.notifier)
                          .approve(claim.id ?? ''),
                  child: const Text('Approve'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// This user's earlier claims, so a recycled photograph is visible.
class _PreviousClaims extends ConsumerWidget {
  const _PreviousClaims({required this.userId, required this.currentId});

  final String userId;
  final String? currentId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final history = ref.watch(claimHistoryForReviewProvider(userId));

    return history.when(
      loading: () => const SizedBox(height: 20),
      error: (_, _) => const SizedBox.shrink(),
      data: (claims) {
        final previous =
            claims.where((c) => c.id != currentId).take(6).toList();

        if (previous.isEmpty) {
          return Text(
            'First claim from this user.',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Earlier claims from this user',
              style: theme.textTheme.labelMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            SizedBox(
              height: 58,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: previous.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (context, index) {
                  final claim = previous[index];
                  return Tooltip(
                    message: '${claim.actionType.label}\n'
                        '${claim.userFacingStatus} · '
                        '${formatAge(claim.createdAt)}',
                    child: Stack(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: CachedNetworkImage(
                            imageUrl: claim.photoUrl,
                            width: 58,
                            height: 58,
                            fit: BoxFit.cover,
                            placeholder: (_, _) => Container(
                              width: 58,
                              height: 58,
                              color: theme.colorScheme.surfaceContainerHighest,
                            ),
                            errorWidget: (_, _, _) => Container(
                              width: 58,
                              height: 58,
                              color: theme.colorScheme.surfaceContainerHighest,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 2,
                          bottom: 2,
                          child: Icon(
                            claim.status.isApproved
                                ? Icons.check_circle
                                : claim.status.isRejected
                                    ? Icons.cancel
                                    : Icons.hourglass_empty,
                            size: 13,
                            color: claim.status.isApproved
                                ? theme.colorScheme.primary
                                : theme.colorScheme.error,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
