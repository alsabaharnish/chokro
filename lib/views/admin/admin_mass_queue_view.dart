import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/sku_controller.dart';
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

/// The mass-verification queue (EPR-42).
///
/// The specification calls this "the single most consequential screen in the
/// system: it is where a number that will appear on regulatory filings is
/// accepted or refused." Three things follow from that, and each is visible in
/// the layout below.
///
/// **The declared figure is shown, and it is shown as a claim.** An Admin
/// weighing a bottle should not be anchored on the producer's number, so it is
/// labelled "declared" and sits beside — not above — the field for what the
/// scale said.
///
/// **The tolerance is stated before the weighing, not after.** A form that
/// refuses a sample of four with "policy requires five" after the units are
/// back on the shelf has wasted a bench session.
///
/// **The measurement is what gets recorded.** The tolerance decides whether the
/// producer's declaration is flagged, not which number Chokro certifies.
class AdminMassQueueView extends ConsumerWidget {
  const AdminMassQueueView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(massQueueProvider);

    return AppShell(
      title: 'Mass verification',
      child: queue.when(
        loading: () => const ContentLoading(
          label: 'Loading the queue…',
          slowHint: ContentLoading.serverWakingHint,
        ),
        error: (error, _) => ErrorRetry(
          error: error,
          onRetry: () => ref.invalidate(massQueueProvider),
        ),
        data: (data) => data.isEmpty
            ? const ContentEmpty(
                icon: Icons.scale_outlined,
                title: 'Nothing waiting to be weighed',
                message:
                    'When a producer sends a product for verification it '
                    'appears here, oldest first.',
              )
            : _Queue(queue: data),
      ),
    );
  }
}

class _Queue extends StatelessWidget {
  const _Queue({required this.queue});

  final MassQueue queue;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(AppTheme.gapMd),
      children: [
        NoticeCard(
          icon: Icons.gavel_outlined,
          title: 'What is being decided here',
          message:
              'The measured mean becomes the unit mass every report for this '
              'producer uses. The declaration is checked against it, and a '
              'departure of more than '
              '${(queue.massToleranceFraction * 100).round()}% is recorded as a '
              'finding — it does not change which number is used. Weigh at '
              'least ${queue.massAuditSampleSize} units.',
        ),
        const SizedBox(height: AppTheme.gapMd),
        Text(
          'Oldest first (${queue.skus.length} waiting)',
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: AppTheme.gapSm),
        for (final sku in queue.skus) _QueueCard(sku: sku, queue: queue),
        const SizedBox(height: AppTheme.gap2Xl),
      ],
    );
  }
}

class _QueueCard extends ConsumerWidget {
  const _QueueCard({required this.sku, required this.queue});

  final ProducerSkuModel sku;
  final MassQueue queue;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              sku.name,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              '${sku.brand}'
              '${sku.gazetteCategory.isEmpty ? '' : ' · ${GazetteCategory.label(sku.gazetteCategory)}'}'
              '${sku.gtin == null ? '' : ' · GTIN ${sku.gtin}'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),

            const SizedBox(height: AppTheme.gapMd),

            // The declaration, labelled as a claim rather than a fact.
            Container(
              padding: const EdgeInsets.all(AppTheme.gapSm),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'The producer declares',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    formatGrams(sku.declaredUnitMassMg),
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: AppTheme.gapXs),
                  Text(
                    sku.components
                        .map(
                          (c) =>
                              '${c.part} ${PolymerType.label(c.polymer)} '
                              '${c.massLabel}',
                        )
                        .join('  ·  '),
                    style: theme.textTheme.bodySmall,
                  ),
                  if (sku.revision > 0) ...[
                    const SizedBox(height: AppTheme.gapXs),
                    Text(
                      'Currently verified at '
                      '${sku.reportableUnitMassMg == null ? "—" : formatGrams(sku.reportableUnitMassMg!)} '
                      '(revision ${sku.revision}). A new weighing opens '
                      'revision ${sku.revision + 1}; the current one is closed, '
                      'not replaced.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ],
                ],
              ),
            ),

            if (sku.sampleImageUrls.isNotEmpty) ...[
              const SizedBox(height: AppTheme.gapSm),
              SizedBox(
                height: 90,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  itemCount: sku.sampleImageUrls.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(width: AppTheme.gapSm),
                  itemBuilder: (context, index) => ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      sku.sampleImageUrls[index],
                      width: 90,
                      height: 90,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 90,
                        height: 90,
                        color: theme.colorScheme.surfaceContainerHighest,
                        child: const Icon(Icons.broken_image_outlined),
                      ),
                    ),
                  ),
                ),
              ),
            ],

            const SizedBox(height: AppTheme.gapMd),
            Wrap(
              spacing: AppTheme.gapSm,
              runSpacing: AppTheme.gapSm,
              children: [
                FilledButton.icon(
                  onPressed: () => _openWeighingForm(context, ref, sku, queue),
                  icon: const Icon(Icons.scale_outlined),
                  label: const Text('Record a weighing'),
                ),
                OutlinedButton(
                  onPressed: () => _openDocumentaryForm(context, ref, sku),
                  child: const Text('Verify from documentation'),
                ),
                TextButton(
                  onPressed: () => _openRejectForm(context, ref, sku),
                  child: const Text('Reject'),
                ),
                TextButton.icon(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => _AdminHistoryDialog(sku: sku),
                  ),
                  icon: const Icon(Icons.history_outlined, size: 18),
                  label: const Text('History'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

Future<void> _openWeighingForm(
  BuildContext context,
  WidgetRef ref,
  ProducerSkuModel sku,
  MassQueue queue,
) async {
  final formKey = GlobalKey<FormState>();
  final sampleSize = TextEditingController(
    text: '${queue.massAuditSampleSize}',
  );
  final meanGrams = TextEditingController();
  final stdDevGrams = TextEditingController();
  final location = TextEditingController();
  final scalePhoto = TextEditingController();
  final note = TextEditingController();
  var saving = false;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final meanMg = milligramsFromGrams(meanGrams.text);
        final withinTolerance = meanMg == null
            ? null
            : (meanMg - sku.declaredUnitMassMg).abs() <=
                  sku.declaredUnitMassMg * queue.massToleranceFraction;

        return AlertDialog(
          title: Text('Weigh ${sku.name}'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'Declared: ${formatGrams(sku.declaredUnitMassMg)}',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: AppTheme.gapMd),

                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: sampleSize,
                            keyboardType: TextInputType.number,
                            decoration: InputDecoration(
                              labelText: 'Units weighed',
                              helperText:
                                  'At least ${queue.massAuditSampleSize}',
                            ),
                            validator: (v) {
                              final n = int.tryParse(v?.trim() ?? '');
                              if (n == null || n < queue.massAuditSampleSize) {
                                return 'At least ${queue.massAuditSampleSize}.';
                              }
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(width: AppTheme.gapMd),
                        Expanded(
                          child: TextFormField(
                            controller: meanGrams,
                            keyboardType:
                                const TextInputType.numberWithOptions(
                                  decimal: true,
                                ),
                            decoration: const InputDecoration(
                              labelText: 'Measured mean (g)',
                            ),
                            onChanged: (_) => setState(() {}),
                            validator: (v) => milligramsFromGrams(v) == null
                                ? 'Record the measured mean.'
                                : null,
                          ),
                        ),
                      ],
                    ),

                    TextFormField(
                      controller: stdDevGrams,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Standard deviation (g, optional)',
                        helperText:
                            'A mean with no spread beside it says nothing about '
                            'whether the sample was consistent.',
                      ),
                    ),
                    TextFormField(
                      controller: location,
                      decoration: const InputDecoration(
                        labelText: 'Where it was weighed',
                      ),
                    ),
                    TextFormField(
                      controller: scalePhoto,
                      decoration: const InputDecoration(
                        labelText: 'Scale photograph URL',
                        helperText:
                            'What makes the figure checkable by somebody who '
                            'was not in the room.',
                      ),
                    ),
                    TextFormField(
                      controller: note,
                      maxLines: 2,
                      decoration: const InputDecoration(
                        labelText: 'Note (optional)',
                      ),
                    ),

                    if (meanMg != null) ...[
                      const SizedBox(height: AppTheme.gapMd),
                      NoticeCard(
                        icon: withinTolerance == true
                            ? Icons.check_circle_outline
                            : Icons.report_problem_outlined,
                        tone: withinTolerance == true
                            ? NoticeTone.success
                            : NoticeTone.warning,
                        message: withinTolerance == true
                            ? 'The declaration is within '
                                  '${(queue.massToleranceFraction * 100).round()}%. '
                                  '${formatGrams(meanMg)} will be recorded as the '
                                  'verified unit mass.'
                            : 'The declaration is outside '
                                  '${(queue.massToleranceFraction * 100).round()}% and '
                                  'will be flagged. ${formatGrams(meanMg)} will be '
                                  'recorded as the verified unit mass either way.',
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (formKey.currentState?.validate() != true) return;
                      setState(() => saving = true);
                      final snack = AppSnackBar.of(context);
                      final navigator = Navigator.of(context);
                      try {
                        final outcome = await ref
                            .read(massVerificationActionsProvider)
                            .recordAudit(
                              skuId: sku.id,
                              sampleSize:
                                  int.parse(sampleSize.text.trim()),
                              measuredMeanMg:
                                  milligramsFromGrams(meanGrams.text)!,
                              measuredStdDevMg: milligramsFromGrams(
                                stdDevGrams.text,
                              ),
                              weighingLocation: location.text.trim(),
                              scalePhotoUrl: scalePhoto.text.trim().isEmpty
                                  ? null
                                  : scalePhoto.text.trim(),
                              note: note.text.trim(),
                            );
                        navigator.pop();
                        snack.success(
                          'Verified at '
                          '${formatGrams(outcome.verifiedUnitMassMg)}, '
                          'revision ${outcome.revision}'
                          '${outcome.wasWithinTolerance ? '' : ' — declaration flagged'}.',
                        );
                      } on OrgActionException catch (error) {
                        setState(() => saving = false);
                        snack.failure(
                          error.needsReauthentication
                              ? 'Sign in again before verifying a mass.'
                              : error.message,
                        );
                      } catch (_) {
                        setState(() => saving = false);
                        snack.failure('The weighing could not be recorded.');
                      }
                    },
              child: Text(saving ? 'Recording…' : 'Record'),
            ),
          ],
        );
      },
    ),
  );

  sampleSize.dispose();
  meanGrams.dispose();
  stdDevGrams.dispose();
  location.dispose();
  scalePhoto.dispose();
  note.dispose();
}

/// EPR-11 cases 2 and 3 — documentary verification or an Admin override.
Future<void> _openDocumentaryForm(
  BuildContext context,
  WidgetRef ref,
  ProducerSkuModel sku,
) async {
  final formKey = GlobalKey<FormState>();
  final grams = TextEditingController();
  final note = TextEditingController();
  var reason = RevisionReason.documentary;
  var saving = false;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('Verify without weighing'),
        content: SizedBox(
          width: 480,
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const NoticeCard(
                  icon: Icons.info_outline,
                  message:
                      'For a product Chokro cannot obtain, or a correction. '
                      'The basis is recorded on the revision and appears in the '
                      'audit pack.',
                ),
                const SizedBox(height: AppTheme.gapMd),
                DropdownButtonFormField<String>(
                  initialValue: reason,
                  decoration: const InputDecoration(labelText: 'Basis'),
                  items: const [
                    DropdownMenuItem(
                      value: RevisionReason.documentary,
                      child: Text('Manufacturer data sheet or specification'),
                    ),
                    DropdownMenuItem(
                      value: RevisionReason.adminOverride,
                      child: Text('Admin override'),
                    ),
                  ],
                  onChanged: (v) => setState(() => reason = v ?? reason),
                ),
                TextFormField(
                  controller: grams,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Verified unit mass (g)',
                    helperText:
                        'Declared: ${formatGrams(sku.declaredUnitMassMg)}',
                  ),
                  validator: (v) => milligramsFromGrams(v) == null
                      ? 'Enter a mass between ${formatGrams(minUnitMassMg)} '
                            'and ${formatGrams(maxUnitMassMg)}.'
                      : null,
                ),
                TextFormField(
                  controller: note,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'The basis, in your own words',
                    helperText:
                        'A data sheet reference, or why the override was made. '
                        'A figure set by hand with no recorded basis is what a '
                        'data verification asks about.',
                  ),
                  validator: (v) => (v == null || v.trim().length < 10)
                      ? 'Record the basis — at least a sentence.'
                      : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    if (formKey.currentState?.validate() != true) return;
                    setState(() => saving = true);
                    final snack = AppSnackBar.of(context);
                    final navigator = Navigator.of(context);
                    try {
                      await ref
                          .read(massVerificationActionsProvider)
                          .setVerifiedMass(
                            skuId: sku.id,
                            verifiedUnitMassMg:
                                milligramsFromGrams(grams.text)!,
                            reason: reason,
                            note: note.text.trim(),
                          );
                      navigator.pop();
                      snack.success('Verified mass recorded.');
                    } on OrgActionException catch (error) {
                      setState(() => saving = false);
                      snack.failure(error.message);
                    } catch (_) {
                      setState(() => saving = false);
                      snack.failure('That could not be recorded.');
                    }
                  },
            child: Text(saving ? 'Saving…' : 'Record'),
          ),
        ],
      ),
    ),
  );

  grams.dispose();
  note.dispose();
}

Future<void> _openRejectForm(
  BuildContext context,
  WidgetRef ref,
  ProducerSkuModel sku,
) async {
  final controller = TextEditingController();
  var saving = false;

  await showDialog<void>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('Reject ${sku.name}'),
        content: SizedBox(
          width: 440,
          child: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'What is wrong with this declaration?',
              helperText:
                  'Shown to the producer, who can then correct and resubmit.',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    final reason = controller.text.trim();
                    final snack = AppSnackBar.of(context);
                    if (reason.length < 5) {
                      snack.failure('Give a reason the producer can act on.');
                      return;
                    }
                    setState(() => saving = true);
                    final navigator = Navigator.of(context);
                    try {
                      await ref
                          .read(massVerificationActionsProvider)
                          .reject(skuId: sku.id, reason: reason);
                      navigator.pop();
                      snack.success('Rejected, with your reason recorded.');
                    } on OrgActionException catch (error) {
                      setState(() => saving = false);
                      snack.failure(error.message);
                    } catch (_) {
                      setState(() => saving = false);
                      snack.failure('That could not be saved.');
                    }
                  },
            child: Text(saving ? 'Saving…' : 'Reject'),
          ),
        ],
      ),
    ),
  );

  controller.dispose();
}

class _AdminHistoryDialog extends ConsumerWidget {
  const _AdminHistoryDialog({required this.sku});

  final ProducerSkuModel sku;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final history = ref.watch(adminSkuHistoryProvider(sku.id));

    return AlertDialog(
      title: Text('${sku.name} — history'),
      content: SizedBox(
        width: 560,
        height: 400,
        child: history.when(
          loading: () => const ContentLoading(label: 'Loading…'),
          error: (error, _) => ErrorRetry(error: error),
          data: (data) => data.isEmpty
              ? const Center(child: Text('No verification history yet.'))
              : ListView(
                  children: [
                    for (final revision in data.revisions)
                      ListTile(
                        dense: true,
                        leading: CircleAvatar(
                          radius: 14,
                          child: Text('${revision.revision}'),
                        ),
                        title: Text(revision.verifiedLabel ?? 'Not verified'),
                        subtitle: Text(
                          [
                            RevisionReason.label(revision.reason),
                            'declared ${revision.declaredLabel}',
                            if (revision.varianceFromDeclared != null)
                              '${(revision.varianceFromDeclared! * 100).toStringAsFixed(1)}% from declared',
                            if (revision.note != null) revision.note!,
                          ].join(' · '),
                        ),
                      ),
                    for (final audit in data.audits)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.scale_outlined),
                        title: Text(
                          '${audit.measuredMeanLabel} mean, n = ${audit.sampleSize}',
                        ),
                        subtitle: Text(
                          [
                            MassAuditVerdict.label(audit.verdict),
                            'declared ${audit.declaredLabel}',
                            if (audit.toleranceFraction != null)
                              'judged at ±${(audit.toleranceFraction! * 100).round()}%',
                            if (audit.weighingLocation.isNotEmpty)
                              audit.weighingLocation,
                          ].join(' · '),
                        ),
                      ),
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
