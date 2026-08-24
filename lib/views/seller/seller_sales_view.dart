import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/sales_report_controller.dart';
import '../../core/label_format.dart';
import '../../core/sales_report.dart';
import '../../core/theme.dart';
import '../../models/order_model.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';

/// The Greenpreneur's sales report (F4.6).
///
/// ## The one thing this screen must not do
///
/// Imply that Chokro is holding money for the seller. It is not: there is no
/// seller wallet anywhere in the system, and a buyer settles with a Greenpreneur
/// directly — cash at the door, or through one of the prototype online methods,
/// which move nothing at all. So the figures here describe *orders*, and the
/// screen says as much in the header rather than leaving a reader to assume the
/// friendlier interpretation.
///
/// The three settlement figures are kept apart for the same reason. Cash a
/// seller has actually taken, a simulation that only looks like a payment, and
/// money still to collect are three different facts, and a single "received"
/// total would merge the first two into a number that is partly fictional.
class SellerSalesView extends ConsumerWidget {
  const SellerSalesView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reportAsync = ref.watch(sellerSalesReportProvider);

    return AppShell(
      title: 'Sales',
      child: reportAsync.when(
        loading: () => const ContentLoading(label: 'Adding up your orders…'),
        error: (error, _) => ErrorRetry(
          error: error,
          title: 'Your sales',
          onRetry: () => ref.invalidate(sellerReportOrdersProvider),
        ),
        data: (report) => _Report(report: report),
      ),
    );
  }
}

class _Report extends ConsumerWidget {
  const _Report({required this.report});

  final SellerSalesReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Flutter web renders to canvas, so none of these figures could be selected
    // or copied — and a seller reconciling takings against a notebook or a
    // spreadsheet wants exactly that. Costs nothing on mobile, where a long
    // press now selects rather than doing nothing.
    return SelectionArea(
      child: RefreshIndicator(
        onRefresh: () async => ref.invalidate(sellerReportOrdersProvider),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 720;

            return ListView(
              padding: EdgeInsets.fromLTRB(
                wide ? AppTheme.gapXl : AppTheme.gapMd,
                AppTheme.gapMd,
                wide ? AppTheme.gapXl : AppTheme.gapMd,
                AppTheme.gap2Xl,
              ),
              children: [
                Center(
                  child: ConstrainedBox(
                    // Centres rather than stretching to the edge of a monitor —
                    // a report read edge to edge on 1920px is unreadable.
                    constraints: const BoxConstraints(
                      maxWidth: AppTheme.maxDashboardWidth,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _PeriodSelector(selected: report.period, wide: wide),
                        const SizedBox(height: AppTheme.gapLg),
                        _Headline(report: report),
                        if (report.truncated) ...[
                          const SizedBox(height: AppTheme.gapMd),
                          _Caveat(
                            icon: Icons.filter_alt_outlined,
                            text:
                                'You have more orders than this report reads, so '
                                'these figures are floors rather than totals — at '
                                'least this much. Counted back to '
                                '${formatDate(report.oldestOrder)}; anything '
                                'older is not included.',
                          ),
                        ],
                        if (report.undated > 0) ...[
                          const SizedBox(height: AppTheme.gapMd),
                          _Caveat(
                            icon: Icons.event_busy_outlined,
                            text:
                                '${report.undated} order'
                                '${report.undated == 1 ? ' has' : 's have'} no '
                                'readable date, so '
                                '${report.undated == 1 ? 'it is' : 'they are'} '
                                'left out of every dated period.',
                          ),
                        ],
                        const SizedBox(height: AppTheme.gapLg),
                        _SettlementGrid(report: report, wide: wide),
                        const SizedBox(height: AppTheme.gapLg),
                        _VolumeCard(report: report),
                        const SizedBox(height: AppTheme.gapLg),
                        _StatusCard(report: report),
                      ],
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The five windows.
///
/// A [SegmentedButton] where there is room and a scrolling row of chips where
/// there is not. Five segments do not fit across a 320 dp phone at any text
/// size, and a segmented control that overflows is worse than a list that
/// scrolls.
class _PeriodSelector extends ConsumerWidget {
  const _PeriodSelector({required this.selected, required this.wide});

  final SalesPeriod selected;
  final bool wide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    void select(SalesPeriod period) =>
        ref.read(salesPeriodProvider.notifier).select(period);

    if (wide) {
      return Align(
        alignment: Alignment.centerLeft,
        child: SegmentedButton<SalesPeriod>(
          segments: [
            for (final period in SalesPeriod.values)
              ButtonSegment(value: period, label: Text(period.label)),
          ],
          selected: {selected},
          showSelectedIcon: false,
          onSelectionChanged: (values) => select(values.first),
        ),
      );
    }

    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: SalesPeriod.values.length,
        separatorBuilder: (_, _) => const SizedBox(width: AppTheme.gapSm),
        itemBuilder: (context, index) {
          final period = SalesPeriod.values[index];
          return ChoiceChip(
            label: Text(period.label),
            selected: period == selected,
            onSelected: (_) => select(period),
          );
        },
      ),
    );
  }
}

/// The period's income, and the plain statement of what it is.
class _Headline extends StatelessWidget {
  const _Headline({required this.report});

  final SellerSalesReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final since = report.since;
    final window = since == null
        ? 'Every order you have ever had'
        : report.period == SalesPeriod.today
        ? 'Orders placed today'
        : 'Orders placed since ${formatDate(since)}';

    return Card(
      margin: EdgeInsets.zero,
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapLg),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              window,
              style: theme.textTheme.labelLarge?.copyWith(
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: AppTheme.gapSm),
            Text(
              // The qualifier belongs on the number, not only in a note beside
              // it. A reader who takes one thing off this screen takes the
              // headline.
              report.truncated
                  ? 'at least ${formatTaka(report.net)}'
                  : formatTaka(report.net),
              style: theme.textTheme.displaySmall?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              'Earned from ${orderCount(report.orderCount)}, after points '
              'discounts.',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: AppTheme.gapMd),
            // The sentence the whole screen exists to keep honest.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline,
                  size: 16,
                  color: scheme.onPrimaryContainer,
                ),
                const SizedBox(width: AppTheme.gapSm),
                Expanded(
                  child: Text(
                    'Chokro does not hold this money. 3ZERO Champions pay you '
                    'directly, so this is what your orders were worth — not a '
                    'balance waiting to be paid out.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onPrimaryContainer,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Cash taken, simulated payments, and money still to collect — never added up.
class _SettlementGrid extends StatelessWidget {
  const _SettlementGrid({required this.report, required this.wide});

  final SellerSalesReport report;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    final tiles = <Widget>[
      _StatTile(
        icon: Icons.payments_outlined,
        label: 'Received in cash',
        value: formatTaka(report.collected),
        note: 'Cash on delivery you have marked delivered.',
        tone: scheme.success,
      ),
      _StatTile(
        icon: Icons.hourglass_bottom_outlined,
        label: 'Still to collect',
        value: formatTaka(report.outstanding),
        // Not "owed": nothing is overdue, these are simply orders that have not
        // reached the door yet. Framing it as a debt would misdescribe it.
        note: 'On orders you have not delivered yet.',
        tone: scheme.warning,
      ),
      _StatTile(
        icon: Icons.science_outlined,
        label: 'Simulated online',
        value: formatTaka(report.simulated),
        note: 'Prototype payments. No real money moved.',
        tone: scheme.onSurfaceVariant,
      ),
      _StatTile(
        icon: Icons.redeem_outlined,
        label: 'Points discount',
        value: '−${formatTaka(report.pointsDiscount)}',
        note:
            'Paid by Champions with points, so it came off your '
            '${formatTaka(report.gross)} list value.',
        tone: scheme.onSurfaceVariant,
      ),
    ];

    // A Wrap rather than a GridView: the tiles size to their own content, so a
    // long note at a large text size makes its tile taller instead of clipping,
    // and the row count follows the width without a breakpoint per layout.
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 900
            ? 4
            : constraints.maxWidth >= 560
            ? 2
            : 1;
        final spacing = AppTheme.gapMd;
        final width = columns == 1
            ? constraints.maxWidth
            : (constraints.maxWidth - spacing * (columns - 1)) / columns;

        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final tile in tiles) SizedBox(width: width, child: tile),
          ],
        );
      },
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.note,
    required this.tone,
  });

  final IconData icon;
  final String label;
  final String value;
  final String note;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: tone),
                const SizedBox(width: AppTheme.gapSm),
                Expanded(
                  child: Text(
                    label,
                    style: theme.textTheme.labelLarge?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.gapSm),
            Text(
              value,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              note,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _VolumeCard extends StatelessWidget {
  const _VolumeCard({required this.report});

  final SellerSalesReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Volume',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppTheme.gapSm),
            _Line(label: 'Orders', value: '${report.orderCount}'),
            _Line(label: 'Items sold', value: '${report.itemCount}'),
            _Line(
              label: 'List value before points',
              value: formatTaka(report.gross),
            ),
            // Points, not taka — `pointsApplied` is a points quantity, and
            // formatting it as money would overstate it tenfold at the default
            // policy of ten points to the taka.
            _Line(
              label: 'Points spent by Champions',
              value: '${report.pointsRedeemed} pts',
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.report});

  final SellerSalesReport report;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Where these orders are',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: AppTheme.gapSm),
            for (final status in OrderStatus.values)
              _Line(
                label: status.label,
                value: '${report.countByStatus[status] ?? 0}',
              ),
            const SizedBox(height: AppTheme.gapSm),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => context.go('/seller/orders'),
                icon: const Icon(Icons.local_shipping_outlined),
                label: const Text('Open the orders to fulfil'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppTheme.gapXs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: AppTheme.gapMd),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

/// A qualification on the figures above it. Never a footnote — a caveat a reader
/// has to go looking for is one they will not find.
class _Caveat extends StatelessWidget {
  const _Caveat({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Container(
      padding: const EdgeInsets.all(AppTheme.gapMd),
      decoration: BoxDecoration(
        color: scheme.warningContainer,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: scheme.onWarningContainer),
          const SizedBox(width: AppTheme.gapSm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onWarningContainer,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
