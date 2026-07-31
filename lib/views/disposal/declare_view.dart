import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/disposal_controller.dart';
import '../../core/geo.dart';
import '../../models/disposal_model.dart';

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
        theme: theme,
        onDone: () {
          controller.reset();
          context.go('/home');
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
                    border: OutlineInputBorder(),
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

class _SubmittedView extends StatelessWidget {
  final ThemeData theme;
  final VoidCallback onDone;

  const _SubmittedView({required this.theme, required this.onDone});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.check_circle,
                    size: 72, color: theme.colorScheme.primary),
                const SizedBox(height: 24),
                Text(
                  'Submitted',
                  style: theme.textTheme.headlineSmall
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                Text(
                  'Your disposal is being checked. Points are added once it is '
                  'approved, and you can follow it in your history.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: 32),
                FilledButton(
                  onPressed: onDone,
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
