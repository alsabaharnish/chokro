/// Regulator disclosure (SEC-13) — the special power, and its register.
///
/// ## Why this screen is locked when every other Admin screen is not
///
/// Everything else in the oversight console reads data that is already
/// de-identified. This one undoes that, on purpose, for one person at a time.
/// It is the only place in Chokro where an Admin can walk back from a
/// pseudonym to a human being.
///
/// So it asks for the password again. Not because the session is untrusted —
/// it passed `requireAdmin` — but because an unattended laptop with a signed-in
/// Admin should not be able to re-identify a Champion, and five minutes of
/// "I signed in earlier" is not the standard that should apply to this.
///
/// **The padlock here is not the control.** The server reads `auth_time` from
/// the token and refuses a stale one. This screen exists to tell the Admin what
/// will happen before they have typed a declaration.
///
/// ## Three things are recorded that the Admin cannot skip
///
/// The regulator's request number, a written reason in their own words, and
/// where they were. The third is asked for rather than taken: a refusal is
/// recorded AS a refusal, which is a fact about the access, and the disclosure
/// still proceeds. Blocking on it would make the control bypassable with a
/// system setting and would punish an Admin for a browser preference.
///
/// ## The register is open
///
/// No padlock on reading it. An Admin checking whether a colleague's access was
/// proper must not face the same barrier as the access itself — oversight has
/// to be cheaper than the thing it oversees.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/disclosure_controller.dart';
import '../../core/mass_math.dart';
import '../../core/theme.dart';
import '../../models/disclosure_model.dart';
import '../../services/organization_service.dart' show OrgActionException;
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';

class AdminDisclosureTab extends ConsumerStatefulWidget {
  const AdminDisclosureTab({super.key});

  @override
  ConsumerState<AdminDisclosureTab> createState() => _AdminDisclosureTabState();
}

class _AdminDisclosureTabState extends ConsumerState<AdminDisclosureTab> {
  final _orgId = TextEditingController();
  final _ref = TextEditingController();
  final _doe = TextEditingController();
  final _why = TextEditingController();

  DisclosureResult? _result;
  DisclosureLocation? _location;
  String? _error;
  bool _busy = false;
  bool _attested = false;

  @override
  void dispose() {
    _orgId.dispose();
    _ref.dispose();
    _doe.dispose();
    _why.dispose();
    super.dispose();
  }

  bool get _unlocked =>
      ref.read(disclosureUnlockProvider.notifier).isUnlocked;

  Future<void> _unlock() async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _PasswordPrompt(),
    );
    if (password == null || password.isEmpty || !mounted) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(disclosureServiceProvider).reauthenticate(password);
      if (!mounted) return;
      ref.read(disclosureUnlockProvider.notifier).unlocked();
      setState(() => _busy = false);
    } on OrgActionException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _busy = false;
      });
    }
  }

  /// Asks the device where it is. Records the answer either way.
  Future<void> _locate() async {
    setState(() => _busy = true);
    final result = await ref
        .read(locationServiceProvider)
        .getCurrentLocation();
    if (!mounted) return;
    setState(() {
      _location = DisclosureLocation.fromResult(result);
      _busy = false;
    });
  }

  Future<void> _resolve() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await ref.read(disclosureServiceProvider).resolve(
        orgId: _orgId.text.trim(),
        disposalRef: _ref.text.trim(),
        doeReference: _doe.text.trim(),
        declaration: _why.text.trim(),
        location: _location ?? const DisclosureLocation.unavailable(),
      );
      if (!mounted) return;
      // Locked again immediately. A second disclosure is a second decision.
      ref.read(disclosureUnlockProvider.notifier).lock();
      ref.invalidate(disclosureRegisterProvider);
      setState(() {
        _result = result;
        _busy = false;
        _attested = false;
      });
    } on OrgActionException catch (error) {
      if (!mounted) return;
      if (error.code == 'reauthentication_required') {
        ref.read(disclosureUnlockProvider.notifier).lock();
      }
      setState(() {
        _error = error.message;
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(AppTheme.gapMd),
      children: [
        const NoticeCard(
          icon: Icons.lock_outline,
          tone: NoticeTone.warning,
          title: 'This is the only screen that re-identifies a person',
          message:
              'Resolving a reference undoes the de-identification that makes a '
              'producer export releasable. Use it only to answer a formal '
              'request from the Department of Environment. Every use is '
              'recorded below with your name, the time, where you were and '
              'the reason you give — permanently, and visible to every Admin.',
        ),
        const SizedBox(height: AppTheme.gapMd),

        if (_error != null) ...[
          NoticeCard(
            icon: Icons.error_outline,
            tone: NoticeTone.error,
            title: 'That did not run',
            message: _error!,
          ),
          const SizedBox(height: AppTheme.gapMd),
        ],

        if (!_unlocked)
          _LockedPanel(busy: _busy, onUnlock: _unlock)
        else
          _form(theme),

        if (_result != null) ...[
          const SizedBox(height: AppTheme.gapMd),
          _ResultPanel(result: _result!),
        ],

        const SizedBox(height: AppTheme.gapLg),
        Text('Disclosure register', style: theme.textTheme.titleMedium),
        const SizedBox(height: AppTheme.gapXs),
        Text(
          'Every resolution and every identity release. Readable by any Admin '
          'without unlocking — checking a colleague’s access must be easier '
          'than making one.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: AppTheme.gapSm),
        const _Register(),
      ],
    );
  }

  Widget _form(ThemeData theme) {
    final remaining = ref.read(disclosureUnlockProvider.notifier).remaining;
    final complete = _orgId.text.trim().isNotEmpty &&
        _ref.text.trim().isNotEmpty &&
        _doe.text.trim().length >= 3 &&
        _why.text.trim().length >= 20 &&
        _attested;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.lock_open, size: 18, color: theme.colorScheme.error),
                const SizedBox(width: AppTheme.gapSm),
                Expanded(
                  child: Text(
                    remaining == null
                        ? 'Unlocked'
                        : 'Unlocked for ${remaining.inMinutes + 1} more minute(s)',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.gapMd),

            TextField(
              controller: _orgId,
              decoration: const InputDecoration(
                labelText: 'Organisation id',
                helperText: 'Whose export the reference came from',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppTheme.gapSm),
            TextField(
              controller: _ref,
              decoration: const InputDecoration(
                labelText: 'Disposal reference',
                helperText: '24 hex characters, from the chain-of-custody export',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppTheme.gapSm),
            TextField(
              controller: _doe,
              decoration: const InputDecoration(
                labelText: 'Department of Environment request number',
                hintText: 'DoE/EPR/2026/0041',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppTheme.gapSm),
            TextField(
              controller: _why,
              decoration: const InputDecoration(
                labelText: 'Why you are doing this',
                helperText:
                    'In your own words, at least a sentence. Read back on the '
                    'register by somebody who was not here.',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
              maxLength: 1000,
              onChanged: (_) => setState(() {}),
            ),

            const SizedBox(height: AppTheme.gapSm),
            _LocationRow(
              location: _location,
              busy: _busy,
              onLocate: _locate,
            ),

            const SizedBox(height: AppTheme.gapSm),
            CheckboxListTile(
              value: _attested,
              onChanged: (v) => setState(() => _attested = v ?? false),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(
                'I confirm this answers a formal request from the Department '
                'of Environment, and that I am authorised to make it.',
                style: theme.textTheme.bodySmall,
              ),
            ),

            const SizedBox(height: AppTheme.gapSm),
            FilledButton.icon(
              onPressed: _busy || !complete ? null : _resolve,
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
              ),
              icon: const Icon(Icons.key, size: 18),
              label: Text(_busy ? 'Recording…' : 'Record and resolve'),
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              // Said before the button, not after.
              'This writes to the audit chain before it resolves anything. '
              'There is no way to resolve a reference without leaving a record.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LockedPanel extends StatelessWidget {
  const _LockedPanel({required this.busy, required this.onUnlock});

  final bool busy;
  final VoidCallback onUnlock;

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
                Icon(Icons.lock, size: 18, color: theme.colorScheme.error),
                const SizedBox(width: AppTheme.gapSm),
                Text('Locked', style: theme.textTheme.titleSmall),
              ],
            ),
            const SizedBox(height: AppTheme.gapSm),
            Text(
              'Enter your password to unlock this for five minutes. Your '
              'password goes to Firebase, not to Chokro — this service never '
              'receives it.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: AppTheme.gapMd),
            FilledButton.icon(
              onPressed: busy ? null : onUnlock,
              icon: const Icon(Icons.lock_open, size: 18),
              label: Text(busy ? 'Checking…' : 'Unlock'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PasswordPrompt extends StatefulWidget {
  const _PasswordPrompt();

  @override
  State<_PasswordPrompt> createState() => _PasswordPromptState();
}

class _PasswordPromptState extends State<_PasswordPrompt> {
  final _controller = TextEditingController();
  bool _obscure = true;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Confirm it is you'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'This unlocks the ability to re-identify a Champion for five '
            'minutes.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppTheme.gapMd),
          TextField(
            controller: _controller,
            obscureText: _obscure,
            autofocus: true,
            decoration: InputDecoration(
              labelText: 'Your password',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _obscure = !_obscure),
                tooltip: _obscure ? 'Show' : 'Hide',
              ),
            ),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Unlock'),
        ),
      ],
    );
  }
}

class _LocationRow extends StatelessWidget {
  const _LocationRow({
    required this.location,
    required this.busy,
    required this.onLocate,
  });

  final DisclosureLocation? location;
  final bool busy;
  final VoidCallback onLocate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = location;

    return Row(
      children: [
        Icon(
          l?.hasCoordinates == true
              ? Icons.location_on
              : Icons.location_searching,
          size: 18,
          color: theme.colorScheme.outline,
        ),
        const SizedBox(width: AppTheme.gapSm),
        Expanded(
          child: Text(
            // Never blank. "Not recorded yet" and "refused" are different
            // states and the register will show whichever one this is.
            l == null ? 'Location not recorded yet' : l.label,
            style: theme.textTheme.bodySmall,
          ),
        ),
        TextButton(
          onPressed: busy ? null : onLocate,
          child: Text(l == null ? 'Add location' : 'Update'),
        ),
      ],
    );
  }
}

class _ResultPanel extends StatelessWidget {
  const _ResultPanel({required this.result});

  final DisclosureResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (!result.found) {
      return NoticeCard(
        icon: result.exhaustive ? Icons.search_off : Icons.hourglass_empty,
        // The distinction a regulator's conclusion turns on. Telling them a
        // genuine row is unknown is the worst answer this feature can give.
        tone: result.exhaustive ? NoticeTone.info : NoticeTone.warning,
        title: result.exhaustive
            ? 'Not this organisation’s reference'
            : 'The search stopped early — this is NOT a not-found',
        message: result.note ?? '',
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Evidence', style: theme.textTheme.titleSmall),
            const SizedBox(height: AppTheme.gapXs),

            if (result.referenceKeyed == false)
              Padding(
                padding: const EdgeInsets.only(bottom: AppTheme.gapSm),
                child: Text(
                  'This reference was minted before AUDIT_CHAIN_KEY was set. '
                  'Worth noting on any exhibit built from it.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),

            if (!result.disposalPresent)
              Text(
                'The disposal record no longer exists. The attributions below '
                'are retained compliance records and remain valid.',
                style: theme.textTheme.bodySmall,
              )
            else ...[
              Text('Bin: ${result.binId ?? '—'}',
                  style: theme.textTheme.bodyMedium),
              Text('Status: ${result.status ?? '—'}',
                  style: theme.textTheme.bodyMedium),
            ],

            const SizedBox(height: AppTheme.gapSm),
            Text(
              '${result.attributions.length} attribution(s)',
              style: theme.textTheme.titleSmall,
            ),
            for (final a in result.attributions)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  '• ${a.periodId ?? '—'} · ${a.skuId ?? '—'} · '
                  '${formatKilograms(a.massMg)} · ${a.units} unit(s)',
                  style: theme.textTheme.bodySmall,
                ),
              ),

            const SizedBox(height: AppTheme.gapSm),
            Text(
              result.registerId == null
                  // Said rather than hidden: the access happened either way.
                  ? 'The register row could not be written. The audit chain '
                        'entry did commit — this access IS recorded.'
                  : 'Recorded on the register as ${result.registerId}.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: result.registerId == null
                    ? theme.colorScheme.error
                    : theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Register extends ConsumerWidget {
  const _Register();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final register = ref.watch(disclosureRegisterProvider);
    final theme = Theme.of(context);

    return register.when(
      loading: () => const ContentLoading(
        label: 'Loading…',
        slowHint: ContentLoading.serverWakingHint,
      ),
      error: (error, _) => ErrorRetry(
        error: error,
        onRetry: () => ref.invalidate(disclosureRegisterProvider),
      ),
      data: (data) {
        if (data.entries.isEmpty) {
          return Text(
            'No disclosure has ever been made.',
            style: theme.textTheme.bodyMedium,
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!data.complete)
              Padding(
                padding: const EdgeInsets.only(bottom: AppTheme.gapSm),
                child: Text(
                  'Showing the most recent ${data.limit}. There are more — a '
                  'register of privileged accesses is the one place a missing '
                  'row matters most.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ),
            for (final entry in data.entries) _RegisterRow(entry: entry),
          ],
        );
      },
    );
  }
}

class _RegisterRow extends StatelessWidget {
  const _RegisterRow({required this.entry});

  final DisclosureRecord entry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.only(bottom: AppTheme.gapSm),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    entry.namedAPerson
                        // The stronger of the two acts, and labelled as such.
                        ? 'Named a Champion'
                        : 'Resolved a reference',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: entry.namedAPerson
                          ? theme.colorScheme.error
                          : null,
                    ),
                  ),
                ),
                Text(
                  entry.at == null ? 'Time not recorded' : '${entry.at!.toLocal()}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              '${entry.adminName ?? entry.adminUid ?? 'Unknown Admin'} · '
              '${entry.doeReference ?? 'no request number'}',
              style: theme.textTheme.bodyMedium,
            ),
            if (entry.declaration != null) ...[
              const SizedBox(height: AppTheme.gapXs),
              Text('“${entry.declaration}”', style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: AppTheme.gapXs),
            Text(
              '${entry.location.label} · ${entry.ip ?? 'no address'}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
