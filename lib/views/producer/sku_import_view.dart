import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/producer_workspace_controller.dart';
import '../../controllers/sku_controller.dart';
import '../../core/mass_math.dart';
import '../../core/sku_csv.dart';
import '../../core/theme.dart';
import '../../services/organization_service.dart';
import '../shared/app_shell.dart';
import '../shared/app_snackbar.dart';
import '../shared/notice_card.dart';

/// Bulk product import (EPR-10).
///
/// ## Paste, not upload
///
/// A file picker on Flutter web returns bytes the app must decode, and on a
/// handset it opens a document provider that a producer's spreadsheet is
/// unlikely to be in. A paste box works identically on both, needs no plugin,
/// and — the part that matters here — lets somebody fix a rejected row in place
/// and re-check without leaving the screen and re-exporting from Excel.
///
/// ## All-or-nothing, and the preview says which rows failed
///
/// Nothing is sent until every row parses. A partial import leaves a producer
/// with a catalogue it cannot reason about: half the products registered, half
/// rejected, and no way to tell which without diffing against the spreadsheet.
class SkuImportView extends ConsumerStatefulWidget {
  const SkuImportView({super.key});

  @override
  ConsumerState<SkuImportView> createState() => _SkuImportViewState();
}

class _SkuImportViewState extends ConsumerState<SkuImportView> {
  final _controller = TextEditingController();
  SkuCsvImport? _preview;
  bool _importing = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _check() {
    final workspace = ref.read(producerWorkspaceProvider).value;
    setState(() {
      _preview = parseSkuCsv(
        _controller.text,
        // The server takes the organisation from the caller's membership and
        // ignores whatever the file says; this is only so the preview can show
        // a complete draft.
        orgId: workspace?.organization?.id ?? '',
      );
    });
  }

  Future<void> _import() async {
    final preview = _preview;
    if (preview == null || !preview.canImport) return;

    final snack = AppSnackBar.of(context);
    setState(() => _importing = true);

    try {
      final created = await ref.read(skuActionsProvider).import(preview.skus);
      if (!mounted) return;
      snack.success(
        '$created ${created == 1 ? 'product' : 'products'} registered as drafts.',
      );
      context.pop();
    } on OrgActionException catch (error) {
      if (!mounted) return;
      setState(() => _importing = false);
      snack.failure(error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _importing = false);
      snack.failure('The import could not be completed.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = _preview;

    return AppShell(
      title: 'Import products',
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const NoticeCard(
                  icon: Icons.table_chart_outlined,
                  title: 'One row per product',
                  message:
                      'Export your catalogue as CSV, paste it below and check '
                      'it. Nothing is registered until every row reads cleanly '
                      '— a half-imported catalogue is worse than none.',
                ),

                const SizedBox(height: AppTheme.gapMd),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Accepted columns: ${skuCsvColumns.join(', ')}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: skuCsvTemplate()),
                        );
                        if (context.mounted) {
                          AppSnackBar.of(
                            context,
                          ).success('Template copied — paste it into a spreadsheet.');
                        }
                      },
                      icon: const Icon(Icons.copy_all_outlined, size: 18),
                      label: const Text('Copy template'),
                    ),
                  ],
                ),

                const SizedBox(height: AppTheme.gapSm),
                Text(
                  'Parts go in one cell as part:polymer:grams, separated by "|" '
                  '— for example body:pet:8.2|cap:pp:1.3|label:pet:0.5. They '
                  'must add up to declaredUnitMassG exactly.',
                  style: theme.textTheme.bodySmall,
                ),

                const SizedBox(height: AppTheme.gapMd),
                TextField(
                  controller: _controller,
                  maxLines: 12,
                  minLines: 6,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: 'Paste your CSV here',
                    alignLabelWithHint: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) {
                    if (_preview != null) setState(() => _preview = null);
                  },
                ),

                const SizedBox(height: AppTheme.gapMd),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _controller.text.trim().isEmpty ? null : _check,
                      icon: const Icon(Icons.fact_check_outlined),
                      label: const Text('Check'),
                    ),
                    const SizedBox(width: AppTheme.gapSm),
                    FilledButton.icon(
                      onPressed: preview?.canImport == true && !_importing
                          ? _import
                          : null,
                      icon: const Icon(Icons.download_outlined),
                      label: Text(
                        _importing
                            ? 'Importing…'
                            : preview == null
                            ? 'Import'
                            : 'Import ${preview.validCount}',
                      ),
                    ),
                  ],
                ),

                if (preview != null) ...[
                  const SizedBox(height: AppTheme.gapLg),
                  _PreviewResult(preview: preview),
                ],

                const SizedBox(height: AppTheme.gapXl),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PreviewResult extends StatelessWidget {
  const _PreviewResult({required this.preview});

  final SkuCsvImport preview;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (preview.fileProblems.isNotEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NoticeCard(
            icon: Icons.error_outline,
            tone: NoticeTone.error,
            title: 'The file itself could not be read',
            message: preview.fileProblems.join('\n'),
          ),
        ],
      );
    }

    if (preview.canImport) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          NoticeCard(
            icon: Icons.check_circle_outline,
            tone: NoticeTone.success,
            title:
                '${preview.validCount} '
                '${preview.validCount == 1 ? 'product reads' : 'products read'} cleanly',
            message:
                'They will be registered as drafts. Sample photographs cannot '
                'travel in a spreadsheet, so add two to six to each product '
                'before sending it to Chokro for verification.',
          ),
          const SizedBox(height: AppTheme.gapMd),
          Card(
            child: Column(
              children: [
                for (final sku in preview.skus.take(20))
                  ListTile(
                    dense: true,
                    title: Text(sku.name),
                    subtitle: Text(
                      '${sku.brand} · ${formatGrams(sku.declaredUnitMassMg)} · '
                      '${sku.components.length} parts',
                    ),
                  ),
                if (preview.skus.length > 20)
                  Padding(
                    padding: const EdgeInsets.all(AppTheme.gapSm),
                    child: Text(
                      'and ${preview.skus.length - 20} more',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NoticeCard(
          icon: Icons.error_outline,
          tone: NoticeTone.error,
          title:
              '${preview.invalidRows.length} of ${preview.rows.length} rows '
              'could not be read',
          message:
              'Nothing has been imported. Fix these rows and check again — the '
              'line numbers match your spreadsheet.',
        ),
        const SizedBox(height: AppTheme.gapMd),
        Card(
          child: Column(
            children: [
              for (final row in preview.invalidRows.take(30))
                ListTile(
                  dense: true,
                  leading: Text(
                    'Line ${row.lineNumber}',
                    style: theme.textTheme.labelMedium,
                  ),
                  title: Text(
                    row.problems.join('\n'),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              if (preview.invalidRows.length > 30)
                Padding(
                  padding: const EdgeInsets.all(AppTheme.gapSm),
                  child: Text(
                    'and ${preview.invalidRows.length - 30} more rows with '
                    'problems',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: AppTheme.gapSm),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(
                ClipboardData(text: preview.errorReport()),
              );
              if (context.mounted) {
                AppSnackBar.of(context).success('Error report copied.');
              }
            },
            icon: const Icon(Icons.copy_outlined, size: 18),
            label: const Text('Copy the error report'),
          ),
        ),
      ],
    );
  }
}
