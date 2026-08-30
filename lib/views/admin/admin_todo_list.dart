import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/admin_workload_controller.dart';
import '../../core/theme.dart';

/// Today's live review workload for a 3ZERO Admin.
///
/// A row remains visible after its queue reaches zero when this administrator
/// completed work today, showing a green check. At local midnight those audit
/// counts reset and only new or still-pending work remains.
class AdminTodoList extends ConsumerWidget {
  const AdminTodoList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workload = ref.watch(adminWorkloadProvider);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final visible = AdminTaskKind.values
        .where((kind) => workload.progressFor(kind).isVisible)
        .toList();

    return Card(
      color: scheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    Icons.task_alt_rounded,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Today's review list",
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        _summary(workload),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (workload.pendingTotal > 0)
                  _CountPill(
                    label:
                        '${workload.pendingTotal}'
                        '${workload.hasCappedPending ? '+' : ''} remaining',
                    background: scheme.errorContainer,
                    foreground: scheme.onErrorContainer,
                  ),
              ],
            ),
            const SizedBox(height: AppTheme.gapMd),
            if (workload.isLoading && visible.isEmpty)
              const LinearProgressIndicator(minHeight: 3)
            else if (visible.isEmpty)
              _AllDone(hasError: workload.hasError)
            else
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: scheme.outlineVariant),
                  borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                ),
                child: Column(
                  children: [
                    for (var index = 0; index < visible.length; index++) ...[
                      _TaskRow(
                        kind: visible[index],
                        progress: workload.progressFor(visible[index]),
                      ),
                      if (index < visible.length - 1) const Divider(),
                    ],
                  ],
                ),
              ),
            if (workload.hasError) ...[
              const SizedBox(height: AppTheme.gapSm),
              Text(
                'Some review counts could not refresh. Visible counts may be partial.',
                style: theme.textTheme.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _summary(AdminWorkload workload) {
    if (workload.pendingTotal == 0 && workload.completedTodayTotal == 0) {
      return 'No reviews are waiting right now.';
    }
    if (workload.pendingTotal == 0) {
      return '${workload.hasCappedCompleted ? 'At least ' : ''}'
          '${workload.completedTodayTotal} completed today. Everything is clear.';
    }
    if (workload.completedTodayTotal == 0) {
      return '${workload.hasCappedPending ? 'At least ' : ''}'
          '${workload.pendingTotal} waiting for your decision.';
    }
    return '${workload.hasCappedCompleted ? 'At least ' : ''}'
        '${workload.completedTodayTotal} done today · '
        '${workload.hasCappedPending ? 'at least ' : ''}'
        '${workload.pendingTotal} still waiting.';
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({required this.kind, required this.progress});

  final AdminTaskKind kind;
  final AdminTaskProgress progress;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final canOpen = progress.pending > 0;

    return Semantics(
      button: canOpen,
      label:
          '${_label(kind)}. '
          '${progress.atCap ? 'At least ' : ''}${progress.pending} waiting. '
          '${progress.completedAtCap ? 'At least ' : ''}'
          '${progress.completedToday} completed today.',
      child: InkWell(
        onTap: canOpen ? () => context.push(_path(kind)) : null,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: canOpen
                      ? scheme.secondaryContainer
                      : scheme.successContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  canOpen ? _icon(kind) : Icons.check_rounded,
                  size: 20,
                  color: canOpen
                      ? scheme.onSecondaryContainer
                      : scheme.onSuccessContainer,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _label(kind),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Wrap(
                      spacing: 7,
                      runSpacing: 5,
                      children: [
                        if (progress.pending > 0)
                          _StatusPill(
                            icon: Icons.schedule_rounded,
                            label: '${progress.badgeLabel} waiting',
                            background: scheme.errorContainer,
                            foreground: scheme.onErrorContainer,
                          ),
                        if (progress.completedToday > 0)
                          _StatusPill(
                            icon: Icons.check_circle_rounded,
                            label:
                                '${progress.completedToday}'
                                '${progress.completedAtCap ? '+' : ''} done today',
                            background: scheme.successContainer,
                            foreground: scheme.onSuccessContainer,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              if (canOpen) ...[
                const SizedBox(width: AppTheme.gapSm),
                Icon(
                  Icons.arrow_forward_rounded,
                  size: 19,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _AllDone extends StatelessWidget {
  const _AllDone({required this.hasError});

  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.all(AppTheme.gapMd),
      decoration: BoxDecoration(
        color: scheme.successContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusMd),
      ),
      child: Row(
        children: [
          Icon(Icons.done_all_rounded, color: scheme.onSuccessContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              hasError
                  ? 'No waiting work is visible.'
                  : 'All caught up. New reviews will appear here automatically.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSuccessContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({
    required this.icon,
    required this.label,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: foreground),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
            color: foreground,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class _CountPill extends StatelessWidget {
  const _CountPill({
    required this.label,
    required this.background,
    required this.foreground,
  });

  final String label;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      label,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: foreground,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}

String _label(AdminTaskKind kind) => switch (kind) {
  AdminTaskKind.disposal => 'Disposal reviews',
  AdminTaskKind.claim => 'Eco-action reviews',
  AdminTaskKind.appeal => 'Appeals',
  AdminTaskKind.application => 'Greenpreneur applications',
};

String _path(AdminTaskKind kind) => switch (kind) {
  AdminTaskKind.disposal => '/admin/disposals',
  AdminTaskKind.claim => '/admin/claims',
  AdminTaskKind.appeal => '/admin/appeals',
  AdminTaskKind.application => '/admin/applications',
};

IconData _icon(AdminTaskKind kind) => switch (kind) {
  AdminTaskKind.disposal => Icons.fact_check_outlined,
  AdminTaskKind.claim => Icons.eco_outlined,
  AdminTaskKind.appeal => Icons.gavel_outlined,
  AdminTaskKind.application => Icons.storefront_outlined,
};
