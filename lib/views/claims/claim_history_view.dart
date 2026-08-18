import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';
import '../shared/app_shell.dart';
import 'claim_submit_view.dart' show ClaimHistoryList;

/// Eco-action history (F7.2, F6.1).
///
/// F7.2 asks for "in-app submission history with status and reason", and until
/// now it delivered that for disposals only. `ClaimHistoryList` existed and was
/// mounted — but *inside the claim submit form*, so it was visible only while
/// composing a new claim and vanished the moment one was submitted. The one
/// moment a user most wants to see a claim's status was the one moment they
/// could not.
///
/// It also gave claim notifications nowhere sensible to land. A rejected claim
/// credits nothing, so the wallet has no entry for it, and "My submissions"
/// reads disposals only; the push allow-list was pointing at `/claims/new`, a
/// form. This is the screen it should have been pointing at all along.
class ClaimHistoryView extends ConsumerWidget {
  const ClaimHistoryView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return AppShell(
      title: 'Eco-actions',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTheme.maxContentWidth),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.gapMd,
              AppTheme.gapMd,
              AppTheme.gapMd,
              AppTheme.gapXl,
            ),
            children: [
              Text(
                'Your eco-actions',
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: AppTheme.gapXs),
              Text(
                'Every action you have logged, with its status and — where one '
                'was given — the reason it was not approved.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: AppTheme.gapMd),

              // The same widget the submit form shows, so the two can never
              // disagree about how a claim's status reads.
              const ClaimHistoryList(),

              const SizedBox(height: AppTheme.gapLg),
              OutlinedButton.icon(
                onPressed: () => context.push('/claims/new'),
                icon: const Icon(Icons.add),
                label: const Text('Log another eco-action'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
