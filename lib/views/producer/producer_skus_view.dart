import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/producer_workspace_controller.dart';
import '../../controllers/sku_controller.dart';
import '../../core/constants.dart';
import '../../core/epr_categories.dart';
import '../../core/mass_math.dart';
import '../../core/theme.dart';
import '../../models/producer_sku_model.dart';
import '../../models/sku_revision_model.dart';
import '../../services/organization_service.dart';
import '../../services/producer_sku_service.dart';
import '../shared/app_shell.dart';
import '../shared/app_snackbar.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';
import 'sku_editor_dialog.dart';

/// The producer's product registry (EPR-9).
///
/// ## The number this screen leads with
///
/// Not "40 products". **Verified-mass coverage** — what share of the registry
/// has a mass a report could actually use. A catalogue of forty products with
/// three verified masses can report on three, and a screen that led with the
/// forty would be telling a compliance officer they are twelve times better
/// covered than they are.
class ProducerSkusView extends ConsumerWidget {
  const ProducerSkusView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final workspace = ref.watch(producerWorkspaceProvider);
    final catalogue = ref.watch(skuCatalogueProvider);

    return AppShell(
      title: 'Products',
      floatingActionButton: workspace.maybeWhen(
        data: (w) => w.can(OrgRoles.reporter) && !(w.organization?.isReadOnly ?? true)
            ? FloatingActionButton.extended(
                onPressed: () => _openEditor(context, ref, null),
                icon: const Icon(Icons.add),
                label: const Text('Add product'),
              )
            : null,
        orElse: () => null,
      ),
      child: workspace.when(
        loading: () => const ContentLoading(
          label: 'Loading…',
          slowHint: ContentLoading.serverWakingHint,
        ),
        error: (error, _) => ErrorRetry(
          error: error,
          onRetry: () => ref.invalidate(producerWorkspaceProvider),
        ),
        data: (w) {
          if (!w.isReady) {
            return const ContentEmpty(
              icon: Icons.no_accounts_outlined,
              title: 'No access',
              message:
                  'Open the workspace first — it will tell you what is '
                  'outstanding on this account.',
            );
          }

          return catalogue.when(
            loading: () => const ContentLoading(label: 'Loading products…'),
            error: (error, _) => ErrorRetry(
              error: error,
              onRetry: () => ref.invalidate(skuCatalogueProvider),
            ),
            data: (data) => _Catalogue(
              catalogue: data,
              canEdit:
                  w.can(OrgRoles.reporter) &&
                  !(w.organization?.isReadOnly ?? true),
            ),
          );
        },
      ),
    );
  }
}

class _Catalogue extends ConsumerWidget {
  const _Catalogue({required this.catalogue, required this.canEdit});

  final SkuCatalogue catalogue;
  final bool canEdit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (catalogue.isEmpty) {
      return ContentEmpty(
        icon: Icons.inventory_2_outlined,
        title: 'No products registered',
        message:
            'Register the products your company places on the market. Chokro '
            'verifies each declared unit mass by weighing, and only a verified '
            'mass is used for reporting.',
        actionLabel: canEdit ? 'Add your first product' : null,
        onAction: canEdit ? () => _openEditor(context, ref, null) : null,
      );
    }

    return ListView(
      padding: const EdgeInsets.all(AppTheme.gapMd),
      children: [
        _CoverageCard(catalogue: catalogue),

        if (canEdit) ...[
          const SizedBox(height: AppTheme.gapSm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => context.push('/producer/skus/import'),
              icon: const Icon(Icons.upload_file_outlined),
              label: const Text('Import from a spreadsheet'),
            ),
          ),
        ],

        if (catalogue.awaitingVerification.isNotEmpty) ...[
          const SizedBox(height: AppTheme.gapLg),
          _Heading(
            'With Chokro for verification',
            count: catalogue.awaitingVerification.length,
          ),
          for (final sku in catalogue.awaitingVerification)
            _SkuCard(sku: sku, canEdit: canEdit, catalogue: catalogue),
        ],

        if (catalogue.verified.isNotEmpty) ...[
          const SizedBox(height: AppTheme.gapLg),
          _Heading('Verified', count: catalogue.verified.length),
          for (final sku in catalogue.verified)
            _SkuCard(sku: sku, canEdit: canEdit, catalogue: catalogue),
        ],

        if (catalogue.drafts.isNotEmpty) ...[
          const SizedBox(height: AppTheme.gapLg),
          _Heading('Not yet submitted', count: catalogue.drafts.length),
          for (final sku in catalogue.drafts)
            _SkuCard(sku: sku, canEdit: canEdit, catalogue: catalogue),
        ],

        const SizedBox(height: AppTheme.gap2Xl),
      ],
    );
  }
}

/// Verified-mass coverage, and what its absence means.
class _CoverageCard extends StatelessWidget {
  const _CoverageCard({required this.catalogue});

  final SkuCatalogue catalogue;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final verified = catalogue.verified.length;
    final total = catalogue.skus.length;

    return Card(
      color: theme.colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Verified-mass coverage',
              style: theme.textTheme.labelMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              '$verified of $total',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              verified == total
                  ? 'Every registered product has a Chokro-verified unit mass.'
                  : 'Only a Chokro-verified unit mass is used for reporting. '
                        'Packaging Chokro has not weighed cannot appear in a '
                        'collected figure.',
              style: theme.textTheme.bodySmall,
            ),

            if (catalogue.revalidationDue.isNotEmpty) ...[
              const SizedBox(height: AppTheme.gapMd),
              NoticeCard(
                icon: Icons.update_outlined,
                tone: NoticeTone.warning,
                title:
                    '${catalogue.revalidationDue.length} '
                    '${catalogue.revalidationDue.length == 1 ? 'product is' : 'products are'} '
                    'due for re-weighing',
                message:
                    'A verified mass older than '
                    '${catalogue.massRevalidationMonths ?? 12} months is queued for '
                    're-sampling. Packaging is light-weighted constantly — a '
                    'bottle made this year usually weighs less than one made two '
                    'years ago.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SkuCard extends ConsumerWidget {
  const _SkuCard({
    required this.sku,
    required this.canEdit,
    required this.catalogue,
  });

  final ProducerSkuModel sku;
  final bool canEdit;
  final SkuCatalogue catalogue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dueForReweigh = catalogue.revalidationDue.contains(sku.id);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        sku.name,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        sku.brand,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Chip(
                  label: Text(MassStatus.label(sku.massStatus)),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),

            const SizedBox(height: AppTheme.gapSm),

            // The two masses, side by side and clearly labelled. A producer
            // has to be able to see at a glance which number Chokro reports
            // with — that is the whole of §6.2 on one line.
            Wrap(
              spacing: AppTheme.gapLg,
              runSpacing: AppTheme.gapXs,
              children: [
                _MassFact(
                  label: 'You declared',
                  value: formatGrams(sku.declaredUnitMassMg),
                  emphasised: false,
                ),
                _MassFact(
                  label: 'Chokro verified',
                  value: sku.reportableUnitMassMg == null
                      ? null
                      : formatGrams(sku.reportableUnitMassMg!),
                  missing: 'Not yet',
                  emphasised: true,
                ),
                if (sku.gazetteCategory.isNotEmpty)
                  _MassFact(
                    label: 'Category',
                    value: GazetteCategory.shortLabel(sku.gazetteCategory),
                    emphasised: false,
                  ),
                if (sku.revision > 0)
                  _MassFact(
                    label: 'Revision',
                    value: '${sku.revision}',
                    emphasised: false,
                  ),
              ],
            ),

            if (sku.massStatus == MassStatus.rejected &&
                sku.rejectionReason != null) ...[
              const SizedBox(height: AppTheme.gapSm),
              NoticeCard(
                icon: Icons.error_outline,
                tone: NoticeTone.error,
                title: 'Chokro did not accept this declaration',
                message: sku.rejectionReason!,
              ),
            ],

            if (dueForReweigh) ...[
              const SizedBox(height: AppTheme.gapSm),
              const NoticeCard(
                icon: Icons.update_outlined,
                tone: NoticeTone.warning,
                message:
                    'This verified mass is older than the re-verification '
                    'interval. Chokro will re-weigh it.',
              ),
            ],

            const SizedBox(height: AppTheme.gapSm),
            Wrap(
              spacing: AppTheme.gapSm,
              children: [
                TextButton.icon(
                  onPressed: () => _openHistory(context, sku),
                  icon: const Icon(Icons.history_outlined, size: 18),
                  label: const Text('History'),
                ),
                if (canEdit && sku.massStatus != MassStatus.submitted)
                  TextButton(
                    onPressed: () => _openEditor(context, ref, sku),
                    child: const Text('Edit'),
                  ),
                if (canEdit &&
                    sku.massStatus != MassStatus.submitted &&
                    !sku.hasVerifiedMass)
                  FilledButton.tonal(
                    onPressed: sku.canSubmit
                        ? () => _submit(context, ref, sku)
                        : null,
                    child: Text(
                      sku.canSubmit
                          ? 'Send to Chokro'
                          : 'Not ready to send',
                    ),
                  ),
              ],
            ),

            if (canEdit && !sku.canSubmit && !sku.hasVerifiedMass) ...[
              const SizedBox(height: AppTheme.gapXs),
              // Every reason at once. A form that reveals one rule at a time
              // makes somebody guess their way through the requirements.
              for (final problem in sku.submissionProblems)
                Text(
                  '•  $problem',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _submit(
    BuildContext context,
    WidgetRef ref,
    ProducerSkuModel sku,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Send to Chokro for verification?'),
        content: Text(
          'Chokro will weigh at least '
          '${catalogue.massAuditSampleSize ?? 5} units of "${sku.name}" and '
          'record the sample, the scale reading and the operator.\n\n'
          'The measured mean becomes the verified unit mass — the figure every '
          'report uses. Your declared '
          '${formatGrams(sku.declaredUnitMassMg)} is checked against it, and a '
          'departure of more than '
          '${((catalogue.massToleranceFraction ?? 0.10) * 100).round()}% is '
          'recorded as a finding.\n\n'
          'This product is locked while Chokro has it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    final snack = AppSnackBar.of(context);
    try {
      await ref.read(skuActionsProvider).submit(sku.id);
      snack.success('Sent to Chokro.');
    } on OrgActionException catch (error) {
      snack.failure(error.message);
    } catch (_) {
      snack.failure('That could not be sent.');
    }
  }
}

class _MassFact extends StatelessWidget {
  const _MassFact({
    required this.label,
    required this.value,
    required this.emphasised,
    this.missing,
  });

  final String label;

  /// Null means the figure does not exist. It is said so, in words — never
  /// rendered as a dash or a zero that could be read as a measurement.
  final String? value;

  final String? missing;
  final bool emphasised;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final known = value != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Text(
          known ? value! : (missing ?? 'Not recorded'),
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: emphasised && known ? FontWeight.bold : FontWeight.normal,
            color: known
                ? (emphasised ? theme.colorScheme.primary : null)
                : theme.colorScheme.onSurfaceVariant,
            fontStyle: known ? null : FontStyle.italic,
          ),
        ),
      ],
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.label, {required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppTheme.gapSm),
    child: Text(
      '$label ($count)',
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
    ),
  );
}

Future<void> _openHistory(BuildContext context, ProducerSkuModel sku) =>
    showDialog<void>(
      context: context,
      builder: (context) => _HistoryDialog(sku: sku),
    );

/// A product's revision history (EPR-12).
///
/// The point of showing it to a producer: this is why last quarter's figures
/// did not change when the bottle was re-weighed this quarter.
class _HistoryDialog extends ConsumerWidget {
  const _HistoryDialog({required this.sku});

  final ProducerSkuModel sku;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(skuHistoryProvider(sku.id));
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text('${sku.name} — mass history'),
      content: SizedBox(
        width: 560,
        height: 420,
        child: history.when(
          loading: () => const ContentLoading(label: 'Loading…'),
          error: (error, _) => ErrorRetry(error: error),
          data: (data) => data.isEmpty
              ? const Center(
                  child: Text('No mass has been verified for this product yet.'),
                )
              : ListView(
                  children: [
                    const NoticeCard(
                      icon: Icons.lock_clock_outlined,
                      message:
                          'A verified mass is never edited. A change closes the '
                          'standing revision and opens the next, so a report '
                          'issued earlier stays true.',
                    ),
                    const SizedBox(height: AppTheme.gapMd),
                    for (final revision in data.revisions)
                      ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 14,
                          child: Text(
                            '${revision.revision}',
                            style: theme.textTheme.labelSmall,
                          ),
                        ),
                        title: Text(
                          revision.verifiedLabel ?? 'No verified mass',
                          style: theme.textTheme.titleSmall,
                        ),
                        subtitle: Text(
                          [
                            RevisionReason.label(revision.reason),
                            'declared ${revision.declaredLabel}',
                            if (revision.activeFrom != null)
                              'from ${_shortDate(revision.activeFrom!)}',
                            if (revision.activeTo != null)
                              'to ${_shortDate(revision.activeTo!)}'
                            else
                              'current',
                          ].join(' · '),
                        ),
                      ),
                    if (data.audits.isNotEmpty) ...[
                      const Divider(),
                      Text(
                        'Weighings',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      for (final audit in data.audits)
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.scale_outlined),
                          title: Text(
                            '${audit.measuredMeanLabel} mean, '
                            'n = ${audit.sampleSize}',
                          ),
                          subtitle: Text(
                            [
                              'declared ${audit.declaredLabel}',
                              MassAuditVerdict.label(audit.verdict),
                              if (audit.measuredStdDevMg != null)
                                'SD ${formatGrams(audit.measuredStdDevMg!)}',
                            ].join(' · '),
                          ),
                        ),
                    ],
                  ],
                ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

String _shortDate(DateTime value) {
  final local = value.toLocal();
  return '${local.day}/${local.month}/${local.year}';
}

/// The product editor, reached from the list and from the empty state.
Future<void> _openEditor(
  BuildContext context,
  WidgetRef ref,
  ProducerSkuModel? existing,
) => showDialog<void>(
  context: context,
  builder: (context) => SkuEditorDialog(existing: existing),
);
