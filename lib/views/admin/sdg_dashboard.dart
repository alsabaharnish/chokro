import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/dashboard_controller.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../models/sdg_impact_model.dart';
import '../../models/stats_model.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';

/// The SDG-aligned side of the Admin dashboard.
///
/// Chokro currently stores activity counters, not official UN indicators. This
/// view therefore presents traceable contribution signals and repeats the
/// measurement boundary wherever a number could otherwise be overclaimed.
class SdgImpactDashboard extends ConsumerWidget {
  const SdgImpactDashboard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final statsAsync = ref.watch(platformStatsProvider);
    final accountsAsync = ref.watch(accountTotalsProvider);

    return ListView(
      key: const PageStorageKey<String>('admin-sdg-impact'),
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
            child: statsAsync.when(
              loading: () => const SizedBox(
                height: 420,
                child: ContentLoading(
                  label: 'Confirming impact counters…',
                  slowHint:
                      'This is taking longer than expected. Check the connection '
                      'before treating an empty dashboard as zero activity.',
                ),
              ),
              error: (error, _) => SizedBox(
                height: 420,
                child: ErrorRetry(
                  error: error,
                  title: 'SDG impact counters',
                  onRetry: () => ref.invalidate(platformStatsProvider),
                ),
              ),
              data: (stats) =>
                  _ImpactContent(stats: stats, accountsAsync: accountsAsync),
            ),
          ),
        ),
      ],
    );
  }
}

class _ImpactContent extends StatelessWidget {
  const _ImpactContent({required this.stats, required this.accountsAsync});

  final PlatformStats stats;
  final AsyncValue<AccountTotals> accountsAsync;

  @override
  Widget build(BuildContext context) {
    final accounts = accountsAsync.value;
    final impact = SdgImpactSnapshot.fromPlatform(
      stats: stats,
      greenpreneurProfiles: accounts?.sellers ?? 0,
      greenpreneurCountIsFloor: accounts?.truncated ?? false,
    );
    final accountValue = accounts == null
        ? '—'
        : '${formatCount(accounts.sellers)}${accounts.truncated ? '+' : ''}';
    final accountDetail = accountsAsync.isLoading
        ? 'Counting the account directory…'
        : accountsAsync.hasError
        ? 'Account directory unavailable'
        : accounts?.isFromCache == true
        ? 'Cached account snapshot'
        : 'Current account snapshot';
    final hasCachedData = stats.isFromCache || accounts?.isFromCache == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ImpactHero(
          impact: impact,
          hasCachedData: hasCachedData,
          onMethodology: () => _showMethodology(context),
        ),
        const SizedBox(height: AppTheme.gapXl),
        Row(
          children: [
            Expanded(
              child: Text(
                'Selected SDG alignments',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            const SizedBox(width: AppTheme.gapMd),
            _SourceBadge(isCached: hasCachedData),
          ],
        ),
        const SizedBox(height: AppTheme.gapXs),
        Text(
          'Each card connects existing Chokro activity to a relevant UN target. '
          'The values are operational signals, not official indicators or an '
          'SDG progress score.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppTheme.gapLg),
        _EqualCardGrid(
          children: [
            _SdgGoalCard(
              number: 8,
              colour: const Color(0xFFA21942),
              title: 'Decent work and economic growth',
              target: 'Target 8.3',
              alignment:
                  'Greenpreneur participation and recorded marketplace activity '
                  'align with support for entrepreneurship and small enterprises.',
              metrics: [
                _ImpactMetric(
                  label: 'Accounts with a Greenpreneur profile',
                  value: accountValue,
                  detail: accountDetail,
                ),
                _ImpactMetric(
                  label: 'Marketplace orders placed',
                  value: formatCount(impact.marketplaceOrders),
                  detail: 'Orders placed, not confirmed income',
                ),
                _ImpactMetric(
                  label: 'Order value after points',
                  value: formatTaka(impact.marketplaceOrderValueTaka),
                  detail: 'Payable value recorded at checkout',
                ),
              ],
              boundary:
                  'These figures do not establish jobs created, income paid, or '
                  'enterprise growth.',
            ),
            _SdgGoalCard(
              number: 11,
              colour: const Color(0xFFFD9D24),
              title: 'Sustainable cities and communities',
              target: 'Target 11.6',
              alignment:
                  'Approved disposal submissions show use of Chokro\'s '
                  'location-aware waste-verification flow.',
              metrics: [
                _ImpactMetric(
                  label: 'Approved disposal submissions',
                  value: formatCount(impact.approvedDisposalSubmissions),
                  detail: 'Approved automatically or by an Admin',
                ),
                _ImpactMetric(
                  label: 'Disposal decisions',
                  value: formatCount(stats.disposalsDecided),
                  detail: _decisionRate(stats.disposalApprovalPercent),
                ),
              ],
              boundary:
                  'A submission is not a weight measurement or proof of '
                  'controlled-facility processing.',
            ),
            _SdgGoalCard(
              number: 12,
              colour: const Color(0xFFBF8B2E),
              title: 'Responsible consumption and production',
              target: 'Target 12.5',
              alignment:
                  'Approved disposal submissions and sustainable-product orders '
                  'are platform signals for recycling and responsible consumption.',
              metrics: [
                _ImpactMetric(
                  label: 'Approved disposal submissions',
                  value: formatCount(impact.approvedDisposalSubmissions),
                  detail: 'Recorded through the disposal flow',
                ),
                _ImpactMetric(
                  label: 'Sustainable-product orders placed',
                  value: formatCount(impact.marketplaceOrders),
                  detail: 'Orders placed with Greenpreneurs',
                ),
              ],
              boundary:
                  'The same disposal also aligns with Goal 11. Goal-card values '
                  'must not be added together.',
            ),
            _SdgGoalCard(
              number: 13,
              colour: const Color(0xFF3F7E44),
              title: 'Climate action',
              target: 'Target 13.3',
              alignment:
                  'Approved eco-action records and point contributions show '
                  'participation in environmental action.',
              metrics: [
                _ImpactMetric(
                  label: 'Approved eco-action records',
                  value: formatCount(impact.approvedEcoActions),
                  detail: 'Every record reviewed by an Admin',
                ),
                _ImpactMetric(
                  label: 'Point contributions',
                  value: formatCount(impact.initiativeContributions),
                  detail: 'Champion contributions to green initiatives',
                ),
                _ImpactMetric(
                  label: 'Points contributed',
                  value: formatCount(impact.initiativePoints),
                  detail: 'Reward points, not cash or deployed funds',
                ),
              ],
              boundary:
                  'These are participation records, not avoided-emissions '
                  'estimates or the official Target 13.3 indicator.',
            ),
          ],
        ),
        const SizedBox(height: AppTheme.gapLg),
        _CoverageNote(
          statsAreCached: stats.isFromCache,
          accountsAsync: accountsAsync,
          hasActivity: impact.hasRecordedActivity,
        ),
      ],
    );
  }

  static String _decisionRate(int? percent) => percent == null
      ? 'No decision rate yet'
      : '$percent% of decisions approved';
}

class _ImpactHero extends StatelessWidget {
  const _ImpactHero({
    required this.impact,
    required this.hasCachedData,
    required this.onMethodology,
  });

  final SdgImpactSnapshot impact;
  final bool hasCachedData;
  final VoidCallback onMethodology;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Semantics(
      container: true,
      label:
          '${formatCount(impact.approvedEnvironmentalActivityRecords)} approved '
          'environmental activity records. All-time SDG alignment summary.',
      child: Card(
        color: scheme.primary,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.gapLg),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 680;
              final summary = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: AppTheme.gapSm,
                    runSpacing: AppTheme.gapSm,
                    children: [
                      _HeroPill(
                        icon: Icons.public,
                        label: 'SDG alignment',
                        foreground: scheme.onPrimary,
                      ),
                      _HeroPill(
                        icon: hasCachedData
                            ? Icons.cloud_off_outlined
                            : Icons.cloud_done_outlined,
                        label: hasCachedData
                            ? 'Cached snapshot'
                            : 'Server confirmed',
                        foreground: scheme.onPrimary,
                      ),
                      _HeroPill(
                        icon: Icons.calendar_today_outlined,
                        label: 'All time',
                        foreground: scheme.onPrimary,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppTheme.gapLg),
                  Text(
                    'SDG impact signals',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      color: scheme.onPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: AppTheme.gapSm),
                  Text(
                    'A traceable view of the activity Chokro records across '
                    'waste, responsible consumption, climate participation, and '
                    'green entrepreneurship.',
                    style: theme.textTheme.bodyLarge?.copyWith(
                      color: scheme.onPrimary.withValues(alpha: .88),
                    ),
                  ),
                  const SizedBox(height: AppTheme.gapLg),
                  OutlinedButton.icon(
                    onPressed: onMethodology,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.onPrimary,
                      side: BorderSide(
                        color: scheme.onPrimary.withValues(alpha: .55),
                      ),
                    ),
                    icon: const Icon(Icons.rule_outlined),
                    label: const Text('Read methodology'),
                  ),
                ],
              );
              final total = ExcludeSemantics(
                child: Container(
                  constraints: BoxConstraints(
                    minWidth: compact ? 0 : 238,
                    maxWidth: compact ? double.infinity : 280,
                  ),
                  padding: const EdgeInsets.all(AppTheme.gapLg),
                  decoration: BoxDecoration(
                    color: scheme.onPrimary.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(AppTheme.radiusMd),
                    border: Border.all(
                      color: scheme.onPrimary.withValues(alpha: .2),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatCount(
                          impact.approvedEnvironmentalActivityRecords,
                        ),
                        style: theme.textTheme.displaySmall?.copyWith(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1.4,
                        ),
                      ),
                      const SizedBox(height: AppTheme.gapXs),
                      Text(
                        'Approved environmental activity records',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: scheme.onPrimary,
                        ),
                      ),
                      const SizedBox(height: AppTheme.gapSm),
                      Text(
                        'Approved disposals plus approved eco-actions. No '
                        'estimated weight or carbon is added.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onPrimary.withValues(alpha: .82),
                        ),
                      ),
                    ],
                  ),
                ),
              );

              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    summary,
                    const SizedBox(height: AppTheme.gapLg),
                    total,
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: summary),
                  const SizedBox(width: AppTheme.gapXl),
                  total,
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _HeroPill extends StatelessWidget {
  const _HeroPill({
    required this.icon,
    required this.label,
    required this.foreground,
  });

  final IconData icon;
  final String label;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppTheme.gapSm,
        vertical: 6,
      ),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: foreground.withValues(alpha: .2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: foreground),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceBadge extends StatelessWidget {
  const _SourceBadge({required this.isCached});

  final bool isCached;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final background = isCached
        ? scheme.warningContainer
        : scheme.successContainer;
    final foreground = isCached
        ? scheme.onWarningContainer
        : scheme.onSuccessContainer;

    return Tooltip(
      message: isCached
          ? 'Showing the most recent locally cached snapshot'
          : 'Firestore has confirmed this snapshot with the server',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isCached ? Icons.cloud_off_outlined : Icons.cloud_done_outlined,
              size: 15,
              color: foreground,
            ),
            const SizedBox(width: 6),
            Text(
              isCached ? 'Cached' : 'Confirmed',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: foreground,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SdgGoalCard extends StatefulWidget {
  const _SdgGoalCard({
    required this.number,
    required this.colour,
    required this.title,
    required this.target,
    required this.alignment,
    required this.metrics,
    required this.boundary,
  });

  final int number;
  final Color colour;
  final String title;
  final String target;
  final String alignment;
  final List<_ImpactMetric> metrics;
  final String boundary;

  @override
  State<_SdgGoalCard> createState() => _SdgGoalCardState();
}

class _SdgGoalCardState extends State<_SdgGoalCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final badgeForeground = _readableForeground(widget.colour);

    return Semantics(
      container: true,
      label:
          'Sustainable Development Goal ${widget.number}: ${widget.title}. '
          '${widget.target}.',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          transform: _hovered
              ? Matrix4.translationValues(0, -2, 0)
              : Matrix4.identity(),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: Border.all(
              color: _hovered
                  ? widget.colour.withValues(alpha: .7)
                  : scheme.outlineVariant,
            ),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: .09),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ]
                : const [],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd - 1),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(height: 5, color: widget.colour),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(AppTheme.gapLg),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            ExcludeSemantics(
                              child: Container(
                                width: 54,
                                height: 54,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: widget.colour,
                                  borderRadius: BorderRadius.circular(14),
                                ),
                                child: Text(
                                  '${widget.number}',
                                  style: theme.textTheme.headlineSmall
                                      ?.copyWith(
                                        color: badgeForeground,
                                        fontWeight: FontWeight.w900,
                                      ),
                                ),
                              ),
                            ),
                            const SizedBox(width: AppTheme.gapMd),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    widget.title,
                                    style: theme.textTheme.titleLarge?.copyWith(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: AppTheme.gapXs),
                                  Text(
                                    widget.target,
                                    style: theme.textTheme.labelLarge?.copyWith(
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppTheme.gapMd),
                        Text(
                          widget.alignment,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(height: AppTheme.gapLg),
                        ...widget.metrics.map(
                          (metric) => Padding(
                            padding: const EdgeInsets.only(
                              bottom: AppTheme.gapMd,
                            ),
                            child: _MetricRow(metric: metric),
                          ),
                        ),
                        const Spacer(),
                        Divider(color: scheme.outlineVariant),
                        const SizedBox(height: AppTheme.gapSm),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 17,
                              color: scheme.onSurfaceVariant,
                            ),
                            const SizedBox(width: AppTheme.gapSm),
                            Expanded(
                              child: Text(
                                widget.boundary,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Color _readableForeground(Color background) {
  final luminance = background.computeLuminance();
  final contrastWithBlack = (luminance + 0.05) / 0.05;
  final contrastWithWhite = 1.05 / (luminance + 0.05);
  return contrastWithBlack >= contrastWithWhite ? Colors.black : Colors.white;
}

class _ImpactMetric {
  const _ImpactMetric({
    required this.label,
    required this.value,
    required this.detail,
  });

  final String label;
  final String value;
  final String detail;
}

class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.metric});

  final _ImpactMetric metric;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(metric.label, style: theme.textTheme.labelLarge),
              const SizedBox(height: 2),
              Text(
                metric.detail,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: AppTheme.gapMd),
        Flexible(
          child: Text(
            metric.value,
            textAlign: TextAlign.end,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ],
    );
  }
}

/// Builds equal-height rows without fixing an aspect ratio. A fixed grid ratio
/// clips as soon as text is enlarged, while a plain Wrap leaves paired desktop
/// cards at visibly different heights.
class _EqualCardGrid extends StatelessWidget {
  const _EqualCardGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 780 ? 2 : 1;
        final rows = <Widget>[];

        for (var start = 0; start < children.length; start += columns) {
          final end = start + columns < children.length
              ? start + columns
              : children.length;
          final rowChildren = children.sublist(start, end);
          rows.add(
            Padding(
              padding: EdgeInsets.only(
                bottom: end < children.length ? AppTheme.gapMd : 0,
              ),
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var index = 0; index < columns; index++) ...[
                      if (index > 0) const SizedBox(width: AppTheme.gapMd),
                      Expanded(
                        child: index < rowChildren.length
                            ? rowChildren[index]
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          );
        }

        return Column(children: rows);
      },
    );
  }
}

class _CoverageNote extends StatelessWidget {
  const _CoverageNote({
    required this.statsAreCached,
    required this.accountsAsync,
    required this.hasActivity,
  });

  final bool statsAreCached;
  final AsyncValue<AccountTotals> accountsAsync;
  final bool hasActivity;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final accountStatus = accountsAsync.isLoading
        ? 'The account directory is still loading.'
        : accountsAsync.hasError
        ? 'The account directory could not be loaded; SDG 8 shows an unavailable '
              'profile count.'
        : accountsAsync.value?.isFromCache == true
        ? 'The Greenpreneur count is from the local cache.'
        : 'The Greenpreneur count is confirmed by Firestore.';

    return Card(
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapLg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: scheme.primaryContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(
                hasActivity ? Icons.verified_outlined : Icons.hourglass_empty,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasActivity
                        ? 'Coverage and freshness'
                        : 'Impact reporting is ready',
                    style: theme.textTheme.titleMedium,
                  ),
                  const SizedBox(height: AppTheme.gapXs),
                  Text(
                    '${statsAreCached ? 'Platform counters are from the local cache.' : 'Platform counters are confirmed by Firestore.'} '
                    '$accountStatus '
                    '${hasActivity ? 'All values are lifetime totals; the current schema does not support date trends.' : 'The cards will populate after the first approved activity, marketplace order, or contribution.'}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
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

void _showMethodology(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.gapLg,
        AppTheme.gapSm,
        AppTheme.gapLg,
        AppTheme.gapXl,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'How SDG alignment is calculated',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: AppTheme.gapSm),
              Text(
                'Chokro maps its own operational records to selected UN targets: '
                '8.3, 11.6, 12.5, and 13.3. It does not convert those records '
                'into an official SDG score.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: AppTheme.gapLg),
              const _MethodologyItem(
                icon: Icons.verified_user_outlined,
                title: 'Only approved records are counted',
                body:
                    'The combined activity total is approved disposal '
                    'submissions plus approved eco-action records. Rejections '
                    'and pending reviews are excluded.',
              ),
              const _MethodologyItem(
                icon: Icons.rule_outlined,
                title: 'Goal cards may overlap',
                body:
                    'One approved disposal is relevant to both Goals 11 and 12. '
                    'It appears in both cards but only once in the combined '
                    'activity total.',
              ),
              const _MethodologyItem(
                icon: Icons.straighten_outlined,
                title: 'Unmeasured outcomes stay unclaimed',
                body:
                    'The current schema does not support kilograms recycled, '
                    'carbon avoided, jobs created, income paid, or progress '
                    'against a baseline. No estimate is substituted for them.',
              ),
              const _MethodologyItem(
                icon: Icons.history_outlined,
                title: 'Counters are lifetime totals',
                body:
                    'The trusted service maintains the platform counters. '
                    'Account totals come from the bounded Admin directory and '
                    'show a plus sign when that read is truncated.',
              ),
              const SizedBox(height: AppTheme.gapMd),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Done'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _MethodologyItem extends StatelessWidget {
  const _MethodologyItem({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.gapLg),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(width: AppTheme.gapMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                const SizedBox(height: AppTheme.gapXs),
                Text(
                  body,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
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
