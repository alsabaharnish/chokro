import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/attribution_controller.dart';
import '../../controllers/compliance_controller.dart';
import '../../core/epr_categories.dart';
import '../../core/epr_period.dart';
import '../../core/mass_math.dart';
import '../../core/network_errors.dart';
import '../../core/theme.dart';
import '../../models/put_on_market_model.dart';
import '../../services/compliance_service.dart';
import '../../services/organization_service.dart' show OrgActionException;
import '../shared/app_shell.dart';
import '../shared/app_snackbar.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';

/// Filing what the company placed on the market (EPR-40 to EPR-43).
///
/// ## This screen is the reason a percentage can exist at all
///
/// Chokro knows how much it collected. It does not know, and cannot find out,
/// how much the company put on the market — that figure exists only in the
/// producer's own records. So the collection percentage on every other screen
/// and on every certificate is a ratio whose denominator is filed here, by the
/// producer, under attestation.
///
/// Which makes the empty state of this form the honest state of the whole
/// portal: until it is filled in, there is no percentage anywhere, and
/// [CollectedMassCard] says so rather than showing a zero.
///
/// ## Why the figures are entered in grams
///
/// Kilograms would be the natural unit for an annual volume, and it is what the
/// rest of the portal displays. The form takes grams because that is the unit
/// the producer's own SKU records are in — a 250 ml bottle weighs 9.8 g — and a
/// person converting to kilograms in their head to fill in a compliance form
/// will eventually convert one line wrong. The screen shows the kilogram
/// equivalent live beside each figure so the scale is never in doubt.
///
/// Nothing is converted here: the grams go to the server, which is the only
/// thing that turns them into the integer milligrams everything else stores
/// (EPR-20).
class DeclarationView extends ConsumerStatefulWidget {
  const DeclarationView({super.key});

  @override
  ConsumerState<DeclarationView> createState() => _DeclarationViewState();
}

class _DeclarationViewState extends ConsumerState<DeclarationView> {
  /// One controller pair per gazette category, kept for the screen's lifetime.
  ///
  /// Built once rather than per-build: rebuilding a `TextEditingController`
  /// while somebody is typing in it loses the cursor position, and this form is
  /// long enough that it would be noticed.
  final Map<String, TextEditingController> _mass = {
    for (final category in GazetteCategory.all) category: TextEditingController(),
  };
  final Map<String, TextEditingController> _units = {
    for (final category in GazetteCategory.all) category: TextEditingController(),
  };

  /// Which period the form is currently filled from.
  ///
  /// Not a bool. A one-shot `_hydrated` flag meant the form was filled once
  /// and then never again — so changing the "Reporting period" dropdown left
  /// the PREVIOUS month's figures in the fields while `_isEditable` became
  /// true for the new one, and pressing "Attest and file" wrote them against
  /// the new period under the EPR-41 attestation. A producer would have
  /// attested, by name and under stated penalty, to figures for a month it
  /// never entered them for.
  String? _hydratedFor;

  bool _busy = false;
  List<String> _problems = const [];

  @override
  void dispose() {
    for (final c in _mass.values) {
      c.dispose();
    }
    for (final c in _units.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(declarationProvider);
    final permissions = ref.watch(declarationPermissionsProvider);
    final periodId = ref.watch(selectedPeriodProvider);

    return AppShell(
      title: 'Put on market',
      child: detail.when(
        loading: () => const ContentLoading(
          label: 'Loading…',
          slowHint: ContentLoading.serverWakingHint,
        ),
        error: (error, _) => ErrorRetry(
          error: error,
          onRetry: () => ref.invalidate(declarationProvider),
        ),
        data: (data) {
          if (data.hasError) {
            return ErrorRetry(
              error: data.error!,
              onRetry: () => ref.invalidate(declarationProvider),
            );
          }

          _hydrate(data);

          return ListView(
            padding: const EdgeInsets.all(AppTheme.gapMd),
            children: [
              _PeriodHeader(periodId: periodId, declaration: data.declaration),
              const SizedBox(height: AppTheme.gapMd),
              if (permissions.value?.isReadOnly ?? false) ...[
                const NoticeCard(
                  icon: Icons.lock_outline,
                  tone: NoticeTone.warning,
                  title: 'This workspace is read-only',
                  message:
                      'Existing filings and certificates stay available. '
                      'Nothing new can be filed until the suspension is lifted.',
                ),
                const SizedBox(height: AppTheme.gapMd),
              ],
              _StatusBanner(declaration: data.declaration),
              const SizedBox(height: AppTheme.gapMd),
              if (_problems.isNotEmpty) ...[
                _ProblemList(problems: _problems),
                const SizedBox(height: AppTheme.gapMd),
              ],
              _LinesForm(
                mass: _mass,
                units: _units,
                enabled: _isEditable(data, permissions.value),
                onChanged: () => setState(() {}),
              ),
              const SizedBox(height: AppTheme.gapMd),
              _Totals(mass: _mass),
              const SizedBox(height: AppTheme.gapLg),
              _Actions(
                detail: data,
                permissions: permissions.value,
                busy: _busy,
                onSaveDraft: () => _saveDraft(data),
                onSubmit: () => _submit(data),
                onCorrect: () => _correct(data),
              ),
              const SizedBox(height: AppTheme.gapLg),
              if (data.versions.isNotEmpty) _VersionHistory(versions: data.versions),
            ],
          );
        },
      ),
    );
  }

  /// Whether the form accepts input right now.
  ///
  /// A submitted declaration is NOT editable. Correcting one is a deliberate
  /// act with a stated reason that supersedes certificates already issued
  /// (EPR-30), so it goes through the correction button rather than by letting
  /// somebody type over a filed figure.
  bool _isEditable(DeclarationDetail detail, DeclarationPermissions? permissions) {
    if (permissions == null || !permissions.canDraft) return false;
    final declaration = detail.declaration;
    return declaration == null || declaration.status == DeclarationStatus.draft;
  }

  /// Fills the form from the stored record, once per period.
  ///
  /// Guarded on the PERIOD rather than on a bool. `build` runs on every
  /// keystroke, so re-filling unconditionally would overwrite what the person
  /// is typing with what the server last saw — but guarding on a one-shot flag
  /// leaves last month's figures in the fields when the period changes, and
  /// the submit that follows attests to them against the new month.
  ///
  /// Every field is cleared before filling, so a period with nothing filed
  /// shows an empty form rather than the previous month's numbers.
  void _hydrate(DeclarationDetail detail) {
    if (_hydratedFor == detail.periodId) return;
    _hydratedFor = detail.periodId;

    for (final controller in [..._mass.values, ..._units.values]) {
      controller.clear();
    }

    final declaration = detail.declaration;
    if (declaration == null) return;

    for (final line in declaration.lines) {
      _mass[line.category]?.text = _gramsText(line.massMg);
      _units[line.category]?.text = line.units.toString();
    }
  }

  /// Milligrams as a gram figure a person would recognise.
  ///
  /// Not rounded to significant figures: this is a value going back into an
  /// editable field, and rounding it would silently change the producer's own
  /// declared figure the next time they pressed save.
  static String _gramsText(int massMg) {
    final grams = massMg / 1000;
    return grams == grams.roundToDouble()
        ? grams.round().toString()
        : grams.toString();
  }

  List<PutOnMarketLine> _collectLines() {
    final lines = <PutOnMarketLine>[];
    for (final category in GazetteCategory.all) {
      final massText = _mass[category]!.text.trim();
      final unitsText = _units[category]!.text.trim();
      // A category left entirely blank is not declared. That is a different
      // statement from a nil declaration (EPR-42), so it is omitted rather
      // than sent as a zero.
      if (massText.isEmpty && unitsText.isEmpty) continue;

      final grams = double.tryParse(massText) ?? -1;
      lines.add(
        PutOnMarketLine(
          category: category,
          units: int.tryParse(unitsText) ?? -1,
          // Rounded here only to build the model the service reads back as
          // grams. The server re-parses the gram figure and is the only thing
          // that decides the stored milligrams.
          massMg: grams < 0 ? -1 : (grams * 1000).round(),
        ),
      );
    }
    return lines;
  }

  Future<void> _saveDraft(DeclarationDetail detail) async {
    final snack = AppSnackBar.of(context);
    await _run(() async {
      await ref.read(complianceServiceProvider).saveDraft(
        periodId: detail.periodId,
        lines: _collectLines(),
      );
      snack.success('Draft saved. It is not a declaration yet.');
    });
  }

  Future<void> _submit(DeclarationDetail detail) async {
    final snack = AppSnackBar.of(context);
    final name = await _askForAttestation(detail.attestationText);
    if (name == null) return;

    await _run(() async {
      // Saved first, so what is attested to is what is on the screen. Without
      // this an unsaved edit would be signed for and then discarded — the
      // person would have attested to a figure that was never filed.
      await ref.read(complianceServiceProvider).saveDraft(
        periodId: detail.periodId,
        lines: _collectLines(),
        attestedByName: name,
      );
      final result = await ref
          .read(complianceServiceProvider)
          .submit(periodId: detail.periodId, attestedByName: name);

      snack.success(
        'Filed as version ${result.version}. '
        '${formatKilograms(result.totalMassMg)} declared for '
        '${detail.periodId}.',
      );
    });
  }

  Future<void> _correct(DeclarationDetail detail) async {
    final snack = AppSnackBar.of(context);
    final reason = await _askForCorrectionReason();
    if (reason == null) return;

    await _run(() async {
      final superseded = await ref
          .read(complianceServiceProvider)
          .openCorrection(periodId: detail.periodId, reason: reason);

      snack.success(
        superseded == 0
            ? 'Reopened for correction. File the new figures and attest again.'
            : 'Reopened for correction. $superseded '
                  '${superseded == 1 ? 'certificate' : 'certificates'} for '
                  'this period ${superseded == 1 ? 'is' : 'are'} now '
                  'superseded — anyone verifying one is told so.',
      );
      // The form must reload from the reopened record rather than keep what
      // was on screen: the attestation has been cleared and the status has
      // changed, and a stale form would let somebody press submit against a
      // record it no longer matches.
      _hydratedFor = null;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    final snack = AppSnackBar.of(context);
    setState(() {
      _busy = true;
      _problems = const [];
    });
    try {
      await action();
      ref.invalidate(declarationProvider);
      ref.invalidate(compliancePositionProvider);
      ref.invalidate(passportsProvider);
    } on DeclarationRejected catch (rejection) {
      // Every problem at once, against the line it belongs to. A form that
      // reported the first fault and hid the rest would make a five-line
      // declaration a five-round-trip exercise.
      if (mounted) setState(() => _problems = rejection.problems);
    } on OrgActionException catch (error) {
      snack.failure(error.message);
    } catch (error) {
      // Everything else, and deliberately broad.
      //
      // `ComplianceService` calls `.timeout(ApiConfig.coldStartTimeout)`, so a
      // sleeping instance raises `TimeoutException`; a dropped connection
      // raises `SocketException`, and the web build raises
      // `http.ClientException` on a CORS refusal. None of those is an
      // `OrgActionException`, so before this they escaped `_run` into a Future
      // that the button's `VoidCallback` discards — and with no
      // `runZonedGuarded` anywhere in the app, the producer saw the spinner
      // stop and nothing else. On a form that files a legal attestation,
      // "nothing happened and nobody said why" is the worst available outcome.
      snack.failure(friendlyErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The attestation dialog (EPR-41).
  ///
  /// The full text, not a summary, and not a checkbox beside a link. The
  /// statement says a false figure may cost the company its registration and
  /// bring legal action; a person signing that is entitled to have read it
  /// without navigating anywhere.
  Future<String?> _askForAttestation(String attestationText) async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Attest to these figures'),
        content: SingleChildScrollView(
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  attestationText,
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: AppTheme.gapMd),
                TextFormField(
                  controller: controller,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Full name of the person attesting',
                    helperText: 'Recorded on the filing and on every '
                        'certificate that uses it.',
                  ),
                  validator: (value) => (value ?? '').trim().length < 2
                      ? 'Enter the name of the person signing.'
                      : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(context).pop(controller.text.trim());
              }
            },
            child: const Text('File this declaration'),
          ),
        ],
      ),
    );

    controller.dispose();
    return name;
  }

  Future<String?> _askForCorrectionReason() async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final reason = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Correct a filed declaration'),
        content: SingleChildScrollView(
          child: Form(
            key: formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'The filed figures stay on record and are not deleted. '
                  'Every Plastic Passport issued for this period will be '
                  'marked superseded, and anyone verifying one is told so.',
                ),
                const SizedBox(height: AppTheme.gapMd),
                TextFormField(
                  controller: controller,
                  autofocus: true,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Why are the figures being corrected?',
                    helperText: 'Recorded in the audit trail and shown to '
                        'Chokro’s reviewers.',
                  ),
                  validator: (value) => (value ?? '').trim().length < 5
                      ? 'A correction with no stated reason cannot be told '
                            'apart from a manipulation.'
                      : null,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(context).pop(controller.text.trim());
              }
            },
            child: const Text('Reopen for correction'),
          ),
        ],
      ),
    );

    controller.dispose();
    return reason;
  }
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

class _PeriodHeader extends ConsumerWidget {
  const _PeriodHeader({required this.periodId, required this.declaration});

  final String periodId;
  final PutOnMarketDeclaration? declaration;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final options = ref.watch(periodOptionsProvider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              initialValue: options.contains(periodId) ? periodId : null,
              decoration: const InputDecoration(labelText: 'Reporting period'),
              items: [
                for (final option in options)
                  DropdownMenuItem(value: option, child: Text(periodLabel(option))),
              ],
              onChanged: (value) {
                if (value == null) return;
                ref.read(selectedPeriodProvider.notifier).select(value);
              },
            ),
            const SizedBox(height: AppTheme.gapSm),
            Text(
              'Declare what your company placed on the Bangladesh market in '
              'this period. Chokro cannot know this figure — it is the '
              'denominator of every collection percentage on your certificates.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.declaration});

  final PutOnMarketDeclaration? declaration;

  @override
  Widget build(BuildContext context) {
    // The empty state, and the reason this screen exists. Said in the words
    // EPR-24 uses rather than left as a blank form.
    if (declaration == null) {
      return const NoticeCard(
        icon: Icons.assignment_outlined,
        tone: NoticeTone.info,
        title: 'Nothing filed for this period',
        message:
            'Until a declaration is filed, no collection percentage is shown '
            'anywhere in the portal and none is printed on a certificate. '
            'Chokro states what it collected; the percentage needs what you '
            'placed on the market.',
      );
    }

    return switch (declaration!.status) {
      DeclarationStatus.draft => NoticeCard(
        icon: Icons.edit_outlined,
        tone: NoticeTone.warning,
        title: declaration!.version > 0
            ? 'Reopened for correction'
            : 'Draft — not yet a declaration',
        message: declaration!.version > 0
            ? 'Version ${declaration!.version} has been superseded. File the '
                  'corrected figures and attest to them again.'
            : 'A draft carries no attestation, so nothing certifies against '
                  'it. File it to make it your declaration for this period.',
      ),
      DeclarationStatus.submitted => NoticeCard(
        icon: Icons.verified_outlined,
        tone: NoticeTone.success,
        title: 'Filed — version ${declaration!.version}',
        message:
            'Attested by ${declaration!.attestedByName}. '
            'This is the denominator for every collection percentage in this '
            'period. Correcting it supersedes any certificate already issued.',
      ),
      _ => const NoticeCard(
        icon: Icons.history,
        tone: NoticeTone.warning,
        title: 'Superseded',
        message: 'A later version of this declaration has replaced it.',
      ),
    };
  }
}

class _ProblemList extends StatelessWidget {
  const _ProblemList({required this.problems});

  final List<String> problems;

  @override
  Widget build(BuildContext context) {
    return NoticeCard(
      icon: Icons.error_outline,
      tone: NoticeTone.error,
      title: problems.length == 1
          ? 'One figure could not be accepted'
          : '${problems.length} figures could not be accepted',
      // Every problem, named by category. Nothing was saved, so the person is
      // looking at exactly what they typed.
      message: problems.join('\n'),
    );
  }
}

class _LinesForm extends StatelessWidget {
  const _LinesForm({
    required this.mass,
    required this.units,
    required this.enabled,
    required this.onChanged,
  });

  final Map<String, TextEditingController> mass;
  final Map<String, TextEditingController> units;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'By gazette category',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              'Leave a category blank if you placed none of it on the market. '
              'Enter 0 in both fields only to declare a category as nil — that '
              'is a statement, and it is recorded as one.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppTheme.gapMd),
            for (final category in GazetteCategory.all) ...[
              _CategoryRow(
                category: category,
                massController: mass[category]!,
                unitsController: units[category]!,
                enabled: enabled,
                onChanged: onChanged,
              ),
              const SizedBox(height: AppTheme.gapMd),
            ],
          ],
        ),
      ),
    );
  }
}

class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.category,
    required this.massController,
    required this.unitsController,
    required this.enabled,
    required this.onChanged,
  });

  final String category;
  final TextEditingController massController;
  final TextEditingController unitsController;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final grams = double.tryParse(massController.text.trim());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          GazetteCategory.label(category),
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: AppTheme.gapXs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 3,
              child: TextField(
                controller: massController,
                enabled: enabled,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                // Digits and one decimal point. A thousands separator would be
                // refused by the server anyway, and refusing it here means the
                // person finds out while they are still looking at the field.
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                  labelText: 'Mass (grams)',
                  // The kilogram equivalent, live. A person entering an annual
                  // volume in grams is typing a number with a lot of zeros, and
                  // this is where a factor-of-a-thousand slip becomes visible.
                  helperText: grams == null || grams <= 0
                      ? null
                      : '= ${formatKilograms((grams * 1000).round())}',
                ),
                onChanged: (_) => onChanged(),
              ),
            ),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              flex: 2,
              child: TextField(
                controller: unitsController,
                enabled: enabled,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(labelText: 'Units'),
                onChanged: (_) => onChanged(),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Totals extends StatelessWidget {
  const _Totals({required this.mass});

  final Map<String, TextEditingController> mass;

  @override
  Widget build(BuildContext context) {
    var totalMg = 0;
    var declaredCategories = 0;
    for (final controller in mass.values) {
      final grams = double.tryParse(controller.text.trim());
      if (grams == null) continue;
      declaredCategories += 1;
      totalMg += (grams * 1000).round();
    }

    if (declaredCategories == 0) return const SizedBox.shrink();

    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Total to be declared',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            Text(
              formatKilograms(totalMg),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.detail,
    required this.permissions,
    required this.busy,
    required this.onSaveDraft,
    required this.onSubmit,
    required this.onCorrect,
  });

  final DeclarationDetail detail;
  final DeclarationPermissions? permissions;
  final bool busy;
  final VoidCallback onSaveDraft;
  final VoidCallback onSubmit;
  final VoidCallback onCorrect;

  @override
  Widget build(BuildContext context) {
    final permissions = this.permissions;
    if (permissions == null) return const SizedBox.shrink();

    final isFiled = detail.isFiled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isFiled)
          OutlinedButton.icon(
            onPressed: busy || !permissions.canAttest ? null : onCorrect,
            icon: const Icon(Icons.edit_note),
            label: const Text('Correct this declaration'),
          )
        else ...[
          OutlinedButton(
            onPressed: busy || !permissions.canDraft ? null : onSaveDraft,
            child: const Text('Save draft'),
          ),
          const SizedBox(height: AppTheme.gapSm),
          FilledButton.icon(
            onPressed: busy || !permissions.canAttest ? null : onSubmit,
            icon: const Icon(Icons.verified_user_outlined),
            label: const Text('Attest and file'),
          ),
        ],
        // Shown rather than hidden. A reporter who could not see that the
        // attestation step exists would think the draft was the filing — and
        // a draft certifies nothing.
        if (!permissions.canAttest && !permissions.isReadOnly) ...[
          const SizedBox(height: AppTheme.gapSm),
          Text(
            'Only an owner can attest to these figures. The attestation names '
            'the person signing and states what a false declaration costs.',
            style: Theme.of(context).textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ],
    );
  }
}

/// Every figure ever declared for this period (EPR-41).
///
/// Shown to the producer rather than kept for Chokro. A superseded version is
/// evidence — of what was declared at the time, and of the fact that it was
/// later withdrawn — and a producer that cannot see its own filing history
/// cannot answer a question about it.
class _VersionHistory extends StatelessWidget {
  const _VersionHistory({required this.versions});

  final List<PutOnMarketDeclaration> versions;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Filing history', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: AppTheme.gapSm),
            for (final version in versions)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: CircleAvatar(
                  radius: 14,
                  child: Text(
                    'v${version.version}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
                ),
                title: Text(
                  version.totalMassMg == null
                      ? '—'
                      : formatKilograms(version.totalMassMg!),
                ),
                subtitle: Text(
                  version.attestedByName.isEmpty
                      ? 'Attested'
                      : 'Attested by ${version.attestedByName}',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
