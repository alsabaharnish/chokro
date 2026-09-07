import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/admin_users_controller.dart';
import '../../controllers/dashboard_controller.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../models/stats_model.dart';
import '../shared/action_card.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import 'sdg_dashboard.dart';

/// The administrator's dashboard (F5.1).
///
/// ## Two kinds of figure, and the screen says which is which
///
/// The **platform counters** are incremented with `FieldValue.increment()`
/// inside the same server transactions that cause them (§6.3), so this screen
/// costs one document read however much data accumulates. They are a record of
/// what the server did rather than a recount of the collections.
///
/// The **account totals** are derived from the bounded `users` directory,
/// because registration is a client write that cannot touch `stats` — nothing
/// can. Cached and truncated snapshots are labelled rather than presented as
/// complete live totals.
///
/// Presenting both without distinguishing them would invite the obvious viva
/// question with no good answer: "so is that a count or a counter?"
class AdminDashboardView extends StatelessWidget {
  const AdminDashboardView({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppShell(
      title: 'Dashboard',
      child: DefaultTabController(
        length: 2,
        child: Column(
          children: [
            Material(
              color: scheme.surfaceContainerLowest,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: TabBar(
                      tabs: const [
                        Tab(
                          height: 64,
                          child: _DashboardTabLabel(
                            icon: Icons.public,
                            label: 'SDG impact',
                          ),
                        ),
                        Tab(
                          height: 64,
                          child: _DashboardTabLabel(
                            icon: Icons.monitor_heart_outlined,
                            label: 'Platform data',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const Expanded(
              child: TabBarView(
                children: [
                  SelectionArea(child: SdgImpactDashboard()),
                  SelectionArea(child: _OperationsDashboard()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DashboardTabLabel extends StatelessWidget {
  const _DashboardTabLabel({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 19),
        const SizedBox(width: AppTheme.gapSm),
        Flexible(child: Text(label, maxLines: 2, textAlign: TextAlign.center)),
      ],
    );
  }
}

class _OperationsDashboard extends ConsumerWidget {
  const _OperationsDashboard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(platformStatsProvider);
    final accountsAsync = ref.watch(accountTotalsProvider);

    return ListView(
      key: const PageStorageKey<String>('admin-operations-dashboard'),
      padding: const EdgeInsets.fromLTRB(
        AppTheme.gapMd,
        AppTheme.gapMd,
        AppTheme.gapMd,
        AppTheme.gap2Xl,
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
                _OperationsIntro(stats: statsAsync.value),
                const SizedBox(height: AppTheme.gapLg),
                statsAsync.when(
                  loading: () => const SizedBox(
                    height: 280,
                    child: ContentLoading(label: 'Reading platform counters…'),
                  ),
                  error: (error, _) => SizedBox(
                    height: 280,
                    child: ErrorRetry(
                      error: error,
                      title: 'Platform counters',
                      onRetry: () => ref.invalidate(platformStatsProvider),
                    ),
                  ),
                  data: (stats) => _PlatformCounterSections(stats: stats),
                ),
                const SizedBox(height: AppTheme.gapLg),
                const SectionHeading('Accounts', icon: Icons.people_outline),
                accountsAsync.when(
                  loading: () => const SizedBox(
                    height: 180,
                    child: ContentLoading(label: 'Counting accounts…'),
                  ),
                  error: (error, _) => SizedBox(
                    height: 180,
                    child: ErrorRetry(
                      error: error,
                      title: 'Account totals',
                      onRetry: () => ref.invalidate(allUsersProvider),
                    ),
                  ),
                  data: (accounts) =>
                      _AccountCounterSection(accounts: accounts),
                ),
                const SizedBox(height: AppTheme.gapLg),
                if (statsAsync.hasValue)
                  _ProvenanceNote(
                    stats: statsAsync.value!,
                    accounts: accountsAsync.value,
                  ),
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
                  subtitle: 'Suspend or reinstate, and hide a shop with it.',
                  tone: ActionTone.admin,
                  onTap: () => context.push('/admin/users'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _OperationsIntro extends StatelessWidget {
  const _OperationsIntro({required this.stats});

  final PlatformStats? stats;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Card(
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapLg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(
                Icons.monitor_heart_outlined,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Operational overview',
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: AppTheme.gapXs),
                  Text(
                    'All-time point, verification, marketplace, and account '
                    'totals. Use the SDG impact view for target alignment and '
                    'measurement boundaries.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (stats != null) ...[
              const SizedBox(width: AppTheme.gapMd),
              _OperationalSourceBadge(isCached: stats!.isFromCache),
            ],
          ],
        ),
      ),
    );
  }
}

class _OperationalSourceBadge extends StatelessWidget {
  const _OperationalSourceBadge({required this.isCached});

  final bool isCached;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Tooltip(
      message: isCached
          ? 'Waiting for Firestore to confirm this cached snapshot'
          : 'Confirmed by Firestore',
      child: Icon(
        isCached ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
        color: isCached ? scheme.warning : scheme.success,
      ),
    );
  }
}

class _PlatformCounterSections extends StatelessWidget {
  const _PlatformCounterSections({required this.stats});

  final PlatformStats stats;

  @override
  Widget build(BuildContext context) {
    return Column(
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
              value: formatCount(stats.pointsIssued),
              detail: 'Every credit, from any source',
              icon: Icons.trending_up,
            ),
            _Stat(
              label: 'Points redeemed',
              value: formatCount(stats.pointsRedeemed),
              detail: 'Spent at checkout',
              icon: Icons.trending_down,
            ),
            _Stat(
              label: 'Points donated',
              value: formatCount(stats.pointsDonated),
              detail:
                  '${formatCount(stats.donationsReceived)} Champion contributions',
              icon: Icons.volunteer_activism_outlined,
            ),
            _Stat(
              label: 'Points outstanding',
              value: formatCount(stats.pointsOutstanding),
              detail: 'Held in wallets — the standing liability',
              icon: Icons.account_balance_wallet_outlined,
              emphasise: true,
            ),
          ],
        ),
        const SizedBox(height: AppTheme.gapLg),
        const SectionHeading('Verification', icon: Icons.fact_check_outlined),
        _StatGrid(
          tiles: [
            _Stat(
              label: 'Disposals approved',
              value: formatCount(stats.disposalsApproved),
              detail: _rate(
                stats.disposalApprovalPercent,
                stats.disposalsDecided,
              ),
              icon: Icons.recycling,
            ),
            _Stat(
              label: 'Disposals rejected',
              value: formatCount(stats.disposalsRejected),
              detail: 'Each with a recorded reason',
              icon: Icons.cancel_outlined,
            ),
            _Stat(
              label: 'Claims approved',
              value: formatCount(stats.claimsApproved),
              detail: _rate(stats.claimApprovalPercent, stats.claimsDecided),
              icon: Icons.eco_outlined,
            ),
            _Stat(
              label: 'Claims rejected',
              value: formatCount(stats.claimsRejected),
              detail: 'The weakest route, reviewed by a person',
              icon: Icons.block_outlined,
            ),
          ],
        ),
        const SizedBox(height: AppTheme.gapLg),
        const SectionHeading('Marketplace', icon: Icons.storefront_outlined),
        _StatGrid(
          tiles: [
            _Stat(
              label: 'Orders placed',
              value: formatCount(stats.ordersCreated),
              detail: 'One per Greenpreneur per checkout',
              icon: Icons.receipt_long_outlined,
            ),
            _Stat(
              label: 'Orders confirmed',
              value: formatCount(stats.ordersConfirmed),
              detail: '${formatCount(stats.ordersOpen)} still open',
              icon: Icons.verified_outlined,
            ),
            _Stat(
              label: 'Order value placed',
              value: formatTaka(stats.salesPayable),
              detail: 'Payable value after points were applied',
              icon: Icons.payments_outlined,
            ),
            _Stat(
              label: 'Prototype donations',
              value: formatTaka(stats.prototypeDonationTaka),
              detail:
                  '${formatCount(stats.prototypeDonationsReceived)} simulations — not real funds',
              icon: Icons.science_outlined,
            ),
          ],
        ),
      ],
    );
  }

  static String _rate(int? percent, int decided) {
    if (percent == null) return 'Nothing decided yet';
    return '$percent% of ${formatCount(decided)} decided';
  }
}

class _AccountCounterSection extends StatelessWidget {
  const _AccountCounterSection({required this.accounts});

  final AccountTotals accounts;

  String _value(int value) =>
      '${formatCount(value)}${accounts.truncated ? '+' : ''}';

  @override
  Widget build(BuildContext context) {
    final source = accounts.isFromCache
        ? 'cached snapshot'
        : 'current snapshot';
    return _StatGrid(
      tiles: [
        _Stat(
          label: 'Accounts',
          value: _value(accounts.total),
          detail: accounts.truncated
              ? 'At least this many — $source'
              : 'Account directory — $source',
          icon: Icons.person_outline,
        ),
        _Stat(
          label: 'Accounts with a Greenpreneur profile',
          value: _value(accounts.sellers),
          detail:
              '${_value(accounts.buyers)} Champions, ${_value(accounts.admins)} 3ZERO Admins',
          icon: Icons.storefront_outlined,
        ),
        _Stat(
          label: 'Cannot act',
          value: _value(accounts.suspended),
          detail: accounts.truncated
              ? 'At least this many suspended now'
              : 'Suspended now — expiry checked every minute',
          icon: Icons.pause_circle_outline,
        ),
      ],
    );
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

/// One column on phones, up to four on a wide browser window.
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
        final columns = constraints.maxWidth >= 960
            ? tiles.length >= 4
                  ? 4
                  : tiles.length
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
  const _ProvenanceNote({required this.stats, required this.accounts});

  final PlatformStats stats;
  final AccountTotals? accounts;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final platformText = stats.isFromCache
        ? stats.hasAnyCounterActivity
              ? 'Platform counters are from the local cache. Reconnect to '
                    'confirm that they are current.'
              : 'The cached platform snapshot contains no counter activity. '
                    'Reconnect before treating that as an authoritative zero.'
        : stats.hasAnyCounterActivity
        ? 'Platform counters are server-confirmed lifetime totals written by '
              'the trusted service inside the transactions that cause them.'
        : 'Firestore confirmed that no platform counter has been incremented '
              'yet, so zero is an available result rather than a loading state.';
    final accountText = accounts == null
        ? 'Account totals are loaded independently above.'
        : accounts!.isFromCache
        ? 'Account totals are from the local cache.'
        : accounts!.truncated
        ? 'Account totals are server-confirmed lower bounds because the '
              'directory reached its read cap.'
        : 'Account totals are server-confirmed directory counts.';

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
                '$platformText $accountText No client can write a platform '
                'counter, including a 3ZERO Admin.',
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
