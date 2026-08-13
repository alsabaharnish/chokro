import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/wallet_controller.dart';
import '../../controllers/submission_history_controller.dart';
import '../../core/theme.dart';
import '../../models/wallet_model.dart';
import '../shared/action_card.dart';
import '../shared/app_shell.dart';

/// The home screen: who you are, what you have, and what you can do.
///
/// Every tappable row is an [ActionCard]. This screen previously wrote all eight
/// of them out by hand — about 300 lines of identical nesting that had already
/// drifted apart (a doubled spacer between two, a missing one between another
/// pair, and the disabled-state chevron handled differently in each).
class HomeView extends ConsumerWidget {
  const HomeView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userAsync = ref.watch(currentUserProvider);
    final walletAsync = ref.watch(walletProvider);
    final pendingCount = ref.watch(pendingSubmissionCountProvider);

    return AppShell(
      title: 'Chokro',
      child: userAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _HomeError(
          onRetry: () => ref.invalidate(currentUserProvider),
        ),
        data: (user) {
          if (user == null) {
            return const Center(child: CircularProgressIndicator());
          }

          final suspended = !user.isActive;

          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(walletProvider);
              ref.invalidate(submissionHistoryProvider);
            },
            child: ListView(
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
                        _Greeting(name: user.name, role: user.role),

                        if (suspended) ...[
                          const SizedBox(height: AppTheme.gapMd),
                          _SuspendedNotice(
                            until: user.suspendedUntil,
                            indefinite: user.isSuspendedIndefinitely,
                          ),
                        ],

                        const SizedBox(height: AppTheme.gapMd),
                        _BalanceCard(walletAsync: walletAsync),

                        const SizedBox(height: AppTheme.gapLg),
                        const SectionHeading('Earn points'),

                        ActionCard(
                          icon: Icons.qr_code_scanner,
                          title: 'Dispose waste',
                          subtitle: 'Scan the code on a bin to start.',
                          disabledSubtitle: 'Unavailable while suspended.',
                          tone: ActionTone.primary,
                          // Disabled for a suspended account. The Firestore
                          // rules refuse the submission anyway (`isActive()` on
                          // disposal create), so this is courtesy rather than
                          // enforcement — it stops a user walking to a bin and
                          // photographing a bag before finding out.
                          onTap: suspended
                              ? null
                              : () => context.push('/dispose/scan'),
                        ),
                        const SizedBox(height: AppTheme.gapSm),
                        ActionCard(
                          icon: Icons.eco_outlined,
                          title: 'Log an eco-action',
                          subtitle: 'Composting, tree planting and similar. '
                              'Checked by a reviewer.',
                          disabledSubtitle: 'Unavailable while suspended.',
                          onTap: suspended
                              ? null
                              : () => context.push('/claims/new'),
                        ),

                        const SizedBox(height: AppTheme.gapLg),
                        const SectionHeading('Your records'),

                        // Shown to every account, including a suspended one: a
                        // user who cannot submit can still need to read why an
                        // earlier submission was rejected.
                        ActionCard(
                          icon: Icons.receipt_long_outlined,
                          title: 'My submissions',
                          subtitle: switch (pendingCount) {
                            0 => 'Status, reason and points for everything you '
                                'have sent.',
                            1 => '1 submission is waiting for review.',
                            _ => '$pendingCount submissions are waiting for '
                                'review.',
                          },
                          badgeCount: pendingCount,
                          onTap: () => context.push('/history'),
                        ),
                        const SizedBox(height: AppTheme.gapSm),
                        ActionCard(
                          icon: Icons.account_balance_wallet_outlined,
                          title: 'Wallet',
                          subtitle: 'Every point earned and spent, with what '
                              'caused it.',
                          onTap: () => context.push('/wallet'),
                        ),

                        if (user.isAdmin) ...[
                          const SizedBox(height: AppTheme.gapLg),
                          const SectionHeading(
                            'Administration',
                            icon: Icons.shield_outlined,
                          ),
                          ActionCard(
                            icon: Icons.fact_check_outlined,
                            title: 'Disposal review queue',
                            subtitle: 'Approve or reject pending disposals.',
                            tone: ActionTone.admin,
                            onTap: () => context.push('/admin/disposals'),
                          ),
                          const SizedBox(height: AppTheme.gapSm),
                          ActionCard(
                            icon: Icons.eco_outlined,
                            title: 'Claim review',
                            subtitle: 'Self-reported eco-actions awaiting a '
                                'decision.',
                            tone: ActionTone.admin,
                            onTap: () => context.push('/admin/claims'),
                          ),
                          const SizedBox(height: AppTheme.gapSm),
                          ActionCard(
                            icon: Icons.storefront_outlined,
                            title: 'Seller applications',
                            subtitle: 'Approve or reject requests to sell.',
                            tone: ActionTone.admin,
                            onTap: () => context.push('/admin/applications'),
                          ),
                          const SizedBox(height: AppTheme.gapSm),
                          ActionCard(
                            icon: Icons.qr_code_2,
                            title: 'Bins',
                            subtitle: 'Register a bin and print its code.',
                            tone: ActionTone.admin,
                            onTap: () => context.push('/admin/bins'),
                          ),
                          const SizedBox(height: AppTheme.gapSm),
                          ActionCard(
                            icon: Icons.people_outline,
                            title: 'Accounts',
                            subtitle: 'Suspend or reinstate an account.',
                            tone: ActionTone.admin,
                            onTap: () => context.push('/admin/users'),
                          ),
                          const SizedBox(height: AppTheme.gapSm),
                          ActionCard(
                            icon: Icons.tune,
                            title: 'Points policy',
                            subtitle: 'Tune awards, redemption and the '
                                'anti-farming limits.',
                            tone: ActionTone.admin,
                            onTap: () => context.push('/admin/points'),
                          ),
                        ],

                        // The seller route was only ever reachable from the
                        // bottom navigation bar, which meant a user who never
                        // looked there did not know it existed.
                        if (!user.isSeller) ...[
                          const SizedBox(height: AppTheme.gapLg),
                          const SectionHeading('Selling'),
                          ActionCard(
                            icon: Icons.storefront_outlined,
                            title: 'Become a seller',
                            subtitle: 'Apply to list what you make. Reviewed by '
                                'an administrator.',
                            disabledSubtitle: 'Unavailable while suspended.',
                            onTap: suspended
                                ? null
                                : () => context.push('/apply-seller'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Greeting extends StatelessWidget {
  const _Greeting({required this.name, required this.role});

  final String name;
  final String role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Expanded(
          child: Text(
            'Hello, $name',
            style: theme.textTheme.headlineSmall
                ?.copyWith(fontWeight: FontWeight.bold),
            // A long name used to push the role chip off the row and overflow.
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: AppTheme.gapSm),
        Chip(
          label: Text(role.toUpperCase()),
          labelStyle: theme.textTheme.labelSmall
              ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: 0.5),
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
        ),
      ],
    );
  }
}

/// The points balance.
///
/// Reads `wallets/{uid}`, which the client can only read — every mutation goes
/// through the trusted server.
class _BalanceCard extends StatelessWidget {
  const _BalanceCard({required this.walletAsync});

  final AsyncValue<WalletModel?> walletAsync;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(AppTheme.gapLg),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'POINTS BALANCE',
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(height: AppTheme.gapSm),
          walletAsync.when(
            loading: () => SizedBox(
              height: 44,
              child: Align(
                alignment: Alignment.centerLeft,
                child: SizedBox(
                  height: 22,
                  width: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
            // The raw exception used to be printed here. It says nothing to a
            // user and it is not their problem to diagnose.
            error: (_, _) => SizedBox(
              height: 44,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Balance unavailable',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
            ),
            data: (wallet) => Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  '${wallet?.balance ?? 0}',
                  style: theme.textTheme.displaySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: AppTheme.gapSm),
                Text(
                  'points',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onPrimaryContainer.withValues(alpha: 0.85),
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

/// Says what a suspension means and, when it is temporary, when it lifts.
///
/// The old notice said only "This account is suspended. Most actions are
/// unavailable." — with no end date even though `suspendedUntil` was right there
/// on the model, so a user serving a three-day suspension had no way to learn it
/// was three days.
class _SuspendedNotice extends StatelessWidget {
  const _SuspendedNotice({required this.until, required this.indefinite});

  final DateTime? until;
  final bool indefinite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final detail = indefinite || until == null
        ? 'Submitting and claiming are unavailable. Contact an administrator.'
        : 'Submitting and claiming are unavailable until '
            '${_date(until!)}. You can still read your history.';

    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.pause_circle_outline, color: scheme.onErrorContainer),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Account suspended',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    detail,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onErrorContainer),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _date(DateTime value) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final local = value.toLocal();
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }
}

class _HomeError extends StatelessWidget {
  const _HomeError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 40, color: theme.colorScheme.error),
            const SizedBox(height: AppTheme.gapMd),
            Text('Your profile did not load',
                style: theme.textTheme.titleMedium),
            const SizedBox(height: AppTheme.gapSm),
            Text(
              'Check your connection and try again.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: AppTheme.gapMd),
            FilledButton.tonal(onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}
