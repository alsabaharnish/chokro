import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/claim_controller.dart';
import '../../core/label_format.dart';
import '../../models/claim_model.dart';
import 'eco_action_photocard_dialog.dart';
import '../shared/app_shell.dart';
import '../shared/evidence_viewer.dart';
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
    final approved = ref.watch(approvedClaimsProvider);
    final ui = ref.watch(claimReviewControllerProvider);

    ref.listen(claimReviewControllerProvider, (previous, next) {
      final message = next.error ?? next.lastMessage;
      if (message == null) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
      ref.read(claimReviewControllerProvider.notifier).clearMessages();
    });

    return DefaultTabController(
      length: 2,
      child: AppShell(
        title: 'Eco-actions',
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AdminClaimsView._maxContentWidth,
            ),
            child: Column(
              children: [
                Material(
                  color: Theme.of(context).colorScheme.surface,
                  child: TabBar(
                    tabs: [
                      _TabLabel(
                        icon: Icons.fact_check_outlined,
                        label: 'Pending',
                        count: pending.value?.length,
                      ),
                      _TabLabel(
                        icon: Icons.photo_library_outlined,
                        label: 'Photocards',
                        count: approved.value?.length,
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    children: [
                      _PendingClaims(async: pending, ui: ui),
                      _ApprovedPhotocards(async: approved),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TabLabel extends StatelessWidget {
  const _TabLabel({required this.icon, required this.label, this.count});

  final IconData icon;
  final String label;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return Tab(
      icon: Icon(icon, size: 20),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (count != null && count! > 0) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$count',
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: Theme.of(context).colorScheme.onPrimaryContainer,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PendingClaims extends ConsumerWidget {
  const _PendingClaims({required this.async, required this.ui});

  final AsyncValue<List<ClaimModel>> async;
  final ClaimReviewUiState ui;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ErrorRetry(
        error: error,
        title: 'The eco-action queue',
        onRetry: () => ref.invalidate(pendingClaimsProvider),
      ),
      data: (claims) {
        if (claims.isEmpty) {
          return const _EmptyState(
            icon: Icons.done_all,
            title: 'Nothing waiting',
            message: 'Self-reported eco-actions appear here for review.',
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
    );
  }
}

class _ApprovedPhotocards extends ConsumerWidget {
  const _ApprovedPhotocards({required this.async});

  final AsyncValue<List<ClaimModel>> async;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final limit = ref.watch(approvedClaimLimitProvider);
    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => ErrorRetry(
        error: error,
        title: 'Approved eco-actions',
        onRetry: () => ref.invalidate(approvedClaimsProvider),
      ),
      data: (claims) {
        if (claims.isEmpty) {
          return const _EmptyState(
            icon: Icons.photo_library_outlined,
            title: 'No photocards yet',
            message: 'Approved eco-actions will be ready to publish here.',
          );
        }

        final canLoadOlder = claims.length >= limit;
        final gallery = LayoutBuilder(
          builder: (context, constraints) {
            final largeText = MediaQuery.textScalerOf(context).scale(1) > 1.3;
            if (constraints.maxWidth < 680 || largeText) {
              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                itemCount: claims.length,
                separatorBuilder: (_, _) => const SizedBox(height: 14),
                itemBuilder: (context, index) =>
                    _ApprovedClaimCard(claim: claims[index]),
              );
            }

            return GridView.builder(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 14,
                mainAxisSpacing: 14,
                childAspectRatio: .78,
              ),
              itemCount: claims.length,
              itemBuilder: (context, index) =>
                  _ApprovedClaimCard(claim: claims[index]),
            );
          },
        );

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Newest approvals first · ${claims.length} loaded',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: gallery),
            if (canLoadOlder)
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () => ref
                          .read(approvedClaimLimitProvider.notifier)
                          .loadOlder(),
                      icon: const Icon(Icons.expand_more),
                      label: const Text('Load older approved actions'),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ApprovedClaimCard extends StatelessWidget {
  const _ApprovedClaimCard({required this.claim});

  final ClaimModel claim;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final story = claim.story.trim();

    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                CachedNetworkImage(
                  // Review surface — see admin_disposals_view for why the URL
                  // is left alone and only the decode is bounded.
                  memCacheWidth: 1600,
                  imageUrl: claim.photoUrl,
                  fit: BoxFit.cover,
                  placeholder: (_, _) => ColoredBox(
                    color: theme.colorScheme.surfaceContainerHighest,
                  ),
                  errorWidget: (_, _, _) => ColoredBox(
                    color: theme.colorScheme.surfaceContainerHighest,
                    child: const Center(
                      child: Icon(Icons.broken_image_outlined),
                    ),
                  ),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, Color(0xB8002016)],
                    ),
                  ),
                ),
                Positioned(
                  left: 14,
                  right: 14,
                  bottom: 12,
                  child: Text(
                    claim.actionType.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      shadows: const [
                        Shadow(color: Colors.black38, blurRadius: 6),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _PublicationChip(claim: claim),
                const SizedBox(height: 10),
                Text(
                  story.isEmpty ? 'No personal story was added.' : '“$story”',
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: story.isEmpty
                        ? theme.colorScheme.onSurfaceVariant
                        : null,
                    fontStyle: story.isEmpty ? FontStyle.italic : null,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  claim.reviewedAt == null
                      ? 'Approved eco-action'
                      : 'Approved ${formatAge(claim.reviewedAt)}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: claim.hasPublicationPermission
                        ? () => showEcoActionPhotocardDialog(
                            context,
                            claim: claim,
                          )
                        : null,
                    icon: Icon(
                      claim.hasPublicationPermission
                          ? Icons.auto_awesome_outlined
                          : Icons.lock_outline,
                      size: 18,
                    ),
                    label: Text(
                      claim.hasPublicationPermission
                          ? 'Create photocard'
                          : 'Permission not recorded',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PublicationChip extends StatelessWidget {
  const _PublicationChip({required this.claim});

  final ClaimModel claim;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final named = claim.allowsIdentityPublication;
    final permitted = claim.hasPublicationPermission;
    final background = named
        ? theme.colorScheme.primaryContainer
        : permitted
        ? theme.colorScheme.secondaryContainer
        : theme.colorScheme.errorContainer;
    final foreground = named
        ? theme.colorScheme.onPrimaryContainer
        : permitted
        ? theme.colorScheme.onSecondaryContainer
        : theme.colorScheme.onErrorContainer;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            named
                ? Icons.person_pin_outlined
                : permitted
                ? Icons.privacy_tip_outlined
                : Icons.block_outlined,
            size: 14,
            color: foreground,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              claim.publicationLabel,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelSmall?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
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
                // A decision surface, not a thumbnail. This is the image an
                // admin approves or rejects a Champion's eco-action from, and
                // it was a 110 px square with no way to enlarge it — while the
                // appeals queue one tab away has had a zoomable viewer all
                // along.
                EvidenceThumbnail(
                  url: claim.photoUrl,
                  size: 110,
                  semanticLabel: 'Eco-action photograph',
                  caption: claim.actionType.label,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        claim.actionType.label,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
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
            _PublicationChip(claim: claim),
            if (claim.story.trim().isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Champion story',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 3),
              Text(claim.story.trim(), style: theme.textTheme.bodyMedium),
            ],
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
                    foregroundColor: theme.colorScheme.error,
                  ),
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
        final previous = claims
            .where((c) => c.id != currentId)
            .take(6)
            .toList();

        if (previous.isEmpty) {
          return Text(
            'First claim from this user.',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Earlier claims from this user',
              style: theme.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
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
                    message:
                        '${claim.actionType.label}\n'
                        '${claim.userFacingStatus} · '
                        '${formatAge(claim.createdAt)}',
                    child: Stack(
                      children: [
                        EvidenceThumbnail(
                          url: claim.photoUrl,
                          size: 58,
                          semanticLabel: 'Earlier eco-action photograph',
                          caption: 'Earlier claim — ${claim.actionType.label}',
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
