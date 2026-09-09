import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/producer_workspace_controller.dart';
import '../../core/theme.dart';
import '../../models/producer_audit_model.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';

/// The organisation's own activity trail (EPR-44, SEC-12).
///
/// Chokro's Admins see the same log through their own route, and the log
/// records which of the two read it. That distinction is the point of EPR-46:
/// there is no impersonation anywhere in this system, so an entry always names
/// a real principal, and a Chokro employee opening this company's workspace
/// appears in it as themselves.
///
/// The chain digest is shown because a tamper-evidence control nobody can check
/// is a claim rather than a control. The producer holding this screen can
/// compare a digest against a copy taken earlier; the client never computes one.
class ProducerActivityView extends ConsumerWidget {
  const ProducerActivityView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activity = ref.watch(orgActivityProvider);

    return AppShell(
      title: 'Activity trail',
      child: activity.when(
        loading: () => const ContentLoading(
          label: 'Loading your activity trail…',
          slowHint: ContentLoading.serverWakingHint,
        ),
        error: (error, _) => ErrorRetry(
          error: error,
          onRetry: () => ref.invalidate(orgActivityProvider),
        ),
        data: (entries) => entries.isEmpty
            ? const ContentEmpty(
                icon: Icons.history_outlined,
                title: 'Nothing recorded yet',
                message:
                    'Every change to your company record appears here: members '
                    'invited or removed, details updated, documents issued.',
              )
            : _ActivityList(entries: entries),
      ),
    );
  }
}

class _ActivityList extends StatelessWidget {
  const _ActivityList({required this.entries});

  final List<ProducerAuditEntry> entries;

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.all(AppTheme.gapMd),
      // The list is capped on the server (QA-10). Whether it is a full history
      // is stated below rather than implied by its length.
      itemCount: entries.length + 2,
      itemBuilder: (context, index) {
        if (index == 0) {
          return const Padding(
            padding: EdgeInsets.only(bottom: AppTheme.gapMd),
            child: NoticeCard(
              icon: Icons.link_outlined,
              message:
                  'Each entry carries a fingerprint of the one before it, so a '
                  'removed or altered entry breaks the chain and can be '
                  'detected. Entries are never edited or deleted, by anyone.',
            ),
          );
        }
        if (index == entries.length + 1) {
          return Padding(
            padding: const EdgeInsets.only(top: AppTheme.gapMd),
            child: Text(
              'Showing the most recent ${entries.length} entries. The complete '
              'history is included in an audit pack.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          );
        }
        return _ActivityRow(entry: entries[index - 1]);
      },
    );
  }
}

class _ActivityRow extends StatelessWidget {
  const _ActivityRow({required this.entry});

  final ProducerAuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    ProducerAuditAction.label(entry.action),
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (entry.sequence != null)
                  Text(
                    '#${entry.sequence}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            if (entry.summary.isNotEmpty) ...[
              const SizedBox(height: AppTheme.gapXs),
              Text(entry.summary, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: AppTheme.gapSm),
            Wrap(
              spacing: AppTheme.gapMd,
              runSpacing: AppTheme.gapXs,
              children: [
                // The actor's role at the time, so an Admin's read of this
                // company's workspace is visibly a Chokro action and not one of
                // the company's own.
                if (entry.actorName.isNotEmpty || entry.actorRole.isNotEmpty)
                  _Meta(
                    icon: Icons.person_outline,
                    text: [
                      if (entry.actorName.isNotEmpty) entry.actorName,
                      if (entry.actorRole.isNotEmpty)
                        '(${entry.actorRole == 'admin' ? '3ZERO Admin' : 'your company'})',
                    ].join(' '),
                  ),
                if (entry.timestamp != null)
                  _Meta(
                    icon: Icons.schedule_outlined,
                    text: _timestamp(entry.timestamp!),
                  ),
                if (entry.isChained)
                  _Meta(
                    icon: Icons.fingerprint,
                    text: entry.digest!.substring(0, 12),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  const _Meta({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 13, color: theme.colorScheme.onSurfaceVariant),
        const SizedBox(width: 4),
        Text(
          text,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

String _timestamp(DateTime value) {
  final local = value.toLocal();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '${local.day}/${local.month}/${local.year} $hh:$mm';
}
