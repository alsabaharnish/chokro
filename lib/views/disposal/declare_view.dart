import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/disposal_controller.dart';
import '../../core/geo.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../models/disposal_model.dart';
import '../../services/verification_service.dart';

/// Step 4 of the disposal flow (F2.9): declare what is being disposed of, review
/// the submission, and write it.
///
/// The declared count and type are what the automated screen checks the
/// photograph against. They are not verification on their own — a user can type
/// any number — but a declaration that disagrees with the photograph is a signal
/// worth flagging, and asking for it costs one screen.
class DisposalDeclareView extends ConsumerWidget {
  const DisposalDeclareView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final draft = ref.watch(disposalDraftProvider);
    final controller = ref.read(disposalDraftProvider.notifier);
    final userAsync = ref.watch(currentUserProvider);
    final theme = Theme.of(context);
    final bin = draft.bin;

    if (draft.submittedId != null) {
      return _SubmittedView(
        isVerifying: draft.isVerifying,
        verification: draft.verification,
        onDone: () {
          controller.reset();
          context.go('/home');
        },
        onViewHistory: () {
          controller.reset();
          context.go('/history');
        },
      );
    }

    if (bin == null || !draft.hasPhoto || !draft.hasLocation) {
      return Scaffold(
        appBar: AppBar(title: const Text('Confirm disposal')),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('This submission is incomplete. Start again.'),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: () {
                    controller.reset();
                    context.go('/home');
                  },
                  child: const Text('Back to home'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Confirm disposal')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── What are you disposing of ───────────────────────────────
                Text('What are you disposing of?',
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),

                DropdownButtonFormField<DisposalItemType>(
                  initialValue: draft.itemType,
                  decoration: const InputDecoration(
                    labelText: 'Material',
                  ),
                  items: DisposalItemType.values
                      .map((type) => DropdownMenuItem(
                            value: type,
                            child: Text(type.label),
                          ))
                      .toList(),
                  onChanged: (type) {
                    if (type != null) controller.setItemType(type);
                  },
                ),

                const SizedBox(height: 20),

                Text('How many items?', style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  'Count what is visible in your photo.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 12),

                Card(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        IconButton.filledTonal(
                          onPressed: draft.declaredItemCount > 1
                              ? () => controller
                                  .setItemCount(draft.declaredItemCount - 1)
                              : null,
                          icon: const Icon(Icons.remove),
                        ),
                        Text(
                          '${draft.declaredItemCount}',
                          style: theme.textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        IconButton.filledTonal(
                          onPressed: draft.declaredItemCount < 100
                              ? () => controller
                                  .setItemCount(draft.declaredItemCount + 1)
                              : null,
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 12),

                // ── Review ──────────────────────────────────────────────────
                Text('Review', style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),

                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.delete_outline),
                        title: Text(bin.label),
                        subtitle: Text(draft.distanceMeters == null
                            ? 'Location captured'
                            : '${formatDistance(draft.distanceMeters!)} away'),
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: Image.file(
                            File(draft.photoPath!),
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                          ),
                        ),
                        title: Text(draft.itemType.label),
                        subtitle: Text(
                            '${draft.declaredItemCount} item'
                            '${draft.declaredItemCount == 1 ? '' : 's'}'),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                Card(
                  color: theme.colorScheme.surfaceContainerHighest,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(Icons.schedule,
                            color: theme.colorScheme.onSurfaceVariant),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Your submission is checked before points are '
                            'added. You will be told the outcome either way.',
                            style: theme.textTheme.bodySmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                if (draft.error != null) ...[
                  const SizedBox(height: 16),
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline,
                              color: theme.colorScheme.onErrorContainer),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              draft.error!,
                              style: TextStyle(
                                  color: theme.colorScheme.onErrorContainer),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                const SizedBox(height: 24),

                if (draft.isSubmitting)
                  const Center(child: CircularProgressIndicator())
                else
                  FilledButton.icon(
                    onPressed: () async {
                      final user = userAsync.value;
                      if (user == null) return;
                      await controller.submit(uid: user.uid);
                    },
                    icon: const Icon(Icons.send),
                    label: const Text('Submit disposal'),
                  ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The confirmation screen, reporting what verification actually decided.
///
/// ## What this used to do
///
/// It said "your disposal is being checked" and nothing else — always, for
/// everyone. Meanwhile `DisposalDraftController.submit` awaits the trusted
/// service, stores the answer in `draft.verification`, and tracks the wait in
/// `draft.isVerifying`; the screen read neither. So a submission that had been
/// auto-approved, with the points already in the user's wallet, told them to go
/// and wait for a reviewer. `VerificationOutcome.userMessage` was written for
/// this screen and had no caller.
///
/// Three states now, because they mean genuinely different things to the user:
/// still deciding, credited, or queued for a person.
class _SubmittedView extends StatelessWidget {
  const _SubmittedView({
    required this.isVerifying,
    required this.verification,
    required this.onDone,
    required this.onViewHistory,
  });

  final bool isVerifying;
  final VerificationOutcome? verification;
  final VoidCallback onDone;
  final VoidCallback onViewHistory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final outcome = verification;

    // Deliberately not `PopScope(canPop: false)`: the submission is already
    // written and safe, so trapping the user here would be theatre. But the back
    // gesture should land at home rather than the count screen they just left.
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTheme.gapXl),
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: AppTheme.maxFormWidth),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isVerifying)
                    ..._verifying(theme)
                  else if (outcome != null && outcome.wasAutoApproved)
                    ..._approved(theme, scheme, outcome)
                  else
                    ..._queued(theme, scheme, outcome),

                  const SizedBox(height: AppTheme.gapXl),

                  // No buttons while the server is still deciding: leaving now
                  // would not lose the submission, but the answer is seconds
                  // away and it is worth waiting for.
                  if (!isVerifying) ...[
                    FilledButton(
                      onPressed: onDone,
                      child: const Text('Done'),
                    ),
                    const SizedBox(height: AppTheme.gapSm),
                    TextButton.icon(
                      onPressed: onViewHistory,
                      icon: const Icon(Icons.receipt_long_outlined, size: 18),
                      label: const Text('See my submissions'),
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

  List<Widget> _verifying(ThemeData theme) => [
        const SizedBox(
          width: 44,
          height: 44,
          child: CircularProgressIndicator(strokeWidth: 3),
        ),
        const SizedBox(height: AppTheme.gapLg),
        Text(
          'Checking your submission',
          style: theme.textTheme.titleLarge
              ?.copyWith(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppTheme.gapSm),
        Text(
          'It is saved either way — this only decides whether the points can '
          'be added right now.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ];

  List<Widget> _approved(
    ThemeData theme,
    ColorScheme scheme,
    VerificationOutcome outcome,
  ) =>
      [
        Container(
          padding: const EdgeInsets.all(AppTheme.gapLg),
          decoration: BoxDecoration(
            color: scheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.check_circle,
            size: 56,
            color: scheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(height: AppTheme.gapLg),
        Text(
          'Approved',
          style: theme.textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: AppTheme.gapSm),
        // The number is the news. It gets the display size, not body text.
        Text(
          '+${outcome.pointsAwarded}',
          style: theme.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.bold,
            color: scheme.primary,
          ),
        ),
        Text(
          outcome.pointsAwarded == 1 ? 'point added' : 'points added',
          style: theme.textTheme.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (outcome.balanceAfter != null) ...[
          const SizedBox(height: AppTheme.gapSm),
          Text(
            'Your balance is now ${outcome.balanceAfter}.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ],
      ];

  List<Widget> _queued(
    ThemeData theme,
    ColorScheme scheme,
    VerificationOutcome? outcome,
  ) =>
      [
        Container(
          padding: const EdgeInsets.all(AppTheme.gapLg),
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.hourglass_top_outlined,
            size: 56,
            color: scheme.onSecondaryContainer,
          ),
        ),
        const SizedBox(height: AppTheme.gapLg),
        Text(
          'Sent for review',
          style: theme.textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.bold),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppTheme.gapSm),
        Text(
          // `userMessage` names the actual reason when the server gave one —
          // "sent for review: the photo does not match the declared count" is
          // worth far more to the user than a generic wait.
          outcome?.userMessage ??
              'Your submission is saved and waiting for a reviewer.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium,
        ),
        if (outcome != null && outcome.reasons.length > 1) ...[
          const SizedBox(height: AppTheme.gapMd),
          Card(
            color: scheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(AppTheme.gapMd),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final reason in outcome.reasons)
                    Padding(
                      padding: const EdgeInsets.only(bottom: AppTheme.gapXs),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.flag_outlined,
                              size: 15, color: scheme.onSurfaceVariant),
                          const SizedBox(width: AppTheme.gapSm),
                          Expanded(
                            child: Text(
                              humanise(reason),
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: AppTheme.gapSm),
        Text(
          'Points are added only if a reviewer approves it, and you will be '
          'told either way.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ];
}
