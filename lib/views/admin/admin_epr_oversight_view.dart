library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/admin_oversight_controller.dart';
import '../../core/epr_period.dart';
import '../../core/mass_math.dart';
import '../../core/theme.dart';
import '../../models/admin_oversight_model.dart';
import '../../services/organization_service.dart' show OrgActionException;
import '../shared/app_shell.dart';
import '../shared/app_snackbar.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';
import '../shared/rejection_reason_dialog.dart';

/// Chokro checking its own work (EPR-43, EPR-45, EPR-47, EPR-48, EPR-17).
///
/// ## Why one screen with tabs rather than five entry points
///
/// The Admin home is a grid of exactly ten cards, and it is the ONLY place all
/// the admin screens are reachable — six of the ten have no navigation chrome
/// at all, just a "back to home" button. Adding five more cards would make it
/// fifteen, and adding five more chrome-less screens would mean every move
/// between two oversight surfaces is home, card, screen.
///
/// These five belong together anyway. They are one activity — is what Chokro
/// is publishing defensible — and an Admin investigating a producer moves
/// between them constantly: a flagged declaration leads to the anomaly queue,
/// which leads to the issuance register to see what was certified on it.
///
/// ## The period is the thread
///
/// One selector at the top, shared by every tab, because an Admin investigating
/// September who switches from anomalies to accuracy is still investigating
/// September. Making each tab carry its own period would let two of them
/// disagree while sitting a tap apart.
///
/// ## Nothing here computes a figure
///
/// Every percentage, mass and variance comes off the model as the server sent
/// it. Where the server sent null, this renders the server's stated REASON
/// rather than a dash — a blank on a reconciliation screen reads as "checked
/// and fine", which is the opposite of what an unchecked period means.
class AdminEprOversightView extends ConsumerStatefulWidget {
  const AdminEprOversightView({super.key});

  @override
  ConsumerState<AdminEprOversightView> createState() =>
      _AdminEprOversightViewState();
}

class _AdminEprOversightViewState extends ConsumerState<AdminEprOversightView>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 5, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppShell(
      title: 'EPR oversight',
      child: Column(
        children: [
          const _PeriodBar(),
          TabBar(
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: const [
              Tab(text: 'Anomalies'),
              Tab(text: 'Declarations'),
              Tab(text: 'Reconciliation'),
              Tab(text: 'Accuracy'),
              Tab(text: 'Issuance'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: const [
                _AnomalyTab(),
                _DeclarationReviewTab(),
                _ReconciliationTab(),
                _AccuracyTab(),
                _IssuanceTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The period selector, shared by every tab.
class _PeriodBar extends ConsumerWidget {
  const _PeriodBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(oversightPeriodProvider);
    final options = ref.watch(oversightPeriodOptionsProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.gapMd,
        AppTheme.gapMd,
        AppTheme.gapMd,
        AppTheme.gapSm,
      ),
      child: Row(
        children: [
          Icon(
            Icons.calendar_month_outlined,
            size: 18,
            color: Theme.of(context).colorScheme.outline,
          ),
          const SizedBox(width: AppTheme.gapSm),
          Expanded(
            child: DropdownButtonFormField<String>(
              initialValue: options.contains(selected) ? selected : null,
              isDense: true,
              decoration: const InputDecoration(
                labelText: 'Reporting period',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: AppTheme.gapSm,
                  vertical: AppTheme.gapSm,
                ),
              ),
              items: [
                for (final option in options)
                  DropdownMenuItem(
                    value: option,
                    child: Text(periodLabel(option)),
                  ),
              ],
              onChanged: (value) {
                if (value == null) return;
                ref.read(oversightPeriodProvider.notifier).select(value);
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Anomalies (EPR-45)
// ---------------------------------------------------------------------------

class _AnomalyTab extends ConsumerWidget {
  const _AnomalyTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(anomalyFilterProvider);
    final queue = ref.watch(anomalyQueueProvider);

    return Column(
      children: [
        _FilterChips(
          values: AnomalyStatus.all,
          selected: status,
          label: AnomalyStatus.label,
          onSelect: (value) =>
              ref.read(anomalyFilterProvider.notifier).select(value),
        ),
        Expanded(
          child: queue.when(
            loading: () => const ContentLoading(
              label: 'Loading…',
              slowHint: ContentLoading.serverWakingHint,
            ),
            error: (error, _) => ErrorRetry(
              error: error,
              onRetry: () => ref.invalidate(anomalyQueueProvider),
            ),
            data: (findings) {
              if (findings.isEmpty) {
                return _EmptyQueue(
                  icon: Icons.verified_outlined,
                  title: status == AnomalyStatus.open
                      ? 'Nothing flagged'
                      : 'Nothing ${AnomalyStatus.label(status).toLowerCase()}',
                  // The distinction that keeps a queue honest: an empty queue
                  // is not evidence that anything was checked.
                  message: status == AnomalyStatus.open
                      ? 'No open findings. A scan is triggered per producer '
                            'and period — an empty queue does not mean a '
                            'period has been examined.'
                      : 'No findings have been closed with this outcome.',
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.all(AppTheme.gapMd),
                itemCount: findings.length,
                itemBuilder: (context, i) => Padding(
                  padding: const EdgeInsets.only(bottom: AppTheme.gapMd),
                  child: _AnomalyCard(finding: findings[i]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _AnomalyCard extends ConsumerStatefulWidget {
  const _AnomalyCard({required this.finding});

  final AnomalyFinding finding;

  @override
  ConsumerState<_AnomalyCard> createState() => _AnomalyCardState();
}

class _AnomalyCardState extends ConsumerState<_AnomalyCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final finding = widget.finding;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _SeverityPill(severity: finding.severity),
                const SizedBox(width: AppTheme.gapSm),
                Expanded(
                  child: Text(
                    anomalyTypeLabel(finding.type),
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text(
                  periodLabel(finding.periodId),
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              '${anomalySubjectLabel(finding.subjectType)} ${finding.subjectId}'
              '  ·  ${finding.orgId}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),

            // The uid of a real person. Marked so an Admin sharing a screenshot
            // of this queue knows which row carries somebody's identity
            // (SEC-3).
            if (finding.namesAPerson) ...[
              const SizedBox(height: AppTheme.gapXs),
              Row(
                children: [
                  Icon(
                    Icons.person_outline,
                    size: 14,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      'Names an individual account. Not to be shared outside '
                      'Chokro or shown to the producer.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                ],
              ),
            ],

            const SizedBox(height: AppTheme.gapSm),
            // The server's sentence, verbatim. It leads with the innocent
            // explanation on purpose.
            Text(finding.summary, style: theme.textTheme.bodyMedium),

            if (finding.figures.isNotEmpty) ...[
              const SizedBox(height: AppTheme.gapSm),
              _FigureTable(figures: finding.figures),
            ],

            if (!finding.isOpen && finding.dismissedReason != null) ...[
              const SizedBox(height: AppTheme.gapSm),
              NoticeCard(
                icon: Icons.history,
                tone: NoticeTone.info,
                title: AnomalyStatus.label(finding.status),
                message: finding.dismissedReason!,
              ),
            ],

            if (finding.isOpen) ...[
              const SizedBox(height: AppTheme.gapMd),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy
                          ? null
                          : () => _close(AnomalyStatus.dismissed),
                      child: const Text('Innocent — dismiss'),
                    ),
                  ),
                  const SizedBox(width: AppTheme.gapSm),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: _busy
                          ? null
                          : () => _close(AnomalyStatus.actioned),
                      child: const Text('Real — actioned'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.gapXs),
              Text(
                // Why both buttons exist. Collapsing them would make the
                // queue's own history useless for the question an auditor
                // asks: how many of these turned out to be real.
                'Both record a reason. "Dismiss" says this had an innocent '
                'explanation; "actioned" says it was real and something was '
                'done.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _close(String outcome) async {
    final snack = AppSnackBar.of(context);
    final reason = await showRejectionReasonDialog(
      context,
      title: outcome == AnomalyStatus.dismissed
          ? 'Why is this finding being dismissed?'
          : 'What was done about this finding?',
      hintText: outcome == AnomalyStatus.dismissed
          ? 'e.g. Confirmed with the producer: a new distributor in Khulna.'
          : 'e.g. The SKU was re-weighed and its unit mass corrected.',
    );
    if (reason == null) return;

    setState(() => _busy = true);
    try {
      await ref.read(adminOversightServiceProvider).closeAnomaly(
        id: widget.finding.id,
        reason: reason,
        outcome: outcome,
      );
      invalidateOversight(ref);
      snack.success('Finding ${AnomalyStatus.label(outcome).toLowerCase()}.');
    } on OrgActionException catch (error) {
      snack.failure(error.message);
    } catch (_) {
      snack.failure('The finding could not be closed.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _SeverityPill extends StatelessWidget {
  const _SeverityPill({required this.severity});

  final String severity;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (severity) {
      AnomalySeverity.high => (scheme.errorContainer, scheme.onErrorContainer),
      AnomalySeverity.medium => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
      ),
      AnomalySeverity.low => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      // An unrecognised severity reads as serious, matching
      // `AnomalySeverity.rank` sorting it to the top. A future detector should
      // surface loudly rather than settle quietly at the bottom.
      _ => (scheme.errorContainer, scheme.onErrorContainer),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.gapSm, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        AnomalySeverity.label(severity),
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}

/// The figures that triggered a finding, including the threshold in force.
///
/// Rendered as raw key-value pairs rather than prettified. An Admin reading a
/// finding six months later needs to see the threshold it was judged against
/// at the time, and a friendly summary would lose exactly that.
class _FigureTable extends StatelessWidget {
  const _FigureTable({required this.figures});

  final Map<String, Object?> figures;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = figures.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return Container(
      padding: const EdgeInsets.all(AppTheme.gapSm),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 3,
                    child: Text(
                      entry.key,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: Text(
                      _figureText(entry.key, entry.value),
                      textAlign: TextAlign.right,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// A milligram field as kilograms, anything else verbatim.
  ///
  /// The conversion is display-only and uses the same helper the portal does,
  /// so a mass in a finding and the same mass on a certificate read alike.
  static String _figureText(String key, Object? value) {
    if (value == null) return '—';
    if (key.endsWith('MassMg') && value is num) {
      return formatKilograms(value.round());
    }
    if (value is double) return value.toStringAsFixed(4);
    return value.toString();
  }
}

// ---------------------------------------------------------------------------
// Declaration review (EPR-43)
// ---------------------------------------------------------------------------

class _DeclarationReviewTab extends ConsumerWidget {
  const _DeclarationReviewTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(declarationReviewProvider);

    return queue.when(
      loading: () => const ContentLoading(
        label: 'Loading…',
        slowHint: ContentLoading.serverWakingHint,
      ),
      error: (error, _) => ErrorRetry(
        error: error,
        onRetry: () => ref.invalidate(declarationReviewProvider),
      ),
      data: (rows) {
        if (rows.isEmpty) {
          return const _EmptyQueue(
            icon: Icons.assignment_turned_in_outlined,
            title: 'No filed declarations',
            message: 'Nothing has been filed and attested yet.',
          );
        }

        final flagged = rows.where((r) => r.flagged).length;

        return ListView(
          padding: const EdgeInsets.all(AppTheme.gapMd),
          children: [
            NoticeCard(
              icon: Icons.rule_outlined,
              tone: flagged > 0 ? NoticeTone.warning : NoticeTone.info,
              title: flagged > 0
                  ? '$flagged of ${rows.length} filings flagged'
                  : 'No filing flagged',
              message:
                  'A declaration that moves sharply against the previous '
                  'period, or one withdrawn and refiled lower, is either a '
                  'business change or a manipulation. A producer’s own note '
                  'suppresses the flag but not the figure.',
            ),
            const SizedBox(height: AppTheme.gapMd),
            for (final row in rows) ...[
              _DeclarationRow(row: row),
              const SizedBox(height: AppTheme.gapMd),
            ],
          ],
        );
      },
    );
  }
}

class _DeclarationRow extends StatelessWidget {
  const _DeclarationRow({required this.row});

  final DeclarationReviewRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (row.flagged) ...[
                  Icon(Icons.flag, size: 16, color: theme.colorScheme.error),
                  const SizedBox(width: 6),
                ],
                Expanded(
                  child: Text(
                    '${row.orgId}  ·  ${periodLabel(row.periodId)}',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Text('v${row.version}', style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              '${formatKilograms(row.totalMassMg)} declared, attested by '
              '${row.attestedByName}',
              style: theme.textTheme.bodyMedium,
            ),

            const SizedBox(height: AppTheme.gapSm),
            _VarianceLine(
              label: 'Against ${row.previousPeriod ?? 'the previous period'}',
              variance: row.variance,
              // Null is not zero. "Nothing to compare against" is a different
              // statement from "no change", and a first filing has no
              // predecessor.
              absence: 'First filing — nothing to compare against.',
            ),
            _VarianceLine(
              label: 'Against version ${row.version - 1}',
              variance: row.correctionVariance,
              absence: 'Not a correction of an earlier version.',
            ),

            if (row.flagReasons.isNotEmpty) ...[
              const SizedBox(height: AppTheme.gapSm),
              for (final reason in row.flagReasons)
                Text(
                  '• $reason',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: row.flagged
                        ? theme.colorScheme.error
                        : theme.colorScheme.outline,
                  ),
                ),
            ],

            if (row.hasNote) ...[
              const SizedBox(height: AppTheme.gapSm),
              NoticeCard(
                icon: Icons.sticky_note_2_outlined,
                tone: NoticeTone.info,
                title: 'The producer explained this',
                message: row.note ?? '',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VarianceLine extends StatelessWidget {
  const _VarianceLine({
    required this.label,
    required this.variance,
    required this.absence,
  });

  final String label;
  final double? variance;
  final String absence;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final value = variance;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          Text(
            // The reason, not a dash. A dash in a variance column reads as
            // "no change", which is the one thing it does not mean.
            value == null
                ? absence
                : '${value >= 0 ? '+' : ''}${(value * 100).toStringAsFixed(0)}%',
            style: theme.textTheme.bodySmall?.copyWith(
              color: value == null ? theme.colorScheme.outline : null,
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Reconciliation (EPR-48)
// ---------------------------------------------------------------------------

class _ReconciliationTab extends ConsumerWidget {
  const _ReconciliationTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overview = ref.watch(reconciliationProvider);

    return overview.when(
      loading: () => const ContentLoading(
        label: 'Loading…',
        slowHint: ContentLoading.serverWakingHint,
      ),
      error: (error, _) => ErrorRetry(
        error: error,
        onRetry: () => ref.invalidate(reconciliationProvider),
      ),
      data: (data) => ListView(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        children: [
          _CoverageCard(overview: data),
          const SizedBox(height: AppTheme.gapMd),

          if (data.mismatched.isNotEmpty) ...[
            Text(
              'Counters that disagree with a recompute',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              // QA-3: the mismatch is surfaced, never silently corrected. Both
              // figures are shown and neither is presented as the truth.
              'Both figures are shown. Chokro does not overwrite the '
              'incremented counter with the recomputed one — a disagreement is '
              'evidence of a fault, not a number to tidy away.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppTheme.gapSm),
            for (final row in data.mismatched) ...[
              _MismatchCard(row: row),
              const SizedBox(height: AppTheme.gapSm),
            ],
            const SizedBox(height: AppTheme.gapMd),
          ],

          if (data.unchecked.isNotEmpty) ...[
            Text(
              'Never checked',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppTheme.gapSm),
            for (final row in data.unchecked.take(20))
              _UncheckedRow(row: row),
            if (data.uncheckedListIsTruncated) ...[
              const SizedBox(height: AppTheme.gapSm),
              Text(
                // Saying so rather than letting a bounded list read as a
                // complete one — the same honesty `AdminTaskProgress.atCap`
                // applies to the review queues.
                'Showing ${data.unchecked.length > 20 ? 20 : data.unchecked.length} '
                'of ${data.uncheckedCount}. The count above is the total.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

/// The figure an auditor actually asks about: how much has anyone verified?
class _CoverageCard extends StatelessWidget {
  const _CoverageCard({required this.overview});

  final ReconciliationOverview overview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final share = overview.uncheckedShare;

    return Card(
      color: overview.mismatched.isNotEmpty
          ? theme.colorScheme.errorContainer
          : theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Across ${overview.periodsExamined} producer periods',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppTheme.gapSm),
            _CoverageLine(
              label: 'Checked and agreed',
              value: '${overview.reconciled}',
            ),
            _CoverageLine(
              label: 'Checked and disagreed',
              value: '${overview.mismatched.length}',
              emphasise: overview.mismatched.isNotEmpty,
            ),
            _CoverageLine(
              label: 'Never checked',
              value: '${overview.uncheckedCount}'
                  '${share == null ? '' : ' (${(share * 100).round()}%)'}',
              emphasise: overview.uncheckedCount > 0,
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              '${formatKilograms(overview.uncheckedMassMg)} of collected mass '
              'has never been recomputed from its raw rows.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverageLine extends StatelessWidget {
  const _CoverageLine({
    required this.label,
    required this.value,
    this.emphasise = false,
  });

  final String label;
  final String value;
  final bool emphasise;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: theme.textTheme.bodyMedium),
          Text(
            value,
            style: emphasise
                ? theme.textTheme.titleSmall
                : theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}

class _MismatchCard extends ConsumerStatefulWidget {
  const _MismatchCard({required this.row});

  final ReconciliationRow row;

  @override
  ConsumerState<_MismatchCard> createState() => _MismatchCardState();
}

class _MismatchCardState extends ConsumerState<_MismatchCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    final theme = Theme.of(context);
    final variance = row.variance;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${row.orgId}  ·  ${periodLabel(row.periodId)}',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: AppTheme.gapSm),
            _CoverageLine(
              label: 'Counters say',
              value: formatKilograms(row.incrementedMassMg),
            ),
            _CoverageLine(
              label: 'Recompute says',
              value: row.recomputedMassMg == null
                  ? 'never checked'
                  : formatKilograms(row.recomputedMassMg!),
            ),
            if (variance != null)
              _CoverageLine(
                label: 'Difference',
                value: '${variance >= 0 ? '+' : '−'}'
                    '${formatKilograms(variance.abs())}',
                emphasise: true,
              ),
            const SizedBox(height: AppTheme.gapSm),
            OutlinedButton.icon(
              onPressed: _busy ? null : _recompute,
              icon: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh, size: 18),
              label: const Text('Recompute again'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _recompute() async {
    final snack = AppSnackBar.of(context);
    setState(() => _busy = true);
    try {
      final result = await ref.read(adminOversightServiceProvider).recompute(
        orgId: widget.row.orgId,
        periodId: widget.row.periodId,
      );
      ref.invalidate(reconciliationProvider);

      // A partial pass is reported as partial. Its "variance" compares a full
      // counter against a fraction of the rows, so calling it a result would
      // be worse than saying nothing.
      snack.success(
        result.complete
            ? (result.matched
                  ? 'Recomputed: the figures now agree.'
                  : 'Recomputed: they still disagree by '
                        '${formatKilograms(result.variance.abs())}.')
            : 'Partial pass — the period is larger than one read. Run it '
                  'again to continue.',
      );
    } on OrgActionException catch (error) {
      snack.failure(error.message);
    } catch (_) {
      snack.failure('The recompute could not be run.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _UncheckedRow extends StatelessWidget {
  const _UncheckedRow({required this.row});

  final ReconciliationRow row;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '${row.orgId}  ·  ${periodLabel(row.periodId)}',
              style: theme.textTheme.bodySmall,
            ),
          ),
          Text(
            formatKilograms(row.incrementedMassMg),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Accuracy (EPR-17)
// ---------------------------------------------------------------------------

class _AccuracyTab extends ConsumerWidget {
  const _AccuracyTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(accuracySnapshotProvider);
    final reason = ref.watch(accuracyReasonProvider);
    final queue = ref.watch(accuracyQueueProvider);

    return ListView(
      padding: const EdgeInsets.all(AppTheme.gapMd),
      children: [
        snapshot.when(
          loading: () => const ContentLoading(label: 'Loading…'),
          error: (error, _) => ErrorRetry(
            error: error,
            onRetry: () => ref.invalidate(accuracySnapshotProvider),
          ),
          data: (data) => _PrecisionCard(snapshot: data),
        ),
        const SizedBox(height: AppTheme.gapLg),

        Text(
          'Matches waiting for a verdict',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: AppTheme.gapXs),
        Text(
          // The distinction that decides what a verdict MEANS.
          reason == 'accuracyAudit'
              ? 'These were attributed automatically and sampled anyway. Your '
                    'verdict measures how often Chokro is right.'
              : 'These were never attributed — they fell below the threshold. '
                    'Your verdict describes a near-miss, and does not enter '
                    'the precision figure.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: AppTheme.gapSm),
        _FilterChips(
          values: const ['accuracyAudit', 'lowConfidence'],
          selected: reason,
          label: (value) =>
              value == 'accuracyAudit' ? 'Standing audit' : 'Low confidence',
          onSelect: (value) =>
              ref.read(accuracyReasonProvider.notifier).select(value),
        ),
        const SizedBox(height: AppTheme.gapSm),

        queue.when(
          loading: () => const ContentLoading(label: 'Loading…'),
          error: (error, _) => ErrorRetry(
            error: error,
            onRetry: () => ref.invalidate(accuracyQueueProvider),
          ),
          data: (matches) {
            if (matches.isEmpty) {
              return const _EmptyQueue(
                icon: Icons.fact_check_outlined,
                title: 'Nothing waiting',
                message: 'Every sampled match in this queue has a verdict.',
              );
            }
            return Column(
              children: [
                for (final match in matches) ...[
                  _SampledMatchCard(match: match),
                  const SizedBox(height: AppTheme.gapSm),
                ],
              ],
            );
          },
        ),
      ],
    );
  }
}

/// The measured precision, or the stated reason there is none.
class _PrecisionCard extends StatelessWidget {
  const _PrecisionCard({required this.snapshot});

  final AccuracySnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final precision = snapshot.precision;

    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Measured recognition precision',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppTheme.gapXs),

            if (precision == null)
              // Never a zero, never a dash. This figure is published in report
              // methodology, which is the section a reader turns to in order
              // to decide how much to trust everything else.
              Text(
                snapshot.precisionAbsenceReason ??
                    'Not enough reviewed samples to state a figure.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              )
            else ...[
              Text(
                '${(precision * 100).toStringAsFixed(1)}%',
                style: theme.textTheme.headlineMedium,
              ),
              Text(
                '${snapshot.correct} of ${snapshot.judged} sampled matches '
                'confirmed correct, over ${snapshot.windowPeriods.length} '
                'periods.',
                style: theme.textTheme.bodySmall,
              ),
            ],

            if (snapshot.unclearShare != null && snapshot.unclearShare! > 0) ...[
              const SizedBox(height: AppTheme.gapSm),
              Text(
                // A high figure here says the PHOTOGRAPHS are the problem
                // rather than the model, which is a different fix.
                '${(snapshot.unclearShare! * 100).toStringAsFixed(0)}% of the '
                'sample could not be judged and is excluded from the figure.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],

            const SizedBox(height: AppTheme.gapSm),
            NoticeCard(
              icon: Icons.info_outline,
              tone: NoticeTone.info,
              message: snapshot.recallAbsenceReason ??
                  'Recall is not measurable from this sample.',
            ),
          ],
        ),
      ),
    );
  }
}

class _SampledMatchCard extends ConsumerStatefulWidget {
  const _SampledMatchCard({required this.match});

  final SampledMatch match;

  @override
  ConsumerState<_SampledMatchCard> createState() => _SampledMatchCardState();
}

class _SampledMatchCardState extends ConsumerState<_SampledMatchCard> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final match = widget.match;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${match.skuId}  ·  ${periodLabel(match.periodId)}',
              style: theme.textTheme.titleSmall,
            ),
            Text(
              '${match.confidenceTier} confidence'
              '${match.confidence == null ? '' : ' (${(match.confidence! * 100).round()}%)'}'
              '${match.units == null ? '' : '  ·  ${match.units} units'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: AppTheme.gapSm),
            Row(
              children: [
                for (final verdict in AccuracyVerdict.all) ...[
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : () => _review(verdict),
                      child: Text(AccuracyVerdict.label(verdict)),
                    ),
                  ),
                  if (verdict != AccuracyVerdict.all.last)
                    const SizedBox(width: AppTheme.gapSm),
                ],
              ],
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              // Said beside the button rather than left to be assumed. A
              // reviewer who believed "incorrect" removed the mass would be
              // wrong about what they just did.
              'A verdict records what you saw. It does not reverse the '
              'attribution — that is a separate act, with its own reason.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _review(String verdict) async {
    final snack = AppSnackBar.of(context);
    setState(() => _busy = true);
    try {
      await ref.read(adminOversightServiceProvider).reviewSampledMatch(
        confirmationId: widget.match.id,
        verdict: verdict,
      );
      ref.invalidate(accuracyQueueProvider);
      ref.invalidate(accuracySnapshotProvider);
      snack.success('Recorded as ${AccuracyVerdict.label(verdict).toLowerCase()}.');
    } on OrgActionException catch (error) {
      snack.failure(error.message);
    } catch (_) {
      snack.failure('The verdict could not be recorded.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

// ---------------------------------------------------------------------------
// Issuance (EPR-47)
// ---------------------------------------------------------------------------

class _IssuanceTab extends ConsumerWidget {
  const _IssuanceTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filter = ref.watch(issuanceFilterProvider);
    final register = ref.watch(issuanceRegisterProvider);

    return Column(
      children: [
        _FilterChips(
          values: const [null, 'issued', 'superseded', 'revoked'],
          selected: filter,
          label: (value) => value == null ? 'All' : _statusLabel(value),
          onSelect: (value) =>
              ref.read(issuanceFilterProvider.notifier).select(value),
        ),
        Expanded(
          child: register.when(
            loading: () => const ContentLoading(
              label: 'Loading…',
              slowHint: ContentLoading.serverWakingHint,
            ),
            error: (error, _) => ErrorRetry(
              error: error,
              onRetry: () => ref.invalidate(issuanceRegisterProvider),
            ),
            data: (data) {
              if (data.certificates.isEmpty) {
                return const _EmptyQueue(
                  icon: Icons.workspace_premium_outlined,
                  title: 'No certificates',
                  message: 'Nothing has been issued yet.',
                );
              }

              return ListView(
                padding: const EdgeInsets.all(AppTheme.gapMd),
                children: [
                  Text(
                    '${data.issued} standing  ·  ${data.superseded} superseded'
                    '  ·  ${data.revoked} revoked',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  if (data.truncated) ...[
                    const SizedBox(height: AppTheme.gapSm),
                    const NoticeCard(
                      icon: Icons.more_horiz,
                      tone: NoticeTone.warning,
                      title: 'This register is truncated',
                      message:
                          'More certificates exist than are shown. Narrow by '
                          'status or period before treating this list as the '
                          'full set — scoping a fault from a truncated '
                          'register is how one gets missed.',
                    ),
                  ],
                  const SizedBox(height: AppTheme.gapMd),
                  for (final certificate in data.certificates) ...[
                    _CertificateRow(certificate: certificate),
                    const SizedBox(height: AppTheme.gapSm),
                  ],
                ],
              );
            },
          ),
        ),
      ],
    );
  }

  static String _statusLabel(String value) => switch (value) {
    'issued' => 'Standing',
    'superseded' => 'Superseded',
    'revoked' => 'Revoked',
    _ => value,
  };
}

class _CertificateRow extends ConsumerStatefulWidget {
  const _CertificateRow({required this.certificate});

  final IssuedCertificate certificate;

  @override
  ConsumerState<_CertificateRow> createState() => _CertificateRowState();
}

class _CertificateRowState extends ConsumerState<_CertificateRow> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final certificate = widget.certificate;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    certificate.serial,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontFeatures: const [],
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                _CertificateStatusPill(status: certificate.status),
              ],
            ),
            Text(
              '${certificate.tradeName}  ·  ${periodLabel(certificate.periodId)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              '${formatKilograms(certificate.collectedMassMg)} collected'
              '${certificate.collectionRate == null ? ', no percentage stated' : ', ${(certificate.collectionRate! * 100).toStringAsFixed(1)}% of declared'}',
              style: theme.textTheme.bodySmall,
            ),

            if (certificate.withdrawalReason != null) ...[
              const SizedBox(height: AppTheme.gapSm),
              NoticeCard(
                icon: Icons.history,
                tone: NoticeTone.warning,
                message: certificate.withdrawalReason!,
              ),
            ],

            if (certificate.isStanding) ...[
              const SizedBox(height: AppTheme.gapSm),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _supersede,
                      child: const Text('Supersede the period'),
                    ),
                  ),
                  const SizedBox(width: AppTheme.gapSm),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _busy ? null : _revoke,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: theme.colorScheme.error,
                      ),
                      child: const Text('Revoke'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppTheme.gapXs),
              Text(
                // The distinction is not cosmetic, and an Admin choosing under
                // time pressure needs it in front of them.
                'Supersede says the figures have moved on. Revoke says the '
                'certificate should never have been relied on.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _supersede() async {
    final snack = AppSnackBar.of(context);
    final reason = await showRejectionReasonDialog(
      context,
      title: 'Why is this period being superseded?',
      hintText:
          'e.g. A recognition model fault affected September attribution.',
    );
    if (reason == null) return;

    await _run(snack, () async {
      final count = await ref.read(adminOversightServiceProvider).supersedeIssuance(
        orgId: widget.certificate.orgId,
        periodId: widget.certificate.periodId,
        reason: reason,
      );
      snack.success(
        '$count ${count == 1 ? 'certificate' : 'certificates'} superseded. '
        'Anyone verifying one is now told so.',
      );
    });
  }

  Future<void> _revoke() async {
    final snack = AppSnackBar.of(context);
    final reason = await showRejectionReasonDialog(
      context,
      title: 'Why is this certificate being revoked?',
      hintText: 'e.g. An accuracy audit invalidated the September batch.',
    );
    if (reason == null) return;

    await _run(snack, () async {
      await ref.read(adminOversightServiceProvider).revokeCertificate(
        serial: widget.certificate.serial,
        reason: reason,
      );
      snack.success('Certificate revoked.');
    });
  }

  Future<void> _run(AppSnackBar snack, Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
      ref.invalidate(issuanceRegisterProvider);
    } on OrgActionException catch (error) {
      snack.failure(error.message);
    } catch (_) {
      snack.failure('That could not be completed.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _CertificateStatusPill extends StatelessWidget {
  const _CertificateStatusPill({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground, label) = switch (status) {
      'issued' => (scheme.successContainer, scheme.onSuccessContainer, 'Standing'),
      'superseded' => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        'Superseded',
      ),
      _ => (scheme.errorContainer, scheme.onErrorContainer, 'Revoked'),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.gapSm, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: Theme.of(
          context,
        ).textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared pieces
// ---------------------------------------------------------------------------

class _FilterChips<T> extends StatelessWidget {
  const _FilterChips({
    required this.values,
    required this.selected,
    required this.label,
    required this.onSelect,
  });

  final List<T> values;
  final T selected;
  final String Function(T) label;
  final void Function(T) onSelect;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: AppTheme.gapMd),
      child: Row(
        children: [
          for (final value in values) ...[
            ChoiceChip(
              label: Text(label(value)),
              selected: value == selected,
              onSelected: (_) => onSelect(value),
            ),
            const SizedBox(width: AppTheme.gapSm),
          ],
        ],
      ),
    );
  }
}

/// An empty queue, said in a way that does not read as an all-clear.
class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapLg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.outline),
            const SizedBox(height: AppTheme.gapSm),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
