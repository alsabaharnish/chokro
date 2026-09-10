import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:go_router/go_router.dart';

import '../../controllers/attribution_controller.dart';
import '../../controllers/compliance_controller.dart';
import '../../core/compliance_math.dart';
import '../../core/epr_categories.dart';
import '../../core/epr_claims.dart';
import '../../core/epr_period.dart';
import '../../core/mass_math.dart';
import '../../core/theme.dart';
import '../../models/epr_period_model.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';

/// What Chokro's evidence shows was collected, for one period (EPR-22, EPR-37).
///
/// ## The three things this card refuses to do
///
/// **It shows no percentage.** A collection percentage needs what the producer
/// placed on the market as its denominator, and only the producer knows that.
/// Until a put-on-market declaration is filed, the card says so in those words
/// (EPR-24) — it does not show a dash, a zero, or a target with nothing beside
/// it.
///
/// **It states how much of the figure is uncertain.** EPR-37: "A producer that
/// cannot see how much of its number is uncertain will publish the number as if
/// it were certain." The medium-confidence share is on the card, not behind a
/// tooltip.
///
/// **It performs no arithmetic.** Every figure comes from
/// [EprPeriodModel], which is a pure derivation over stored integers (QA-1).
/// The one thing computed here is which month to ask for.
class CollectedMassCard extends ConsumerWidget {
  const CollectedMassCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final period = ref.watch(selectedPeriodDataProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _PeriodSelector(),
            const SizedBox(height: AppTheme.gapMd),
            period.when(
              loading: () => const ContentLoading(label: 'Loading…'),
              error: (error, _) => ErrorRetry(
                error: error,
                onRetry: () => ref.invalidate(selectedPeriodDataProvider),
              ),
              data: (data) => _PeriodFigures(period: data),
            ),
          ],
        ),
      ),
    );
  }
}

class _PeriodSelector extends ConsumerWidget {
  const _PeriodSelector();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(selectedPeriodProvider);
    final options = ref.watch(periodOptionsProvider);
    final theme = Theme.of(context);

    return Row(
      children: [
        Expanded(
          child: Text(
            'Collected on your behalf',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        DropdownButton<String>(
          value: selected,
          underline: const SizedBox.shrink(),
          items: [
            for (final periodId in options)
              DropdownMenuItem(
                value: periodId,
                child: Text(periodLabel(periodId)),
              ),
          ],
          onChanged: (value) {
            if (value != null) {
              ref.read(selectedPeriodProvider.notifier).select(value);
            }
          },
        ),
      ],
    );
  }
}

class _PeriodFigures extends StatelessWidget {
  const _PeriodFigures({required this.period});

  final EprPeriodModel period;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!period.hasActivity) {
      return NoticeCard(
        icon: Icons.inbox_outlined,
        message:
            'No attributed collection recorded for ${period.label}. That means '
            'no registered product of yours was recognised at a bin in this '
            'period — not that none was collected.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The headline, from `totalMassMg`, which is summed from the category
        // breakdown so the two cannot disagree.
        Text(
          period.totalMassLabel,
          style: theme.textTheme.displaySmall?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          '${period.totalUnits} units across '
          '${period.attributionCount} '
          '${period.attributionCount == 1 ? 'record' : 'records'}, from '
          '${period.disposalCount} '
          '${period.disposalCount == 1 ? 'disposal' : 'disposals'}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),

        if (period.uncertainMassMg > 0) ...[
          const SizedBox(height: AppTheme.gapMd),
          NoticeCard(
            icon: Icons.help_outline,
            tone: NoticeTone.warning,
            title:
                '${(period.estimatedShare * 100).toStringAsFixed(1)}% of this '
                'figure is from uncertain matches',
            message:
                '${formatKilograms(period.uncertainMassMg)} was recognised with '
                'medium confidence and is included, flagged, and sampled for '
                'human review. Chokro states this share on every report; a '
                'figure published without it would read as more certain than '
                'it is.',
          ),
        ],

        if (period.categoryBreakdown.isNotEmpty) ...[
          const SizedBox(height: AppTheme.gapLg),
          Text(
            'By gazette category',
            style: theme.textTheme.labelLarge,
          ),
          const SizedBox(height: AppTheme.gapSm),
          for (final row in period.categoryBreakdown)
            _BreakdownRow(
              label: GazetteCategory.label(row.category),
              value: formatKilograms(row.massMg),
              detail: '${row.units} units',
            ),
        ],

        if (period.polymerBreakdown.isNotEmpty) ...[
          const SizedBox(height: AppTheme.gapMd),
          Text('By polymer', style: theme.textTheme.labelLarge),
          const SizedBox(height: AppTheme.gapXs),
          Text(
            'One recognised item contributes to more than one line — a bottle '
            'is a PET body, a PP cap and a PET label. The lines add up to the '
            'total above.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.gapSm),
          for (final row in period.polymerBreakdown)
            _BreakdownRow(
              label: PolymerType.label(row.polymer),
              value: formatKilograms(row.massMg),
            ),
        ],

        // Geography, or a stated reason there is none (SEC-3).
        //
        // The two cases must not render alike: an empty list means no
        // geography was recorded, and a withheld one means Chokro has it and
        // is not showing it. Rendering the second as the first would be a
        // false claim about Chokro's own evidence.
        if (period.districtSuppressed) ...[
          const SizedBox(height: AppTheme.gapMd),
          NoticeCard(
            icon: Icons.privacy_tip_outlined,
            title: 'Geography withheld for this period',
            message:
                'Chokro recorded where this material was collected, and is not '
                'showing it. A district breakdown built from '
                '${period.disposalCount} '
                '${period.disposalCount == 1 ? 'disposal' : 'disposals'} could '
                'identify the individual who made it. Geography appears once a '
                'period has at least ${period.kAnonymityFloor ?? 5} disposals.',
          ),
        ] else if (period.districtBreakdown.isNotEmpty) ...[
          const SizedBox(height: AppTheme.gapMd),
          Text('By district', style: theme.textTheme.labelLarge),
          const SizedBox(height: AppTheme.gapSm),
          for (final row in period.districtBreakdown.take(8))
            _BreakdownRow(
              label: row.district,
              value: formatKilograms(row.massMg),
            ),
        ],

        const SizedBox(height: AppTheme.gapLg),

        // EPR-24. Either the percentage, or the reason there is not one —
        // never a dash, never a zero, never a target with nothing beside it.
        const _CollectionPosition(),

        if (period.reversedCount > 0) ...[
          const SizedBox(height: AppTheme.gapSm),
          NoticeCard(
            icon: Icons.undo_outlined,
            tone: NoticeTone.warning,
            title:
                '${period.reversedCount} '
                '${period.reversedCount == 1 ? 'record was' : 'records were'} '
                'reversed',
            message:
                '${formatKilograms(period.reversedMassMg)} was removed from '
                'this period after review. Reversed records are kept, never '
                'deleted, so the change is auditable.',
          ),
        ],

        if (period.isReconciled) ...[
          const SizedBox(height: AppTheme.gapSm),
          NoticeCard(
            icon: period.hasRecomputeMismatch
                ? Icons.report_problem_outlined
                : Icons.verified_outlined,
            tone: period.hasRecomputeMismatch
                ? NoticeTone.error
                : NoticeTone.success,
            title: period.hasRecomputeMismatch
                ? 'This period did not reconcile'
                : 'Reconciled',
            message: period.hasRecomputeMismatch
                ? 'Rebuilding this period from its individual records produced '
                      'a different total from the running one. Chokro reports '
                      'the disagreement rather than quietly correcting it; a '
                      '3ZERO Admin is investigating.'
                : 'Rebuilding this period from its individual records produced '
                      'the same total as the running one.',
          ),
        ] else ...[
          const SizedBox(height: AppTheme.gapSm),
          Text(
            'This period has not been reconciled yet. Reconciliation rebuilds '
            'the total from every individual record and reports whether the '
            'two agree.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

class _BreakdownRow extends StatelessWidget {
  const _BreakdownRow({required this.label, required this.value, this.detail});

  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.gapXs),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          if (detail != null) ...[
            Text(
              detail!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: AppTheme.gapMd),
          ],
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// The collection percentage, or the stated reason there is none (EPR-24 to
/// EPR-26).
///
/// ## The whole of Phase D, in one widget
///
/// A collection percentage is a ratio between two figures with different
/// owners. The numerator is Chokro's, incremented as each attribution commits.
/// The denominator is the producer's own attested declaration. So the figure
/// exists exactly when the producer has filed one — and when it has not, the
/// honest rendering is a sentence, not a blank.
///
/// The three absences this distinguishes are genuinely different statements,
/// and collapsing any of them into "0%" would be a false one:
///
///   Nothing filed at all — Chokro has no denominator (EPR-24).
///   Filed, but silent on this category — different from declaring it nil,
///     and it usually means the declaration is incomplete (EPR-42).
///   Filed as nil while Chokro collected some — a discrepancy for a person to
///     look at, not a rate to publish.
///
/// ## Why a target can be missing while the percentage is not
///
/// EPR-26: no target unless the obligation year is established. A producer
/// whose obligation start date has not been recorded has a real percentage and
/// no threshold to compare it against, and printing "15%" on a guess would put
/// a compliance verdict on screen that Chokro has no basis for.
class _CollectionPosition extends ConsumerWidget {
  const _CollectionPosition();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(compliancePositionProvider);

    return position.when(
      loading: () => const ContentLoading(label: 'Loading…'),
      // A failed declaration read must not read as "no declaration filed" —
      // that is a claim about the producer's paperwork, and this is a network
      // fault. Said as what it is.
      error: (error, _) => NoticeCard(
        icon: Icons.percent_outlined,
        tone: NoticeTone.warning,
        title: 'The collection percentage could not be worked out',
        message:
            'Your declaration could not be read just now, so no percentage is '
            'shown. This is not a statement about your filing.',
        action: NoticeAction(
          label: 'Try again',
          onPressed: () => ref.invalidate(declarationProvider),
        ),
      ),
      data: (data) => _PositionBody(position: data),
    );
  }
}

class _PositionBody extends StatelessWidget {
  const _PositionBody({required this.position});

  final CompliancePosition position;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overall = position.overall;

    // No declaration: the stated absence, in the shared words, with the route
    // to fixing it. The sentence is the product here — EPR-24's point is that
    // a producer must be able to tell "we collected nothing" from "we have not
    // told Chokro our volume".
    if (overall.rate == null) {
      return NoticeCard(
        icon: Icons.percent_outlined,
        tone: NoticeTone.info,
        title: 'No percentage without a declaration',
        message: switch (overall.absence) {
          RateAbsence.noDeclaration =>
            EprAbsenceReasons.noPercentageWithoutDeclaration,
          RateAbsence.categoryNotDeclared =>
            'Your declaration for this period does not cover the categories '
                'Chokro collected. A category left out is not the same as one '
                'declared nil.',
          RateAbsence.declaredNil =>
            'Your declaration states nil for this period, but Chokro collected '
                'packaging attributed to you. A percentage against nil would '
                'not mean anything; the discrepancy is worth looking at.',
          _ => EprAbsenceReasons.noPercentageWithoutDeclaration,
        },
        action: NoticeAction(
          label: 'File a declaration',
          onPressed: () => context.go('/producer/declaration'),
        ),
      );
    }

    final target = position.applicableCollectionTarget;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.gapMd),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Collected as a share of what you declared',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: AppTheme.gapXs),
                Text(
                  overall.percentLabel!,
                  style: theme.textTheme.headlineMedium,
                ),
                const SizedBox(height: AppTheme.gapXs),
                Text(
                  '${formatKilograms(overall.collectedMassMg)} collected of '
                  '${formatKilograms(overall.declaredMassMg!)} declared.',
                  style: theme.textTheme.bodySmall,
                ),

                // EPR-26. Shown only when the obligation year is established;
                // otherwise nothing, rather than a placeholder.
                if (target != null) ...[
                  const SizedBox(height: AppTheme.gapSm),
                  Text(
                    switch (position.overallComparison) {
                      TargetComparison.atOrAboveTarget =>
                        'At or above the ${(target * 100).round()}% gazette '
                            'collection target for obligation year '
                            '${position.obligationYear}.',
                      TargetComparison.belowTarget =>
                        'Below the ${(target * 100).round()}% gazette '
                            'collection target for obligation year '
                            '${position.obligationYear}.',
                      TargetComparison.notComparable =>
                        'No gazette target applies to this period yet.',
                    },
                    style: theme.textTheme.bodySmall?.copyWith(
                      color:
                          position.overallComparison ==
                              TargetComparison.belowTarget
                          ? theme.colorScheme.error
                          : null,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // A discrepancy, not a rate. Chokro collected packaging in categories
        // the declaration does not cover, which means either the filing is
        // incomplete or a product is registered under the wrong category —
        // and both are things a person should look at (EPR-43).
        if (position.collectedButNotDeclared.isNotEmpty) ...[
          const SizedBox(height: AppTheme.gapSm),
          NoticeCard(
            icon: Icons.rule_outlined,
            tone: NoticeTone.warning,
            title: 'Collected in a category you did not declare',
            message:
                'Chokro attributed '
                '${position.collectedButNotDeclared.map(GazetteCategory.label).join(', ')} '
                'to you this period, but your declaration does not cover '
                '${position.collectedButNotDeclared.length == 1 ? 'it' : 'them'}. '
                'The percentage above therefore counts mass in its numerator '
                'that is missing from its denominator.',
            action: NoticeAction(
              label: 'Review the declaration',
              onPressed: () => context.go('/producer/declaration'),
            ),
          ),
        ],
      ],
    );
  }
}
