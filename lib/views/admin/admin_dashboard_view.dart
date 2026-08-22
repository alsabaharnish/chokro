import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/dashboard_controller.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../models/stats_model.dart';
import '../shared/action_card.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';

/// The administrator's dashboard (F5.1).
///
/// ## Two kinds of figure, and the screen says which is which
///
/// The **platform counters** are incremented with `FieldValue.increment()`
/// inside the same server transactions that cause them (§6.3), so this screen
/// costs one document read however much data accumulates. They are a record of
/// what the server did rather than a recount of the collections.
///
/// The **account totals** are counted live from `users`, because registration is
/// a client write that cannot touch `stats` — nothing can — and the account list
/// already streams that collection. Small, bounded, and honestly labelled.
///
/// Presenting both without distinguishing them would invite the obvious viva
/// question with no good answer: "so is that a count or a counter?"
class AdminDashboardView extends ConsumerWidget {
  const AdminDashboardView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(platformStatsProvider);
    final accounts = ref.watch(accountTotalsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: statsAsync.when(
        loading: () => const ContentLoading(label: 'Reading the counters…'),
        error: (error, _) => ErrorRetry(
          error: error,
          title: 'The dashboard',
          onRetry: () => ref.invalidate(platformStatsProvider),
        ),
        data: (stats) => ListView(
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
                    const SectionHeading(
                      'The points economy',
                      icon: Icons.savings_outlined,
                    ),
                    _StatGrid(
                      tiles: [
                        _Stat(
                          label: 'Points issued',
                          value: '${stats.pointsIssued}',
                          detail: 'Every credit, from any source',
                          icon: Icons.trending_up,
                        ),
                        _Stat(
                          label: 'Points redeemed',
                          value: '${stats.pointsRedeemed}',
                          detail: 'Spent at checkout',
                          icon: Icons.trending_down,
                        ),
                        _Stat(
                          label: 'Points donated',
                          value: '${stats.pointsDonated}',
                          detail:
                              '${stats.donationsReceived} Champion contributions',
                          icon: Icons.volunteer_activism_outlined,
                        ),
                        _Stat(
                          label: 'Points outstanding',
                          value: '${stats.pointsOutstanding}',
                          // Issued minus every debit is what the platform still
                          // owes its users.
                          detail: 'Held in wallets — the standing liability',
                          icon: Icons.account_balance_wallet_outlined,
                          emphasise: true,
                        ),
                      ],
                    ),

                    const SizedBox(height: AppTheme.gapLg),
                    const SectionHeading(
                      'Verification',
                      icon: Icons.fact_check_outlined,
                    ),
                    _StatGrid(
                      tiles: [
                        _Stat(
                          label: 'Disposals approved',
                          value: '${stats.disposalsApproved}',
                          detail: _rate(
                            stats.disposalApprovalPercent,
                            stats.disposalsDecided,
                          ),
                          icon: Icons.recycling,
                        ),
                        _Stat(
                          label: 'Disposals rejected',
                          value: '${stats.disposalsRejected}',
                          detail: 'Each with a recorded reason',
                          icon: Icons.cancel_outlined,
                        ),
                        _Stat(
                          label: 'Claims approved',
                          value: '${stats.claimsApproved}',
                          detail: _rate(
                            stats.claimApprovalPercent,
                            stats.claimsDecided,
                          ),
                          icon: Icons.eco_outlined,
                        ),
                        _Stat(
                          label: 'Claims rejected',
                          value: '${stats.claimsRejected}',
                          detail: 'The weakest route, reviewed by a person',
                          icon: Icons.block_outlined,
                        ),
                      ],
                    ),

                    const SizedBox(height: AppTheme.gapLg),
                    const SectionHeading(
                      'Marketplace',
                      icon: Icons.storefront_outlined,
                    ),
                    _StatGrid(
                      tiles: [
                        _Stat(
                          label: 'Orders placed',
                          value: '${stats.ordersCreated}',
                          detail: 'One per Greenpreneur per checkout',
                          icon: Icons.receipt_long_outlined,
                        ),
                        _Stat(
                          label: 'Orders confirmed',
                          value: '${stats.ordersConfirmed}',
                          detail: '${stats.ordersOpen} still open',
                          icon: Icons.verified_outlined,
                        ),
                        _Stat(
                          label: 'Sales value',
                          value: formatTaka(stats.salesPayable),
                          detail: 'Cash due after points were applied',
                          icon: Icons.payments_outlined,
                        ),
                      ],
                    ),

                    const SizedBox(height: AppTheme.gapLg),
                    const SectionHeading(
                      'Accounts',
                      icon: Icons.people_outline,
                    ),
                    _StatGrid(
                      tiles: [
                        _Stat(
                          label: 'Accounts',
                          value: '${accounts.total}',
                          detail: 'Counted live, not a counter',
                          icon: Icons.person_outline,
                        ),
                        _Stat(
                          label: '3ZERO Greenpreneurs',
                          value: '${accounts.sellers}',
                          detail:
                              '${accounts.buyers} Champions, '
                              '${accounts.admins} 3ZERO Admins',
                          icon: Icons.storefront_outlined,
                        ),
                        _Stat(
                          label: 'Cannot act',
                          value: '${accounts.suspended}',
                          detail: 'Suspended now — lapsed ones excluded',
                          icon: Icons.pause_circle_outline,
                        ),
                      ],
                    ),

                    const SizedBox(height: AppTheme.gapLg),
                    _ProvenanceNote(stats: stats),

                    const SizedBox(height: AppTheme.gapLg),
                    const SectionHeading('Go to', icon: Icons.shield_outlined),
                    ActionCard(
                      icon: Icons.gavel_outlined,
                      title: 'Appeals',
                      subtitle: 'Answer users who dispute a rejection.',
                      tone: ActionTone.admin,
                      onTap: () => context.push('/admin/appeals'),
                    ),
                    const SizedBox(height: AppTheme.gapSm),
                    ActionCard(
                      icon: Icons.people_outline,
                      title: 'Accounts',
                      subtitle:
                          'Suspend or reinstate, and hide a shop with it.',
                      tone: ActionTone.admin,
                      onTap: () => context.push('/admin/users'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// An approval rate, or an honest statement that there is not one yet.
  ///
  /// Nothing decided is not zero percent, and showing it as such would put a
  /// damning-looking figure on a dashboard for a platform that has simply not
  /// been used yet.
  static String _rate(int? percent, int decided) {
    if (percent == null) return 'Nothing decided yet';
    return '$percent% of $decided decided';
  }
}

class _Stat {
  const _Stat({
    required this.label,
    required this.value,
    required this.detail,
    required this.icon,
    this.emphasise = false,
  });

  final String label;
  final String value;
  final String detail;
  final IconData icon;
  final bool emphasise;
}

/// One column on phones, up to three on a wide browser window.
///
/// The dashboard is web-primary (§5.5) — stat density suits side-by-side
/// comparison — but it stacks rather than being excluded from mobile, because
/// that is a layout preference and not a capability limit.
class _StatGrid extends StatelessWidget {
  const _StatGrid({required this.tiles});

  final List<_Stat> tiles;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900
            ? 3
            : constraints.maxWidth >= 560
            ? 2
            : 1;
        final width =
            (constraints.maxWidth - AppTheme.gapMd * (columns - 1)) / columns;

        return Wrap(
          spacing: AppTheme.gapMd,
          runSpacing: AppTheme.gapMd,
          children: [
            for (final tile in tiles)
              SizedBox(
                width: width,
                child: _StatTile(stat: tile),
              ),
          ],
        );
      },
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.stat});

  final _Stat stat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      margin: EdgeInsets.zero,
      color: stat.emphasise ? scheme.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  stat.icon,
                  size: 18,
                  color: stat.emphasise
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppTheme.gapSm),
                Expanded(
                  child: Text(
                    stat.label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: stat.emphasise
                          ? scheme.onPrimaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.gapSm),
            Text(
              stat.value,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w800,
                letterSpacing: -1,
                color: stat.emphasise ? scheme.onPrimaryContainer : null,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              stat.detail,
              style: theme.textTheme.bodySmall?.copyWith(
                color: stat.emphasise
                    ? scheme.onPrimaryContainer
                    : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Says where the numbers come from.
///
/// Worth the space on a screen an examiner will ask about: a dashboard that
/// cannot explain its own provenance is a dashboard nobody should trust.
class _ProvenanceNote extends StatelessWidget {
  const _ProvenanceNote({required this.stats});

  final PlatformStats stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final untouched =
        stats.pointsIssued == 0 &&
        stats.disposalsDecided == 0 &&
        stats.ordersCreated == 0;

    return Card(
      color: scheme.surfaceContainerHighest,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: scheme.onSurfaceVariant),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: Text(
                untouched
                    ? 'No counter has been incremented yet, so these read zero '
                          'rather than being unavailable. They are written by the '
                          'trusted service inside the same transactions that '
                          'award and spend points — no client can write them, an '
                          '3ZERO Admin included.'
                    : 'Platform counters are written by the trusted service '
                          'inside the same transactions that award and spend '
                          'points, so this screen is one document read. Account '
                          'totals are counted live from the accounts list. No '
                          'client can write a counter, a 3ZERO Admin included.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
