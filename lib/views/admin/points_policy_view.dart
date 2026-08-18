import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/points_policy_controller.dart';
import '../../core/label_format.dart';
import '../../core/points_policy.dart';
import '../../core/policy_fields.dart';
import '../../services/points_policy_service.dart';
import '../shared/app_shell.dart';

/// Administrator editor for the points policy (F3.3).
///
/// Three things this screen is careful about:
///
/// 1. **It validates live, but the server decides.** `PointsPolicy.validate()`
///    runs on every keystroke so an administrator sees a broken invariant
///    immediately, and the same check runs again server-side before the write.
///    The client check is a courtesy, not the enforcement.
/// 2. **It shows the change before committing it.** Editing this document
///    changes the economy, so a save presents a from → to summary first.
/// 3. **It says what a change does not do.** Past awards are snapshotted and
///    are not rewritten — the most likely misunderstanding an administrator
///    could have here.
class PointsPolicyView extends ConsumerStatefulWidget {
  const PointsPolicyView({super.key});

  static const double _maxContentWidth = 720;

  @override
  ConsumerState<PointsPolicyView> createState() => _PointsPolicyViewState();
}

class _PointsPolicyViewState extends ConsumerState<PointsPolicyView> {
  final Map<String, TextEditingController> _controllers = {};

  /// The policy as the server last gave it to us. The baseline for the diff.
  PointsPolicy? _loaded;

  bool _saving = false;
  List<String> _serverProblems = const [];

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _adoptLoaded(PointsPolicy policy) {
    _loaded = policy;
    for (final field in policyFields) {
      final text = '${field.read(policy)}';
      final existing = _controllers[field.key];
      if (existing == null) {
        _controllers[field.key] = TextEditingController(text: text);
      } else {
        existing.text = text;
      }
    }
  }

  /// Builds a policy from the current text, or null if any field is not a
  /// whole number. Parse failures are reported separately from invariant
  /// failures — "abc" and "claim pays more than disposal" are different
  /// mistakes and deserve different messages.
  ({PointsPolicy? policy, List<String> parseErrors}) _readForm() {
    final base = _loaded;
    if (base == null) return (policy: null, parseErrors: const []);

    var draft = base;
    final errors = <String>[];

    for (final field in policyFields) {
      final raw = _controllers[field.key]?.text.trim() ?? '';
      final value = int.tryParse(raw);
      if (value == null) {
        errors.add('${field.label} must be a whole number.');
        continue;
      }
      draft = field.write(draft, value);
    }

    return (policy: errors.isEmpty ? draft : null, parseErrors: errors);
  }

  Future<void> _save(PointsPolicy policy, List<PolicyChange> changes) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Apply these changes?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final change in changes)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(change.summary),
              ),
            const SizedBox(height: 12),
            Text(
              'Applies to decisions made from now on. Points already awarded '
              'keep the value they were given.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    setState(() {
      _saving = true;
      _serverProblems = const [];
    });

    try {
      final stored = await ref.read(pointsPolicyEditorProvider).save(policy);
      if (!mounted) return;
      setState(() {
        _adoptLoaded(stored);
        _saving = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Points policy updated.')),
      );
    } on PolicyException catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _serverProblems = error.problems;
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(policySnapshotProvider);

    return AppShell(
      title: 'Points policy',
      child: Center(
        child: ConstrainedBox(
          constraints:
              const BoxConstraints(maxWidth: PointsPolicyView._maxContentWidth),
          child: async.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _PolicyError(
              error: error,
              onRetry: () => ref.invalidate(policySnapshotProvider),
            ),
            data: (snapshot) {
              if (_loaded == null) _adoptLoaded(snapshot.policy);
              return _buildForm(context, snapshot.provenance);
            },
          ),
        ),
      ),
    );
  }

  Widget _buildForm(BuildContext context, PolicyProvenance provenance) {
    final theme = Theme.of(context);
    final base = _loaded!;
    final (policy: draft, parseErrors: parseErrors) = _readForm();

    final invariantProblems = draft?.validate() ?? const <String>[];
    final changes = draft == null ? <PolicyChange>[] : diffPolicies(base, draft);
    final canSave = !_saving &&
        draft != null &&
        invariantProblems.isEmpty &&
        changes.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
      children: [
        Card(
          color: theme.colorScheme.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.history_toggle_off,
                    size: 18, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Changes here affect future decisions only. Every award is '
                    'snapshotted onto the submission that earned it, so past '
                    'points keep the value they were given.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        _ProvenanceLine(provenance: provenance),
        const SizedBox(height: 20),
        for (final field in policyFields) ...[
          _PolicyInput(
            field: field,
            controller: _controllers[field.key]!,
            onChanged: () => setState(() {}),
          ),
          const SizedBox(height: 18),
        ],
        if (parseErrors.isNotEmpty)
          _ProblemList(
            title: 'Fix these entries',
            problems: parseErrors,
            tone: theme.colorScheme.error,
          ),
        if (invariantProblems.isNotEmpty)
          _ProblemList(
            title: 'These values are not allowed',
            problems: invariantProblems,
            tone: theme.colorScheme.error,
          ),
        if (_serverProblems.isNotEmpty)
          _ProblemList(
            title: 'The server refused the write',
            problems: _serverProblems,
            tone: theme.colorScheme.error,
          ),
        if (changes.isNotEmpty && invariantProblems.isEmpty) ...[
          const SizedBox(height: 4),
          _ProblemList(
            title: 'Pending changes',
            problems: changes.map((c) => c.summary).toList(growable: false),
            tone: theme.colorScheme.primary,
          ),
        ],
        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed:
                    canSave ? () => _save(draft, changes) : null,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.save_outlined),
                label: Text(_saving ? 'Saving…' : 'Save policy'),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton(
              onPressed: _saving
                  ? null
                  : () => setState(() => _adoptLoaded(base)),
              child: const Text('Revert'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Center(
          child: TextButton(
            onPressed: _saving
                ? null
                : () => setState(() {
                      for (final field in policyFields) {
                        _controllers[field.key]!.text =
                            '${field.read(PointsPolicy.defaults)}';
                      }
                    }),
            child: const Text('Load section 7.3 defaults'),
          ),
        ),
      ],
    );
  }
}

class _PolicyInput extends StatelessWidget {
  const _PolicyInput({
    required this.field,
    required this.controller,
    required this.onChanged,
  });

  final PolicyField field;
  final TextEditingController controller;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => onChanged(),
          decoration: InputDecoration(
            labelText: field.label,
            suffixText: field.suffix,
            isDense: true,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          field.help,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _ProblemList extends StatelessWidget {
  const _ProblemList({
    required this.title,
    required this.problems,
    required this.tone,
  });

  final String title;
  final List<String> problems;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.labelLarge
                ?.copyWith(color: tone, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          for (final problem in problems)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('• ', style: theme.textTheme.bodySmall),
                  Expanded(
                    child: Text(problem, style: theme.textTheme.bodySmall),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PolicyError extends StatelessWidget {
  const _PolicyError({required this.error, required this.onRetry});

  final Object error;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off_outlined,
                size: 40, color: theme.colorScheme.error),
            const SizedBox(height: 14),
            Text('The policy did not load', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '$error',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            FilledButton.tonal(
                onPressed: onRetry, child: const Text('Try again')),
          ],
        ),
      ),
    );
  }
}

/// Who last changed the policy, and when (F3.3).
///
/// The server has recorded this on every write since the endpoint existed and
/// nothing ever showed it. On a screen where any administrator can change the
/// economy, the values give no hint of their own history: a disposal award of 50
/// reads the same whether it is the untouched default from §7.3 or something a
/// colleague set an hour ago.
class _ProvenanceLine extends StatelessWidget {
  const _ProvenanceLine({required this.provenance});

  final PolicyProvenance provenance;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // "Nobody has changed this" is different information from "somebody set it
    // to exactly the defaults", and only the first can be stated with certainty
    // from an absent document.
    final text = provenance.isUntouched
        ? 'Never changed. These are the defaults.'
        : 'Last changed by ${provenance.editor}, '
            '${formatDateTime(provenance.updatedAt)}.';

    return Row(
      children: [
        Icon(
          provenance.isUntouched ? Icons.settings_suggest_outlined : Icons.person_outline,
          size: 16,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      ],
    );
  }
}
