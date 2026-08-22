import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/appeals_controller.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../models/appeal_model.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';

/// The user's own appeals and the answers they got (F5.4).
class AppealsView extends ConsumerWidget {
  const AppealsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appealsAsync = ref.watch(userAppealsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('My appeals')),
      body: appealsAsync.when(
        loading: () => const ContentLoading(label: 'Loading your appeals…'),
        error: (error, _) => ErrorRetry(
          error: error,
          title: 'Your appeals',
          onRetry: () => ref.invalidate(userAppealsProvider),
        ),
        data: (appeals) {
          if (appeals.isEmpty) {
            return ContentEmpty(
              icon: Icons.gavel_outlined,
              title: 'No appeals',
              message:
                  'If a submission is rejected and you think that was wrong, '
                  'you can appeal it from your history.',
              actionLabel: 'My submissions',
              onAction: () => context.go('/history'),
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.gapMd,
              AppTheme.gapMd,
              AppTheme.gapMd,
              AppTheme.gapXl,
            ),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppTheme.maxContentWidth,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final appeal in appeals) ...[
                        AppealCard(appeal: appeal),
                        const SizedBox(height: AppTheme.gapMd),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One appeal, from either side.
///
/// Shared with the administrator's queue so the reviewer reads exactly what the
/// user wrote and what any previous reviewer answered, in the same layout.
class AppealCard extends StatelessWidget {
  const AppealCard({super.key, required this.appeal, this.action});

  final AppealModel appeal;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (
      Color foreground,
      Color background,
      IconData icon,
    ) = switch (appeal.status) {
      AppealStatus.pending => (
        scheme.onSurfaceVariant,
        scheme.surfaceContainerHighest,
        Icons.hourglass_empty_outlined,
      ),
      AppealStatus.upheld => (
        scheme.onPrimaryContainer,
        scheme.primaryContainer,
        Icons.thumb_up_outlined,
      ),
      AppealStatus.declined => (
        scheme.onErrorContainer,
        scheme.errorContainer,
        Icons.thumb_down_outlined,
      ),
    };

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${appeal.subjectType.label} · '
                    '${formatAge(appeal.createdAt)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: background,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, size: 15, color: foreground),
                      const SizedBox(width: 5),
                      Text(
                        appeal.status.label,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: foreground,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.gapSm),
            Text(appeal.message, style: theme.textTheme.bodyMedium),

            if (appeal.response != null && appeal.response!.isNotEmpty) ...[
              const Divider(height: AppTheme.gapLg),
              Text(
                'The 3ZERO Admin answered',
                style: theme.textTheme.labelMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 2),
              Text(appeal.response!, style: theme.textTheme.bodyMedium),
              if (appeal.reviewedAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: AppTheme.gapXs),
                  child: Text(
                    formatDateTime(appeal.reviewedAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],

            if (action != null) ...[
              const SizedBox(height: AppTheme.gapMd),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
