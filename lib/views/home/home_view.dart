import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/wallet_controller.dart';
import '../../controllers/submission_history_controller.dart';
import '../shared/app_shell.dart';

class HomeView extends ConsumerWidget {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(currentUserProvider);
    final walletAsync = ref.watch(walletProvider);
    final pendingCount = ref.watch(pendingSubmissionCountProvider);
    final theme = Theme.of(context);

    return AppShell(
      title: 'Chokro',
      child: userAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (user) {
          if (user == null) {
            return const Center(child: CircularProgressIndicator());
          }
          return SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Hello, ${user.name}',
                            style: theme.textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        Chip(
                          label: Text(user.role.toUpperCase()),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
                    if (!user.isActive)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Card(
                          color: theme.colorScheme.errorContainer,
                          child: const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              'This account is suspended. '
                              'Most actions are unavailable.',
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 24),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('Points balance',
                                style: theme.textTheme.labelLarge),
                            const SizedBox(height: 8),
                            walletAsync.when(
                              loading: () => const SizedBox(
                                height: 40,
                                child: Center(
                                  child: SizedBox(
                                    height: 20,
                                    width: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                ),
                              ),
                              error: (e, _) => Text('Unavailable: $e'),
                              data: (wallet) => Text(
                                '${wallet?.balance ?? 0}',
                                style: theme.textTheme.displaySmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Dispose waste (F2.2 entry point) ──────────────────
                    //
                    // Disabled for a suspended account. The Firestore rules
                    // refuse the submission anyway (`isActive()` on disposal
                    // create), so this is courtesy rather than enforcement —
                    // it stops a user walking to a bin and photographing a bag
                    // before finding out.
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: user.isActive
                            ? () => context.push('/dispose/scan')
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 24,
                                backgroundColor:
                                    theme.colorScheme.primaryContainer,
                                child: Icon(
                                  Icons.qr_code_scanner,
                                  color: theme.colorScheme.onPrimaryContainer,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Dispose waste',
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                              fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      user.isActive
                                          ? 'Scan the code on a bin to start.'
                                          : 'Unavailable while suspended.',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              if (user.isActive)
                                const Icon(Icons.chevron_right),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // ── My submissions (F7.2 entry point) ─────────────
                    //
                    // Shown to every account, including a suspended one: a
                    // user who cannot submit can still need to read why an
                    // earlier submission was rejected.
                    //
                    // The badge watches `submissionHistoryProvider`, so this
                    // screen holds a listener on the user's own disposals.
                    // That is one query, the same one the history screen uses.
                    // Drop `pendingCount` and the badge to remove it.
                    const SizedBox(height: 16),
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: () => context.push('/history'),
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 24,
                                backgroundColor:
                                    theme.colorScheme.tertiaryContainer,
                                child: Icon(
                                  Icons.receipt_long_outlined,
                                  color: theme.colorScheme.onTertiaryContainer,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'My submissions',
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                              fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      pendingCount == 0
                                          ? 'Status, reason and points for '
                                              'everything you have sent.'
                                          : pendingCount == 1
                                              ? '1 submission is waiting for '
                                                  'review.'
                                              : '$pendingCount submissions are '
                                                  'waiting for review.',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              if (pendingCount > 0)
                                Badge(
                                  label: Text('$pendingCount'),
                                  child: const SizedBox(width: 8, height: 20),
                                ),
                              const Icon(Icons.chevron_right),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // ── Log an eco-action (F6.1 entry point) ──────────
                    //
                    // Disabled while suspended for the same reason as disposal:
                    // the rules refuse the write anyway, and finding that out
                    // after photographing something is a poor experience.
                    const SizedBox(height: 16),
                    Card(
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: user.isActive
                            ? () => context.push('/claims/new')
                            : null,
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 24,
                                backgroundColor:
                                    theme.colorScheme.tertiaryContainer,
                                child: Icon(
                                  Icons.eco_outlined,
                                  color: theme.colorScheme.onTertiaryContainer,
                                ),
                              ),
                              const SizedBox(width: 16),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Log an eco-action',
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(
                                              fontWeight: FontWeight.bold),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      user.isActive
                                          ? 'Composting, tree planting and '
                                              'similar. Checked by a reviewer.'
                                          : 'Unavailable while suspended.',
                                      style: theme.textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              if (user.isActive) const Icon(Icons.chevron_right),
                            ],
                          ),
                        ),
                      ),
                    ),

                    // ── Admin: review queue ─────────────────────────────
                    if (user.isAdmin) ...[
                      const SizedBox(height: 16),
                      const SizedBox(height: 16),
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => context.push('/admin/claims'),
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 24,
                                  backgroundColor:
                                      theme.colorScheme.tertiaryContainer,
                                  child: Icon(
                                    Icons.eco_outlined,
                                    color:
                                        theme.colorScheme.onTertiaryContainer,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Claim review',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                                fontWeight: FontWeight.bold),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Self-reported eco-actions awaiting a '
                                        'decision.',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => context.push('/admin/bins'),
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 24,
                                  backgroundColor:
                                      theme.colorScheme.primaryContainer,
                                  child: Icon(
                                    Icons.qr_code_2,
                                    color: theme.colorScheme.onPrimaryContainer,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Bins',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                                fontWeight: FontWeight.bold),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Register a bin and print its code.',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => context.push('/admin/users'),
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 24,
                                  backgroundColor:
                                      theme.colorScheme.secondaryContainer,
                                  child: Icon(
                                    Icons.people_outline,
                                    color:
                                        theme.colorScheme.onSecondaryContainer,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Accounts',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                                fontWeight: FontWeight.bold),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Suspend or reinstate an account.',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => context.push('/admin/points'),
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 24,
                                  backgroundColor:
                                      theme.colorScheme.tertiaryContainer,
                                  child: Icon(
                                    Icons.tune,
                                    color:
                                        theme.colorScheme.onTertiaryContainer,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Points policy',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                                fontWeight: FontWeight.bold),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Tune awards, redemption and the '
                                        'anti-farming limits.',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                          ),
                        ),
                      ),
                      Card(
                        clipBehavior: Clip.antiAlias,
                        child: InkWell(
                          onTap: () => context.push('/admin/disposals'),
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: Row(
                              children: [
                                CircleAvatar(
                                  radius: 24,
                                  backgroundColor:
                                      theme.colorScheme.secondaryContainer,
                                  child: Icon(
                                    Icons.fact_check_outlined,
                                    color:
                                        theme.colorScheme.onSecondaryContainer,
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'Review queue',
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                                fontWeight: FontWeight.bold),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        'Approve or reject pending disposals.',
                                        style: theme.textTheme.bodySmall,
                                      ),
                                    ],
                                  ),
                                ),
                                const Icon(Icons.chevron_right),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
