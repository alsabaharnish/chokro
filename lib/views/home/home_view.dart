import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../controllers/account_profile_controller.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/wallet_controller.dart';
import '../../controllers/orders_controller.dart';
import '../../controllers/submission_history_controller.dart';
import '../../core/account_profile.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../models/wallet_model.dart';
import '../shared/account_profile_switcher.dart';
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
    final activeProfile = ref.watch(activeAccountProfileProvider);

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
                        _Greeting(name: user.name, role: activeProfile.label),

                        if (suspended) ...[
                          const SizedBox(height: AppTheme.gapMd),
                          _SuspendedNotice(
                            until: user.suspendedUntil,
                            indefinite: user.isSuspendedIndefinitely,
                          ),
                        ],

                        const SizedBox(height: AppTheme.gapMd),
                        const AccountProfileSwitcher(),

                        ...switch (activeProfile) {
                          AccountProfile.admin => <Widget>[
                            const SizedBox(height: AppTheme.gapXl),
                            const SectionHeading(
                              '3ZERO administration',
                              icon: Icons.shield_outlined,
                            ),
                            _ActionGrid(
                              children: [
                                ActionCard(
                                  icon: Icons.insights_outlined,
                                  title: 'Platform dashboard',
                                  subtitle:
                                      'See points, activity and account totals.',
                                  disabledSubtitle:
                                      'Unavailable while suspended.',
                                  tone: ActionTone.admin,
                                  onTap: suspended
                                      ? null
                                      : () => context.push('/admin/dashboard'),
                                ),
                                ActionCard(
                                  icon: Icons.fact_check_outlined,
                                  title: 'Disposal reviews',
                                  subtitle:
                                      'Approve or reject pending disposals.',
                                  disabledSubtitle:
                                      'Unavailable while suspended.',
                                  tone: ActionTone.admin,
                                  onTap: suspended
                                      ? null
                                      : () => context.push('/admin/disposals'),
                                ),
                                ActionCard(
                                  icon: Icons.eco_outlined,
                                  title: 'Eco-action reviews',
                                  subtitle:
                                      'Decide self-reported green actions.',
                                  disabledSubtitle:
                                      'Unavailable while suspended.',
                                  tone: ActionTone.admin,
                                  onTap: suspended
                                      ? null
                                      : () => context.push('/admin/claims'),
                                ),
                                ActionCard(
                                  icon: Icons.gavel_outlined,
                                  title: 'Appeals',
                                  subtitle:
                                      'Answer Champions who dispute a decision.',
                                  disabledSubtitle:
                                      'Unavailable while suspended.',
                                  tone: ActionTone.admin,
                                  onTap: suspended
                                      ? null
                                      : () => context.push('/admin/appeals'),
                                ),
                                ActionCard(
                                  icon: Icons.storefront_outlined,
                                  title: 'Greenpreneur applications',
                                  subtitle:
                                      'Review Champion requests to start selling.',
                                  disabledSubtitle:
                                      'Unavailable while suspended.',
                                  tone: ActionTone.admin,
                                  onTap: suspended
                                      ? null
                                      : () =>
                                            context.push('/admin/applications'),
                                ),
                                ActionCard(
                                  icon: Icons.qr_code_2,
                                  title: 'Collection bins',
                                  subtitle:
                                      'Register bins and print their codes.',
                                  disabledSubtitle:
                                      'Unavailable while suspended.',
                                  tone: ActionTone.admin,
                                  onTap: suspended
                                      ? null
                                      : () => context.push('/admin/bins'),
                                ),
                                ActionCard(
                                  icon: Icons.people_outline,
                                  title: 'Accounts',
                                  subtitle:
                                      'View, suspend or reinstate an account.',
                                  disabledSubtitle:
                                      'Unavailable while suspended.',
                                  tone: ActionTone.admin,
                                  onTap: suspended
                                      ? null
                                      : () => context.push('/admin/users'),
                                ),
                                ActionCard(
                                  icon: Icons.tune,
                                  title: 'Points policy',
                                  subtitle:
                                      'Tune rewards and anti-farming limits.',
                                  disabledSubtitle:
                                      'Unavailable while suspended.',
                                  tone: ActionTone.admin,
                                  onTap: suspended
                                      ? null
                                      : () => context.push('/admin/points'),
                                ),
                              ],
                            ),
                          ],
                          AccountProfile.greenpreneur => <Widget>[
                            const SizedBox(height: AppTheme.gapXl),
                            const SectionHeading('Greenpreneur workspace'),
                            _ActionGrid(
                              children: [
                                ActionCard(
                                  icon: Icons.inventory_2_outlined,
                                  title: 'My sustainable listings',
                                  subtitle:
                                      'Add products, update stock and manage visibility.',
                                  disabledSubtitle:
                                      'Unavailable while suspended.',
                                  tone: ActionTone.primary,
                                  onTap: suspended
                                      ? null
                                      : () => context.push('/seller/products'),
                                ),
                                ActionCard(
                                  icon: Icons.local_shipping_outlined,
                                  title: 'Orders to fulfil',
                                  subtitle: switch (openSellerOrders) {
                                    0 =>
                                      'Ship and deliver what Champions have ordered.',
                                    1 => '1 order needs something from you.',
                                    _ =>
                                      '$openSellerOrders orders need something from you.',
                                  },
                                  badgeCount: openSellerOrders,
                                  disabledSubtitle:
                                      'Unavailable while suspended.',
                                  onTap: suspended
                                      ? null
                                      : () => context.push('/seller/orders'),
                                ),
                                ActionCard(
                                  icon: Icons.eco_outlined,
                                  title: 'Use my Champion profile',
                                  subtitle:
                                      'Shop, take green actions and manage your points.',
                                  onTap: () => ref
                                      .read(
                                        accountProfileControllerProvider
                                            .notifier,
                                      )
                                      .select(AccountProfile.champion),
                                ),
                              ],
                            ),
                          ],
                          AccountProfile.champion => <Widget>[
                            const SizedBox(height: AppTheme.gapMd),
                            _BalanceCard(
                              walletAsync: walletAsync,
                              onViewWallet: () => context.push('/wallet'),
                            ),
                            const SizedBox(height: AppTheme.gapXl),
                            const SectionHeading('Make an impact'),
                            _ActionGrid(
                              children: [
                                ActionCard(
                                  icon: Icons.qr_code_scanner,
                                  title: 'Dispose waste',
                                  subtitle: 'Scan the code on a bin to start.',
                                  disabledSubtitle:
                                      'Unavailable while suspended.',
                                  tone: ActionTone.primary,
                                  onTap: suspended
                                      ? null
                                      : () => context.push('/dispose/scan'),
                                ),
                                ActionCard(
                                  icon: Icons.eco_outlined,
                                  title: 'Log an eco-action',
                                  subtitle:
                                      'Record composting, planting and other positive actions.',
                                  disabledSubtitle:
                                      'Unavailable while suspended.',
                                  onTap: suspended
                                      ? null
                                      : () => context.push('/claims/new'),
                                ),
                                ActionCard(
                                  icon: Icons.volunteer_activism_outlined,
                                  title: 'Support green initiatives',
                                  subtitle:
                                      'Donate reward points to a 3ZERO initiative.',
                                  disabledSubtitle:
                                      'Unavailable while suspended.',
                                  onTap: suspended
                                      ? null
                                      : () => context.push('/donate'),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppTheme.gapLg),
                            const SectionHeading('Your records'),
                            _ActionGrid(
                              children: [
                                ActionCard(
                                  icon: Icons.receipt_long_outlined,
                                  title: 'My submissions',
                                  subtitle: switch (pendingCount) {
                                    0 =>
                                      'Status, reasons and points for everything you sent.',
                                    1 => '1 submission is waiting for review.',
                                    _ =>
                                      '$pendingCount submissions are waiting for review.',
                                  },
                                  badgeCount: pendingCount,
                                  onTap: () => context.push('/history'),
                                ),
                                ActionCard(
                                  icon: Icons.eco_outlined,
                                  title: 'My eco-actions',
                                  subtitle:
                                      'Review actions, decisions and reasons.',
                                  onTap: () => context.push('/claims'),
                                ),
                                ActionCard(
                                  icon: Icons.local_mall_outlined,
                                  title: 'My orders',
                                  subtitle: switch (awaitingConfirmation) {
                                    0 =>
                                      'Track what you bought and where it has got to.',
                                    1 =>
                                      '1 delivery is waiting for your confirmation.',
                                    _ =>
                                      '$awaitingConfirmation deliveries await confirmation.',
                                  },
                                  badgeCount: awaitingConfirmation,
                                  onTap: () => context.push('/orders'),
                                ),
                                ActionCard(
                                  icon: Icons.gavel_outlined,
                                  title: 'My appeals',
                                  subtitle:
                                      'See disputed decisions and 3ZERO Admin responses.',
                                  onTap: () => context.push('/appeals'),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppTheme.gapLg),
                            const SectionHeading('Greenpreneur journey'),
                            _ActionGrid(
                              children: [
                                if (user.isSeller)
                                  ActionCard(
                                    icon: Icons.storefront_outlined,
                                    title: 'Use my Greenpreneur profile',
                                    subtitle:
                                        'Manage sustainable products and fulfil orders.',
                                    onTap: () => ref
                                        .read(
                                          accountProfileControllerProvider
                                              .notifier,
                                        )
                                        .select(AccountProfile.greenpreneur),
                                  )
                                else
                                  ActionCard(
                                    icon: Icons.storefront_outlined,
                                    title: 'Become a 3ZERO Greenpreneur',
                                    subtitle:
                                        'Learn what Greenpreneurs do and apply when you are ready.',
                                    disabledSubtitle:
                                        'Unavailable while suspended.',
                                    onTap: suspended
                                        ? null
                                        : () => context.push('/apply-seller'),
                                  ),
                              ],
                            ),
                          ],
                        },
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
              label: Text(role),
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
        ? 'Submitting and claiming are unavailable. Contact a 3ZERO Admin.'
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
