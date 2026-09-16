/// The Admin's account-deletion flow (SEC-13).
///
/// ## Three screens, not one button
///
/// Plan, confirm, outcome. The plan exists because an Admin is about to do
/// something irreversible on behalf of somebody who is not in the room, and
/// will usually have to tell that person afterwards what happened to their
/// data. Reading the retained list *before* the deletion is the only point at
/// which that knowledge is useful.
///
/// ## What is retained is shown first, and largest
///
/// Every entry in the retained list is something a person asking to be erased
/// would reasonably expect to go. The contested ones — where Chokro's right to
/// keep the record is its own position rather than settled law (decision 9) —
/// are marked as such, because an Admin answering "will my disposals be
/// deleted?" should know which half of the answer is firm.
///
/// ## A partial deletion never renders as a clean one
///
/// The server answers 207 when a step failed, and the outcome screen shows the
/// failures in error tone with what DID run beside them. Collapsing that into
/// "Deleted" is how somebody is told they were forgotten when they were not.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/admin_users_controller.dart';
import '../../core/theme.dart';
import '../../models/account_deletion_model.dart';
import '../../models/user_model.dart';
import '../shared/notice_card.dart';

/// Opens the flow. Returns the outcome when a deletion ran, null otherwise.
Future<DeletionOutcome?> showAccountDeletionDialog(
  BuildContext context,
  UserModel user,
) {
  return showDialog<DeletionOutcome>(
    context: context,
    // Not dismissible by tapping outside: the confirm step is the last moment
    // to reconsider, and a stray tap there should not read as "cancel" any
    // more than it should read as "go ahead".
    barrierDismissible: false,
    builder: (_) => _AccountDeletionDialog(user: user),
  );
}

class _AccountDeletionDialog extends ConsumerStatefulWidget {
  const _AccountDeletionDialog({required this.user});

  final UserModel user;

  @override
  ConsumerState<_AccountDeletionDialog> createState() =>
      _AccountDeletionDialogState();
}

class _AccountDeletionDialogState
    extends ConsumerState<_AccountDeletionDialog> {
  final _reason = TextEditingController();

  DeletionPlan? _plan;
  DeletionOutcome? _outcome;
  String? _error;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _loadPlan();
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _loadPlan() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final plan = await ref
          .read(accountDeletionServiceProvider)
          .plan(widget.user.uid);
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _busy = false;
      });
    }
  }

  Future<void> _delete() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final outcome = await ref
          .read(accountDeletionServiceProvider)
          .delete(widget.user.uid, reason: _reason.text.trim());
      if (!mounted) return;
      setState(() {
        _outcome = outcome;
        _busy = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = '$error';
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(
        _outcome != null
            ? (_outcome!.complete ? 'Account deleted' : 'Partly deleted')
            : 'Delete ${widget.user.name}’s account',
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(child: _body(theme)),
      ),
      actions: _actions(),
    );
  }

  Widget _body(ThemeData theme) {
    if (_error != null) {
      return NoticeCard(
        icon: Icons.error_outline,
        tone: NoticeTone.error,
        title: 'That did not run',
        message: _error!,
        action: NoticeAction(
          label: 'Try again',
          onPressed: _outcome == null && _plan == null ? _loadPlan : _delete,
        ),
      );
    }

    if (_busy && _plan == null) {
      return const Padding(
        padding: EdgeInsets.all(AppTheme.gapLg),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_outcome != null) return _outcomeBody(theme);

    final plan = _plan!;
    if (plan.alreadyDeleted) {
      return const NoticeCard(
        icon: Icons.info_outline,
        tone: NoticeTone.info,
        title: 'Already deleted',
        message:
            'This account has already been erased. Nothing further will '
            'happen if you run it again.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const NoticeCard(
          icon: Icons.warning_amber_outlined,
          tone: NoticeTone.error,
          title: 'This cannot be undone',
          message:
              'The person will not be able to sign in again, and their name, '
              'email address and photograph cannot be recovered.',
        ),
        const SizedBox(height: AppTheme.gapMd),

        // What stays comes FIRST. It is the part an Admin will be asked about,
        // and the part a deletion flow normally buries.
        Text('What is kept', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppTheme.gapXs),
        for (final item in plan.retained) _RetainedLine(item: item),

        if (plan.hasContestedRetention) ...[
          const SizedBox(height: AppTheme.gapSm),
          Text(
            'Items marked “Chokro’s position” are kept on a basis a lawyer has '
            'not yet confirmed (decision 9). If the Champion asks, say that '
            'these are retained and why — not that they were deleted.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],

        const SizedBox(height: AppTheme.gapMd),
        Text('What is removed', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppTheme.gapXs),
        for (final item in plan.erased)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text(
              '• ${item.what}',
              style: theme.textTheme.bodyMedium,
            ),
          ),

        const SizedBox(height: AppTheme.gapMd),
        TextField(
          controller: _reason,
          decoration: const InputDecoration(
            labelText: 'Why (recorded on the account)',
            hintText: 'e.g. Champion requested deletion by email, 16 Sept',
            border: OutlineInputBorder(),
          ),
          maxLines: 2,
          maxLength: 500,
        ),
      ],
    );
  }

  Widget _outcomeBody(ThemeData theme) {
    final outcome = _outcome!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!outcome.complete)
          NoticeCard(
            icon: Icons.report_problem_outlined,
            tone: NoticeTone.error,
            title: 'Some of this did not run',
            // Named, because an Admin who believes the deletion finished will
            // tell the Champion it did.
            message:
                '${outcome.failed.join('\n')}\n\nRun it again to finish. The '
                'steps below have already been done and will not repeat.',
          )
        else
          const NoticeCard(
            icon: Icons.check_circle_outline,
            tone: NoticeTone.success,
            title: 'Every step completed',
            message:
                'The account is erased and the sign-in no longer exists.',
          ),

        const SizedBox(height: AppTheme.gapMd),
        Text('What was removed', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppTheme.gapXs),
        for (final line in outcome.erased)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Text('• $line', style: theme.textTheme.bodyMedium),
          ),

        const SizedBox(height: AppTheme.gapMd),
        Text('What is still kept', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppTheme.gapXs),
        for (final item in outcome.retained) _RetainedLine(item: item),
      ],
    );
  }

  List<Widget> _actions() {
    if (_outcome != null) {
      return [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_outcome),
          child: const Text('Done'),
        ),
      ];
    }

    final canDelete =
        _plan != null && !_plan!.alreadyDeleted && _plan!.accountExists;

    return [
      TextButton(
        onPressed: _busy ? null : () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _busy || !canDelete ? null : _delete,
        style: FilledButton.styleFrom(
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
        // Not "OK", and not "Confirm". The label says what happens.
        child: Text(_busy ? 'Deleting…' : 'Delete permanently'),
      ),
    ];
  }
}

class _RetainedLine extends StatelessWidget {
  const _RetainedLine({required this.item});

  final RetainedCategory item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.gapSm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(item.what, style: theme.textTheme.bodyMedium),
              ),
              if (item.contested)
                Padding(
                  padding: const EdgeInsets.only(left: AppTheme.gapSm),
                  child: Text(
                    'Chokro’s position',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
          Text(
            item.why,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
