import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/claim_controller.dart';
import '../../core/label_format.dart';
import '../../models/claim_model.dart';
import '../shared/app_shell.dart';

/// Submitting a self-reported eco-action (F6.1, F6.2, F6.4).
///
/// The screen is honest with the user about what this route is. A claim pays
/// less than a disposal and always waits for a person, and saying so up front
/// is better than letting someone expect an instant credit and feel cheated.
class ClaimSubmitView extends ConsumerWidget {
  const ClaimSubmitView({super.key});

  static const double _maxContentWidth = 640;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(claimDraftProvider);
    final quota = ref.watch(claimQuotaProvider);
    final theme = Theme.of(context);

    if (draft.submittedId != null) {
      return const _ClaimSubmitted();
    }

    return AppShell(
      title: 'Log an eco-action',
      child: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: ClaimSubmitView._maxContentWidth),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              quota.when(
                loading: () => const LinearProgressIndicator(),
                error: (error, _) => _Notice(
                  icon: Icons.cloud_off_outlined,
                  tone: theme.colorScheme.onSurfaceVariant,
                  text: 'Your weekly quota could not be checked. You can still '
                      'submit; the server will decide.',
                ),
                data: (q) => _Notice(
                  icon: q.isExhausted
                      ? Icons.block
                      : Icons.calendar_today_outlined,
                  tone: q.isExhausted
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                  text: q.summary,
                ),
              ),
              const SizedBox(height: 8),
              _Notice(
                icon: Icons.person_search_outlined,
                tone: theme.colorScheme.onSurfaceVariant,
                text: 'Every eco-action is checked by a person, so points '
                    'arrive after review rather than straight away. Disposals '
                    'at a registered bin are verified automatically and pay '
                    'more.',
              ),
              const SizedBox(height: 20),
              Text('What did you do?',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 10),
              // RadioGroup owns the selection and the callback; the tiles
              // below only declare their value. Flutter 3.32 deprecated the
              // per-tile groupValue/onChanged pair.
              RadioGroup<ClaimActionType>(
                groupValue: draft.actionType,
                onChanged: (value) {
                  if (value != null) {
                    ref.read(claimDraftProvider.notifier).setActionType(value);
                  }
                },
                child: Column(
                  children: [
                    for (final type in ClaimActionType.values)
                      RadioListTile<ClaimActionType>(
                        value: type,
                        title: Text(type.label),
                        subtitle: Text(
                          type.evidenceHint,
                          style: theme.textTheme.bodySmall,
                        ),
                        contentPadding: EdgeInsets.zero,
                        dense: true,
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              Text('Evidence',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text(
                draft.actionType?.evidenceHint ??
                    'Choose an action above, then photograph it.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 12),
              if (draft.hasPhoto)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: Image.file(
                    File(draft.photoPath!),
                    height: 220,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              if (draft.hasPhoto) const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: draft.isCapturing || draft.isSubmitting
                    ? null
                    : () =>
                        ref.read(claimDraftProvider.notifier).capturePhoto(),
                icon: draft.isCapturing
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.photo_camera_outlined),
                label: Text(
                  draft.hasPhoto ? 'Retake photo' : 'Take photo',
                ),
              ),
              if (draft.error != null) ...[
                const SizedBox(height: 14),
                Text(
                  draft.error!,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              ],
              const SizedBox(height: 22),
              FilledButton.icon(
                onPressed: draft.isReadyToSubmit && !draft.isSubmitting
                    ? () => ref.read(claimDraftProvider.notifier).submit()
                    : null,
                icon: draft.isSubmitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.send_outlined),
                label: Text(draft.isSubmitting ? 'Submitting…' : 'Submit claim'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ClaimSubmitted extends ConsumerWidget {
  const _ClaimSubmitted();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return AppShell(
      title: 'Claim submitted',
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.check_circle_outline,
                  size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('Sent for review', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                'A reviewer will look at your photo. Points are added to your '
                'wallet only if it is approved, and you will be told either '
                'way.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () =>
                    ref.read(claimDraftProvider.notifier).reset(),
                child: const Text('Log another'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A user's own claim history, appended to the submission screen's flow.
class ClaimHistoryList extends ConsumerWidget {
  const ClaimHistoryList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final claims = ref.watch(userClaimsProvider);

    return claims.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => Text('Claims did not load: $error'),
      data: (items) {
        if (items.isEmpty) {
          return Text(
            'No eco-actions logged yet.',
            style: theme.textTheme.bodySmall,
          );
        }
        return Column(
          children: [
            for (final claim in items)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  claim.status.isApproved
                      ? Icons.check_circle_outline
                      : claim.status.isRejected
                          ? Icons.cancel_outlined
                          : Icons.hourglass_empty_outlined,
                  color: claim.status.isApproved
                      ? theme.colorScheme.primary
                      : claim.status.isRejected
                          ? theme.colorScheme.error
                          : theme.colorScheme.onSurfaceVariant,
                ),
                title: Text(claim.actionType.label),
                subtitle: Text(
                  [
                    claim.userFacingStatus,
                    formatAge(claim.createdAt),
                    if (claim.status.isRejected && claim.rejectionReason != null)
                      claim.rejectionReason!,
                  ].join(' · '),
                  style: theme.textTheme.bodySmall,
                ),
                trailing: claim.status.isApproved
                    ? Text(
                        '+${claim.creditedPoints}',
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      )
                    : null,
              ),
          ],
        );
      },
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.tone, required this.text});

  final IconData icon;
  final Color tone;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: tone),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: tone),
          ),
        ),
      ],
    );
  }
}
