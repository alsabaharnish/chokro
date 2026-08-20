import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/wallet_controller.dart';
import '../../controllers/orders_controller.dart';
import '../../controllers/submission_history_controller.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../models/wallet_model.dart';
import '../shared/action_card.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';

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
    final awaitingConfirmation = ref
        .watch(ordersAwaitingConfirmationProvider)
        .length;
    final openSellerOrders = ref.watch(sellerOpenOrdersProvider).length;

    return AppShell(
      title: 'Chokro',
      child: userAsync.when(
        loading: () => const ContentLoading(label: 'Preparing your dashboard…'),
        error: (error, _) =>
            _HomeError(onRetry: () => ref.invalidate(currentUserProvider)),
        data: (user) {
          if (user == null) {
            return const ContentLoading(label: 'Preparing your dashboard…');
          }

          final suspended = !user.isActive;

          return RefreshIndicator(
            onRefresh: () async {
              try {
                await Future.wait<Object?>([
                  ref.refresh(walletProvider.future),
                  ref.refresh(submissionHistoryProvider.future),
                ]);
              } catch (_) {
                // The providers retain the error and the screen renders it.
              }
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
                      maxWidth: AppTheme.maxDashboardWidth,
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
                        _BalanceCard(
                          walletAsync: walletAsync,
                          onViewWallet: () => context.push('/wallet'),
                        ),

                        const SizedBox(height: AppTheme.gapXl),
                        const SectionHeading('Quick actions'),

                        _ActionGrid(
                          children: [
                            ActionCard(
                              icon: Icons.qr_code_scanner,
                              title: 'Dispose waste',
                              subtitle: 'Scan the code on a bin to start.',
                              disabledSubtitle: 'Unavailable while suspended.',
                              tone: ActionTone.primary,
                              // Disabled for a suspended account. The Firestore
                              // rules refuse the submission anyway (`isActive()`
                              // on disposal create), so this is courtesy rather
                              // than enforcement.
                              onTap: suspended
                                  ? null
                                  : () => context.push('/dispose/scan'),
                            ),
                            ActionCard(
                              icon: Icons.eco_outlined,
                              title: 'Log an eco-action',
                              subtitle:
                                  'Record composting, planting and other '
                                  'positive actions.',
                              disabledSubtitle: 'Unavailable while suspended.',
                              onTap: suspended
                                  ? null
                                  : () => context.push('/claims/new'),
                            ),
                          ],
                        ),

                        const SizedBox(height: AppTheme.gapLg),
                        const SectionHeading('Your records'),

                        // Shown to every account, including a suspended one: a
                        // user who cannot submit can still need to read why an
                        // earlier submission was rejected.
                        _ActionGrid(
                          children: [
                            ActionCard(
                              icon: Icons.receipt_long_outlined,
                              title: 'My submissions',
                              subtitle: switch (pendingCount) {
                                0 =>
                                  'Status, reasons and points for everything '
                                      'you have sent.',
                                1 => '1 submission is waiting for review.',
                                _ =>
                                  '$pendingCount submissions are waiting for '
                                      'review.',
                              },
                              badgeCount: pendingCount,
                              onTap: () => context.push('/history'),
                            ),

                            // Kept separate from disposal submissions so the
                            // status of each workflow is easy to scan.
                            ActionCard(
                              icon: Icons.eco_outlined,
                              title: 'My eco-actions',
                              subtitle:
                                  'Review every action, its status and '
                                  'the decision reason.',
                              onTap: () => context.push('/claims'),
                            ),
                            ActionCard(
                              icon: Icons.local_mall_outlined,
                              title: 'My orders',
                              subtitle: switch (awaitingConfirmation) {
                                0 =>
                                  'What you have bought, and where it has got '
                                      'to.',
                                1 =>
                                  '1 delivery is waiting for you to confirm — '
                                      'that is what credits your points.',
                                _ =>
                                  '$awaitingConfirmation deliveries are waiting '
                                      'for you to confirm.',
                              },
                              badgeCount: awaitingConfirmation,
                              onTap: () => context.push('/orders'),
                            ),
                            // Reachable from here as well as from the history
                            // screen, because a user who has appealed something
                            // comes back looking for the answer rather than for
                            // the submission it was about.
                            ActionCard(
                              icon: Icons.gavel_outlined,
                              title: 'My appeals',
                              subtitle:
                                  'Decisions you have disputed, and what an '
                                  'administrator answered.',
                              onTap: () => context.push('/appeals'),
                            ),
                          ],
                        ),

                        if (user.isAdmin && !suspended) ...[
                          const SizedBox(height: AppTheme.gapLg),
                          const SectionHeading(
                            'Administration',
                            icon: Icons.shield_outlined,
                          ),
                          _ActionGrid(
                            children: [
                              ActionCard(
                                icon: Icons.insights_outlined,
                                title: 'Dashboard',
                                subtitle:
                                    'Points issued, redeemed and outstanding, '
                                    'and how the platform is being used.',
                                tone: ActionTone.admin,
                                onTap: () => context.push('/admin/dashboard'),
                              ),
                              ActionCard(
                                icon: Icons.fact_check_outlined,
                                title: 'Disposal reviews',
                                subtitle:
                                    'Approve or reject pending disposals.',
                                tone: ActionTone.admin,
                                onTap: () => context.push('/admin/disposals'),
                              ),
                              ActionCard(
                                icon: Icons.eco_outlined,
                                title: 'Claim reviews',
                                subtitle: 'Decide self-reported eco-actions.',
                                tone: ActionTone.admin,
                                onTap: () => context.push('/admin/claims'),
                              ),
                              ActionCard(
                                icon: Icons.gavel_outlined,
                                title: 'Appeals',
                                subtitle:
                                    'Answer users who dispute a rejection.',
                                tone: ActionTone.admin,
                                onTap: () => context.push('/admin/appeals'),
                              ),
                              ActionCard(
                                icon: Icons.storefront_outlined,
                                title: 'Seller applications',
                                subtitle: 'Review requests to become a seller.',
                                tone: ActionTone.admin,
                                onTap: () =>
                                    context.push('/admin/applications'),
                              ),
                              ActionCard(
                                icon: Icons.qr_code_2,
                                title: 'Bins',
                                subtitle:
                                    'Register bins and print their codes.',
                                tone: ActionTone.admin,
                                onTap: () => context.push('/admin/bins'),
                              ),
                              ActionCard(
                                icon: Icons.people_outline,
                                title: 'Accounts',
                                subtitle: 'Suspend or reinstate an account.',
                                tone: ActionTone.admin,
                                onTap: () => context.push('/admin/users'),
                              ),
                              ActionCard(
                                icon: Icons.tune,
                                title: 'Points policy',
                                subtitle:
                                    'Tune rewards and anti-farming limits.',
                                tone: ActionTone.admin,
                                onTap: () => context.push('/admin/points'),
                              ),
                            ],
                          ),
                        ],

                        // The seller route was only ever reachable from the
                        // bottom navigation bar, which meant a user who never
                        // looked there did not know it existed.
                        const SizedBox(height: AppTheme.gapLg),
                        const SectionHeading('Selling'),
                        _ActionGrid(
                          children: [
                            if (user.isSeller) ...[
                              ActionCard(
                                icon: Icons.inventory_2_outlined,
                                title: 'My listings',
                                subtitle:
                                    'Add, edit and take products off the shop.',
                                disabledSubtitle:
                                    'Unavailable while suspended.',
                                onTap: suspended
                                    ? null
                                    : () => context.push('/seller/products'),
                              ),
                              ActionCard(
                                icon: Icons.local_shipping_outlined,
                                title: 'Orders to fulfil',
                                subtitle: switch (openSellerOrders) {
                                  0 =>
                                    'Ship and deliver what buyers have '
                                        'ordered.',
                                  1 => '1 order needs something from you.',
                                  _ =>
                                    '$openSellerOrders orders need something '
                                        'from you.',
                                },
                                badgeCount: openSellerOrders,
                                disabledSubtitle:
                                    'Unavailable while suspended.',
                                onTap: suspended
                                    ? null
                                    : () => context.push('/seller/orders'),
                              ),
                            ] else
                              ActionCard(
                                icon: Icons.storefront_outlined,
                                title: 'Become a seller',
                                subtitle:
                                    'Apply to list what you make. Every '
                                    'request is reviewed.',
                                disabledSubtitle:
                                    'Unavailable while suspended.',
                                onTap: suspended
                                    ? null
                                    : () => context.push('/apply-seller'),
                              ),
                          ],
                        ),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text(
                'Hello, $name',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -.65,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: AppTheme.gapSm),
            Chip(
              avatar: const Icon(Icons.verified_user_outlined, size: 16),
              label: Text(role.toUpperCase()),
              labelStyle: theme.textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: 0.5,
              ),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          ],
        ),
        const SizedBox(height: AppTheme.gapXs),
        Text(
          'Here is your impact at a glance.',
          style: theme.textTheme.bodyLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
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
  const _BalanceCard({required this.walletAsync, required this.onViewWallet});

  final AsyncValue<WalletModel?> walletAsync;
  final VoidCallback onViewWallet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final foreground = scheme.onPrimary;

    return ClipRRect(
      borderRadius: BorderRadius.circular(AppTheme.radiusLg),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primary,
              Color.lerp(scheme.primary, scheme.tertiary, .68)!,
            ],
          ),
        ),
        child: Stack(
          children: [
            Positioned(
              right: -44,
              top: -70,
              child: Container(
                width: 190,
                height: 190,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: foreground.withValues(alpha: .1),
                    width: 28,
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(AppTheme.gapLg),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final value = _BalanceValue(
                    walletAsync: walletAsync,
                    foreground: foreground,
                  );
                  final button = OutlinedButton.icon(
                    onPressed: onViewWallet,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: foreground,
                      side: BorderSide(color: foreground.withValues(alpha: .4)),
                      backgroundColor: foreground.withValues(alpha: .08),
                    ),
                    icon: const Icon(Icons.arrow_forward, size: 18),
                    label: const Text('View wallet'),
                  );

                  if (constraints.maxWidth < 440) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        value,
                        const SizedBox(height: AppTheme.gapMd),
                        button,
                      ],
                    );
                  }

                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(child: value),
                      const SizedBox(width: AppTheme.gapMd),
                      button,
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BalanceValue extends StatelessWidget {
  const _BalanceValue({required this.walletAsync, required this.foreground});

  final AsyncValue<WalletModel?> walletAsync;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'POINTS BALANCE',
          style: theme.textTheme.labelSmall?.copyWith(
            color: foreground.withValues(alpha: .8),
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
        ),
        const SizedBox(height: AppTheme.gapSm),
        walletAsync.when(
          loading: () => SizedBox(
            height: 52,
            child: Align(
              alignment: Alignment.centerLeft,
              child: SizedBox(
                height: 24,
                width: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: foreground,
                ),
              ),
            ),
          ),
          error: (_, _) => SizedBox(
            height: 52,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Balance unavailable',
                style: theme.textTheme.titleMedium?.copyWith(color: foreground),
              ),
            ),
          ),
          data: (wallet) => Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  '${wallet?.balance ?? 0}',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.displayMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.5,
                    color: foreground,
                  ),
                ),
              ),
              const SizedBox(width: AppTheme.gapSm),
              Text(
                'points',
                style: theme.textTheme.titleMedium?.copyWith(
                  color: foreground.withValues(alpha: .82),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// One column on phones, two on tablets and desktop. The fixed maximum keeps
/// each card readable while making useful use of a wide browser window.
class _ActionGrid extends StatelessWidget {
  const _ActionGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 700 ? 2 : 1;
        final width = columns == 1
            ? constraints.maxWidth
            : (constraints.maxWidth - AppTheme.gapMd) / 2;

        return Wrap(
          spacing: AppTheme.gapMd,
          runSpacing: AppTheme.gapMd,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
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
              '${formatDate(until)}. You can still read your history.';

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
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
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
            Icon(
              Icons.cloud_off_outlined,
              size: 40,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: AppTheme.gapMd),
            Text(
              'Your profile did not load',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: AppTheme.gapSm),
            Text(
              'Check your connection and try again.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppTheme.gapMd),
            FilledButton.tonal(
              onPressed: onRetry,
              child: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }
}
