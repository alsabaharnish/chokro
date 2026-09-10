import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/attribution_controller.dart';
import '../../controllers/compliance_controller.dart';
import '../../core/carbon_math.dart';
import '../../core/compliance_math.dart';
import '../../core/epr_period.dart';
import '../../core/mass_math.dart';
import '../../core/theme.dart';
import '../../models/producer_sdg_model.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';

/// This company's SDG alignment for one period (EPR-36, EPR-37).
///
/// ## No arithmetic here
///
/// EPR-36 asks for "a pure, testable derivation with no arithmetic in the
/// view", and every figure on this screen comes off [ProducerSdgSnapshot]
/// already computed. The view's job is to render each alignment *with its
/// boundary*, which is the part that actually matters: an SDG card without its
/// stated limit is the claim §11 forbids.
///
/// ## Why the boundary is not a footnote
///
/// The obvious layout puts the number large and the caveat small underneath, or
/// behind a tooltip. That is how a producer ends up publishing "12.5 t diverted
/// from landfill" from a card that said "collected, not recycled" in grey six
/// point type.
///
/// So the boundary sits directly under the signal, at body size, in every card,
/// and the model makes it a required field with no default so a sixth
/// alignment cannot be added without one.
class ProducerSdgView extends ConsumerWidget {
  const ProducerSdgView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snapshot = ref.watch(producerSdgProvider);
    final periodId = ref.watch(selectedPeriodProvider);
    final options = ref.watch(periodOptionsProvider);

    return AppShell(
      title: 'SDG alignment',
      child: snapshot.when(
        loading: () => const ContentLoading(
          label: 'Loading…',
          slowHint: ContentLoading.serverWakingHint,
        ),
        error: (error, _) => ErrorRetry(
          error: error,
          onRetry: () => ref.invalidate(producerSdgProvider),
        ),
        data: (data) => ListView(
          padding: const EdgeInsets.all(AppTheme.gapMd),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(AppTheme.gapMd),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: options.contains(periodId) ? periodId : null,
                      decoration: const InputDecoration(
                        labelText: 'Reporting period',
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
                        ref.read(selectedPeriodProvider.notifier).select(value);
                      },
                    ),
                    const SizedBox(height: AppTheme.gapSm),
                    Text(
                      'These are alignments with UN Sustainable Development '
                      'Goal targets, derived from what Chokro recorded. They '
                      'are not official UN indicators, and each card states '
                      'what it does not show.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: AppTheme.gapMd),

            if (!data.hasRecordedActivity)
              // One honest sentence rather than five cards of zeros, which
              // would read as five measured outcomes of nothing.
              NoticeCard(
                icon: Icons.inbox_outlined,
                tone: NoticeTone.info,
                title: 'Nothing recorded for ${periodLabel(data.periodId)}',
                message:
                    'No collection has been attributed to your products in '
                    'this period, so there is nothing to align. This is not a '
                    'statement that nothing was collected — only that nothing '
                    'was attributed to you.',
              )
            else ...[
              _MassHeadline(snapshot: data),
              const SizedBox(height: AppTheme.gapMd),

              // EPR-37, once and prominently, above the cards it qualifies —
              // rather than repeated in small type under each one, where it
              // becomes wallpaper.
              if (data.isSubstantiallyEstimated) ...[
                NoticeCard(
                  icon: Icons.help_outline,
                  tone: NoticeTone.warning,
                  title:
                      '${(data.estimatedShare * 100).toStringAsFixed(1)}% of '
                      'this mass rests on estimates',
                  message:
                      'That share came from medium-confidence matches rather '
                      'than confirmed ones. Every figure below that derives '
                      'from mass carries the same uncertainty, and a figure '
                      'published without it will be read as certain.',
                ),
                const SizedBox(height: AppTheme.gapMd),
              ],

              for (final alignment in data.alignments) ...[
                _AlignmentCard(alignment: alignment, snapshot: data),
                const SizedBox(height: AppTheme.gapMd),
              ],

              const _NotAdditive(),
            ],
            const SizedBox(height: AppTheme.gapXl),
          ],
        ),
      ),
    );
  }
}

class _MassHeadline extends StatelessWidget {
  const _MassHeadline({required this.snapshot});

  final ProducerSdgSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rate = snapshot.collectionRate;

    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Collected through Chokro in ${periodLabel(snapshot.periodId)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              formatKilograms(snapshot.totalMassMg),
              style: theme.textTheme.headlineMedium,
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              // Stated once. Goal 12 and Goal 11 are two lenses on this same
              // figure, and the cards below say so.
              //
              // The absence branch reads the REASON rather than assuming one.
              // Printing "no declaration has been filed" for a producer that
              // filed a nil declaration tells a company its paperwork is
              // missing when it is not — the same false statement EPR-42 is
              // about, made on the page most likely to be screenshotted.
              switch (rate.absence) {
                null => '${rate.percentLabel} of what you declared you placed '
                    'on the market.',
                RateAbsence.noDeclaration =>
                  'No collection percentage: no put-on-market declaration has '
                      'been filed for this period.',
                RateAbsence.declaredNil =>
                  'No collection percentage: your declaration states nil for '
                      'this period, and a share of nil would not mean '
                      'anything.',
                RateAbsence.categoryNotDeclared =>
                  'No collection percentage: your declaration does not cover '
                      'the categories collected this period.',
              },
              style: theme.textTheme.bodySmall,
            ),
            if (snapshot.reversedCount > 0) ...[
              const SizedBox(height: AppTheme.gapXs),
              Text(
                '${snapshot.reversedCount} '
                '${snapshot.reversedCount == 1 ? 'record was' : 'records were'} '
                'reversed after review and are excluded above.',
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
}

class _AlignmentCard extends StatelessWidget {
  const _AlignmentCard({required this.alignment, required this.snapshot});

  final ProducerSdgAlignment alignment;
  final ProducerSdgSnapshot snapshot;

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
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.gapSm,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'Goal ${alignment.goal} · Target ${alignment.target}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.gapSm),
            Text(alignment.title, style: theme.textTheme.titleMedium),
            const SizedBox(height: AppTheme.gapXs),
            Text(alignment.signal, style: theme.textTheme.bodyMedium),

            // The limit, at body size and directly under the signal. Not a
            // footnote, not grey, not behind a tooltip — that is how a card
            // saying "collected, not recycled" gets published as "recycled".
            const SizedBox(height: AppTheme.gapSm),
            Container(
              padding: const EdgeInsets.all(AppTheme.gapSm),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.info_outline,
                    size: 16,
                    color: theme.colorScheme.outline,
                  ),
                  const SizedBox(width: AppTheme.gapSm),
                  Expanded(
                    child: Text(
                      alignment.boundary,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),

            // EPR-37, on the cards whose figures actually carry the
            // uncertainty. A participation count is not more or less certain
            // because some mass was a medium-confidence match, and putting an
            // uncertainty figure on it would teach the reader to ignore the
            // ones that matter.
            if (alignment.carriesMass && snapshot.estimatedShare > 0) ...[
              const SizedBox(height: AppTheme.gapXs),
              Text(
                '${(snapshot.estimatedShare * 100).toStringAsFixed(1)}% of the '
                'mass behind this figure rests on medium-confidence matches.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.outline,
                ),
              ),
            ],

            // Goal 13's factor provenance, on the card that uses it (EPR-38).
            if (alignment.goal == 13) ...[
              const SizedBox(height: AppTheme.gapXs),
              _CarbonDetail(snapshot: snapshot),
            ],
          ],
        ),
      ),
    );
  }
}

class _CarbonDetail extends StatelessWidget {
  const _CarbonDetail({required this.snapshot});

  final ProducerSdgSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final carbon = snapshot.carbon;
    final kg = carbon.kgCo2eAvoided;

    // No figure at all, and the reason. EPR-39 is explicit that above the
    // uncertainty ceiling there is no carbon figure — not a wider range, not a
    // qualified one.
    if (kg == null) {
      return Text(
        switch (carbon.absence) {
          CarbonAbsence.tooUncertain =>
            'No avoided-emissions estimate is stated: too much of this '
                'period’s mass rests on estimates for a factor-based figure '
                'to mean anything.',
          CarbonAbsence.noFactor =>
            'No avoided-emissions estimate is stated: no cited emission '
                'factor is registered for this material.',
          CarbonAbsence.noMass =>
            'No avoided-emissions estimate is stated: there is no collected '
                'mass to convert.',
          _ => 'No avoided-emissions estimate is stated for this period.',
        },
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.outline,
        ),
      );
    }

    final factor = carbon.factor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          // `CarbonEstimate.label`, not a local `.round()`. Rounding here
          // printed "0 kg CO2e avoided" for any period under about half a
          // kilogram of avoided emissions — which on an SDG card reads as a
          // measured zero rather than as a small number.
          '${carbon.label} avoided (indicative)',
          style: theme.textTheme.titleSmall,
        ),
        if (factor != null) ...[
          const SizedBox(height: 2),
          // The version, pinned and shown, so the figure stays reproducible
          // when the registry is updated (EPR-38).
          Text(
            'Factor ${factor.version} · ${factor.systemBoundary} · '
            '${factor.geography}, ${factor.publicationYear}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
          for (final caveat in factor.caveats) ...[
            const SizedBox(height: 2),
            Text(
              '• $caveat',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _NotAdditive extends StatelessWidget {
  const _NotAdditive();

  @override
  Widget build(BuildContext context) {
    return const NoticeCard(
      icon: Icons.functions_outlined,
      tone: NoticeTone.info,
      title: 'These cards are not additive',
      message:
          'Goal 12 and Goal 11 read the same collected mass through two '
          'different lenses. Adding them together would count every gram '
          'twice. The mass is stated once at the top of this page.',
    );
  }
}
