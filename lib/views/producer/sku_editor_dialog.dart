import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/sku_controller.dart';
import '../../core/epr_categories.dart';
import '../../core/mass_math.dart';
import '../../core/theme.dart';
import '../../models/producer_sku_model.dart';
import '../../services/organization_service.dart';
import '../shared/app_snackbar.dart';
import '../shared/notice_card.dart';

/// Registering a product and its declared unit mass (EPR-9).
///
/// ## Why the component breakdown is not optional, and why the form says so
///
/// A 250 ml PET bottle is a PET body, a PP cap and often a PET or PVC label
/// sleeve — three polymers and three gazette-relevant masses in one object the
/// recognition model will see as a single bottle. Reporting category totals
/// from one blended figure is wrong in a way a DoE audit would find.
///
/// So the parts are entered individually, and the form shows the running sum
/// against the declared unit mass as it is typed. That is not a nicety: the two
/// must match exactly, on integers, and a producer who discovers a 0.3 g
/// discrepancy at submission time has to go back through every row to find it.
class SkuEditorDialog extends ConsumerStatefulWidget {
  const SkuEditorDialog({super.key, this.existing});

  final ProducerSkuModel? existing;

  @override
  ConsumerState<SkuEditorDialog> createState() => _SkuEditorDialogState();
}

class _SkuEditorDialogState extends ConsumerState<SkuEditorDialog> {
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _name;
  late final TextEditingController _brand;
  late final TextEditingController _gtin;
  late final TextEditingController _volume;
  late final TextEditingController _declaredMass;
  late final TextEditingController _hints;
  late final TextEditingController _images;

  late String _category;
  late String _polymer;
  late List<_ComponentDraft> _components;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;

    _name = TextEditingController(text: e?.name ?? '');
    _brand = TextEditingController(text: e?.brand ?? '');
    _gtin = TextEditingController(text: e?.gtin ?? '');
    _volume = TextEditingController(text: e?.volumeMl?.toString() ?? '');
    _declaredMass = TextEditingController(
      text: e == null || e.declaredUnitMassMg == 0
          ? ''
          : (e.declaredUnitMassMg / mgPerGram).toString(),
    );
    _hints = TextEditingController(text: e?.recognitionHints.join(', ') ?? '');
    _images = TextEditingController(text: e?.sampleImageUrls.join('\n') ?? '');

    _category = e != null && GazetteCategory.isValid(e.gazetteCategory)
        ? e.gazetteCategory
        : GazetteCategory.rigid;
    _polymer = e != null && PolymerType.isValid(e.polymer)
        ? e.polymer
        : PolymerType.pet;

    _components = e != null && e.components.isNotEmpty
        ? e.components
              .map(
                (c) => _ComponentDraft(
                  part: c.part,
                  polymer: c.polymer,
                  grams: (c.massMg / mgPerGram).toString(),
                ),
              )
              .toList()
        : [_ComponentDraft(part: 'body', polymer: PolymerType.pet, grams: '')];
  }

  @override
  void dispose() {
    _name.dispose();
    _brand.dispose();
    _gtin.dispose();
    _volume.dispose();
    _declaredMass.dispose();
    _hints.dispose();
    _images.dispose();
    super.dispose();
  }

  /// The running component sum, in integer milligrams.
  ///
  /// Null when any row is unreadable — deliberately null rather than a partial
  /// sum, because a total over three of four rows shown beside a declared mass
  /// would read as a discrepancy that is really a typo.
  int? get _componentSumMg {
    var total = 0;
    for (final component in _components) {
      final mg = milligramsFromGrams(component.grams);
      if (mg == null) return null;
      total += mg;
    }
    return _components.isEmpty ? null : total;
  }

  int? get _declaredMg => milligramsFromGrams(_declaredMass.text);

  bool get _balances {
    final sum = _componentSumMg;
    final declared = _declaredMg;
    return sum != null && declared != null && sum == declared;
  }

  ProducerSkuModel? _build() {
    final declared = _declaredMg;
    if (declared == null) return null;

    final components = <SkuComponent>[];
    for (final draft in _components) {
      final mg = milligramsFromGrams(draft.grams);
      if (mg == null || draft.part.trim().isEmpty) return null;
      components.add(
        SkuComponent(part: draft.part.trim(), polymer: draft.polymer, massMg: mg),
      );
    }

    final existing = widget.existing;

    return ProducerSkuModel(
      id: existing?.id ?? '',
      orgId: existing?.orgId ?? '',
      name: _name.text.trim(),
      brand: _brand.text.trim(),
      gtin: _gtin.text.trim().isEmpty ? null : _gtin.text.trim(),
      volumeMl: int.tryParse(_volume.text.trim()),
      gazetteCategory: _category,
      polymer: _polymer,
      declaredUnitMassMg: declared,
      components: components,
      sampleImageUrls: _images.text
          .split(RegExp(r'[\n,]'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .take(6)
          .toList(),
      recognitionHints: _hints.text
          .split(',')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .take(12)
          .toList(),
      // Server-owned. Carried through from the stored document so the model is
      // complete for display; `toDraftJson` omits every one of them.
      massStatus: existing?.massStatus ?? MassStatus.draft,
      verifiedUnitMassMg: existing?.verifiedUnitMassMg,
      revision: existing?.revision ?? 0,
      status: existing?.status ?? SkuStatus.draft,
    );
  }

  Future<void> _save() async {
    if (_formKey.currentState?.validate() != true) return;

    final sku = _build();
    if (sku == null) {
      AppSnackBar.of(context).failure('Check the masses — one is unreadable.');
      return;
    }

    final snack = AppSnackBar.of(context);
    final navigator = Navigator.of(context);
    setState(() => _saving = true);

    try {
      await ref.read(skuActionsProvider).save(sku);
      navigator.pop();
      snack.success('Product saved.');
    } on OrgActionException catch (error) {
      setState(() => _saving = false);
      snack.failure(
        error.needsReauthentication
            ? 'Sign in again before saving a product.'
            : error.message,
      );
    } catch (_) {
      setState(() => _saving = false);
      snack.failure('The product could not be saved.');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sumMg = _componentSumMg;
    final declaredMg = _declaredMg;

    return AlertDialog(
      title: Text(
        widget.existing == null ? 'Register a product' : 'Edit product',
      ),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Product name',
                    hintText: 'Coca-Cola 250 ml PET bottle',
                  ),
                  validator: (v) => (v == null || v.trim().length < 3)
                      ? 'Give the product a name.'
                      : null,
                ),
                TextFormField(
                  controller: _brand,
                  decoration: const InputDecoration(
                    labelText: 'Brand',
                    helperText:
                        'The name on the packaging. Chokro checks brand '
                        'ownership across companies.',
                  ),
                  validator: (v) => (v == null || v.trim().length < 2)
                      ? 'Name the brand.'
                      : null,
                ),

                const SizedBox(height: AppTheme.gapMd),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _category,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Gazette category',
                        ),
                        items: [
                          for (final value in GazetteCategory.all)
                            DropdownMenuItem(
                              value: value,
                              child: Text(
                                GazetteCategory.shortLabel(value),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _category = v ?? _category),
                      ),
                    ),
                    const SizedBox(width: AppTheme.gapMd),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _polymer,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Main polymer',
                        ),
                        items: [
                          for (final value in PolymerType.all)
                            DropdownMenuItem(
                              value: value,
                              child: Text(
                                PolymerType.label(value),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                        onChanged: (v) => setState(() => _polymer = v ?? _polymer),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: AppTheme.gapXs),
                Text(
                  GazetteCategory.description(_category),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),

                const SizedBox(height: AppTheme.gapMd),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _declaredMass,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: const InputDecoration(
                          labelText: 'Unit mass (grams)',
                          helperText: 'The mass of one unit, as you measure it.',
                        ),
                        onChanged: (_) => setState(() {}),
                        validator: (v) => milligramsFromGrams(v) == null
                            ? 'Between ${formatGrams(minUnitMassMg)} and '
                                  '${formatGrams(maxUnitMassMg)}.'
                            : null,
                      ),
                    ),
                    const SizedBox(width: AppTheme.gapMd),
                    Expanded(
                      child: TextFormField(
                        controller: _volume,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(
                          labelText: 'Volume (ml, optional)',
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: AppTheme.gapMd),
                const NoticeCard(
                  icon: Icons.info_outline,
                  message:
                      'Chokro weighs a sample of this product and the measured '
                      'mean becomes the mass every report uses. Your declared '
                      'figure is checked against it.',
                ),

                const SizedBox(height: AppTheme.gapLg),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Parts',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _components.length >= 12
                          ? null
                          : () => setState(
                              () => _components.add(
                                _ComponentDraft(
                                  part: '',
                                  polymer: PolymerType.pet,
                                  grams: '',
                                ),
                              ),
                            ),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add part'),
                    ),
                  ],
                ),
                Text(
                  'One recognised bottle can contribute grams to more than one '
                  'polymer. Declaring the parts is what lets a report state a '
                  'PET figure and a PP figure from the same item.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppTheme.gapSm),

                for (var i = 0; i < _components.length; i += 1)
                  _ComponentRow(
                    key: ValueKey(i),
                    draft: _components[i],
                    onChanged: () => setState(() {}),
                    onRemove: _components.length <= 1
                        ? null
                        : () => setState(() => _components.removeAt(i)),
                  ),

                const SizedBox(height: AppTheme.gapSm),
                _BalanceLine(
                  sumMg: sumMg,
                  declaredMg: declaredMg,
                  balances: _balances,
                ),

                const SizedBox(height: AppTheme.gapLg),
                TextFormField(
                  controller: _images,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Sample photograph URLs',
                    helperText:
                        'Two to six, one per line, against a plain background. '
                        'Needed before Chokro can verify the mass.',
                  ),
                ),
                TextFormField(
                  controller: _gtin,
                  decoration: const InputDecoration(
                    labelText: 'Barcode / GTIN (optional)',
                    helperText:
                        'Where a Champion scans this, recognition stops being '
                        'a guess.',
                  ),
                  validator: (v) {
                    final value = v?.trim() ?? '';
                    if (value.isEmpty) return null;
                    return RegExp(r'^\d{8,14}$').hasMatch(value)
                        ? null
                        : 'A GTIN is 8 to 14 digits.';
                  },
                ),
                TextFormField(
                  controller: _hints,
                  decoration: const InputDecoration(
                    labelText: 'Recognition hints (optional)',
                    helperText:
                        'Label colours, wordmark, shape — comma separated.',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving || !_balances ? null : _save,
          child: Text(_saving ? 'Saving…' : 'Save'),
        ),
      ],
    );
  }
}

/// The running sum against the declared mass, as it is typed.
class _BalanceLine extends StatelessWidget {
  const _BalanceLine({
    required this.sumMg,
    required this.declaredMg,
    required this.balances,
  });

  final int? sumMg;
  final int? declaredMg;
  final bool balances;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (sumMg == null || declaredMg == null) {
      return Text(
        'Enter a mass for every part and for the unit.',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      );
    }

    final difference = sumMg! - declaredMg!;

    return Row(
      children: [
        Icon(
          balances ? Icons.check_circle_outline : Icons.error_outline,
          size: 18,
          color: balances ? theme.colorScheme.primary : theme.colorScheme.error,
        ),
        const SizedBox(width: AppTheme.gapSm),
        Expanded(
          child: Text(
            balances
                ? 'Parts add up to ${formatGrams(sumMg!)} — matches the unit mass.'
                : 'Parts add up to ${formatGrams(sumMg!)}, '
                      '${difference > 0 ? 'over' : 'under'} the '
                      '${formatGrams(declaredMg!)} unit mass by '
                      '${formatGrams(difference.abs())}.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: balances ? null : theme.colorScheme.error,
            ),
          ),
        ),
      ],
    );
  }
}

class _ComponentRow extends StatefulWidget {
  const _ComponentRow({
    super.key,
    required this.draft,
    required this.onChanged,
    this.onRemove,
  });

  final _ComponentDraft draft;
  final VoidCallback onChanged;
  final VoidCallback? onRemove;

  @override
  State<_ComponentRow> createState() => _ComponentRowState();
}

class _ComponentRowState extends State<_ComponentRow> {
  late final TextEditingController _part;
  late final TextEditingController _grams;

  @override
  void initState() {
    super.initState();
    _part = TextEditingController(text: widget.draft.part);
    _grams = TextEditingController(text: widget.draft.grams);
  }

  @override
  void dispose() {
    _part.dispose();
    _grams.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.gapSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 3,
            child: TextFormField(
              controller: _part,
              decoration: const InputDecoration(
                labelText: 'Part',
                hintText: 'body',
                isDense: true,
              ),
              onChanged: (v) {
                widget.draft.part = v;
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: AppTheme.gapSm),
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<String>(
              initialValue: widget.draft.polymer,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Polymer',
                isDense: true,
              ),
              items: [
                for (final value in PolymerType.all)
                  DropdownMenuItem(
                    value: value,
                    child: Text(
                      PolymerType.label(value),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (v) {
                widget.draft.polymer = v ?? widget.draft.polymer;
                widget.onChanged();
              },
            ),
          ),
          const SizedBox(width: AppTheme.gapSm),
          Expanded(
            flex: 2,
            child: TextFormField(
              controller: _grams,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Grams',
                isDense: true,
              ),
              onChanged: (v) {
                widget.draft.grams = v;
                widget.onChanged();
              },
            ),
          ),
          IconButton(
            onPressed: widget.onRemove,
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Remove this part',
          ),
        ],
      ),
    );
  }
}

class _ComponentDraft {
  _ComponentDraft({
    required this.part,
    required this.polymer,
    required this.grams,
  });

  String part;
  String polymer;
  String grams;
}
