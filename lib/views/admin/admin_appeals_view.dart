import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/appeals_controller.dart';
import '../../core/theme.dart';
import '../../models/appeal_model.dart';
import '../appeals/appeals_view.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';

/// The administrator's appeal queue (F5.4).
///
/// Oldest first, like the disposal and claim queues, so the earliest appeal is
/// not the one left waiting longest.
///
/// Both outcomes require a written answer, and the rules enforce it — a status
/// with no words is not an answer to somebody who was already told "rejected"
/// once with a reason they disputed. Upholding an appeal does **not** credit
/// anything: it records that the decision was wrong, and the user submits again
/// so the checks actually run.
class AdminAppealsView extends ConsumerWidget {
  const AdminAppealsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final appealsAsync = ref.watch(pendingAppealsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Appeals')),
      body: appealsAsync.when(
        loading: () => const ContentLoading(label: 'Loading the queue…'),
        error: (error, _) => ErrorRetry(
          error: error,
          title: 'The appeal queue',
          onRetry: () => ref.invalidate(pendingAppealsProvider),
        ),
        data: (appeals) {
          if (appeals.isEmpty) {
            return const ContentEmpty(
              icon: Icons.gavel_outlined,
              title: 'Nothing to answer',
              message: 'No appeal is waiting for a decision.',
            );
          }

          return ListView(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.gapMd,
              AppTheme.gapMd,
              AppTheme.gapMd,
              AppTheme.gapXl,
            ),
            children: [
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppTheme.maxDashboardWidth,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _QueueNotice(count: appeals.length),
                      const SizedBox(height: AppTheme.gapMd),
                      for (final appeal in appeals) ...[
                        AppealCard(
                          appeal: appeal,
                          action: _DecisionButtons(appeal: appeal),
                        ),
                        const SizedBox(height: AppTheme.gapMd),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _QueueNotice extends StatelessWidget {
  const _QueueNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      color: scheme.surfaceContainerHighest,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: scheme.onSurfaceVariant),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: Text(
                '$count waiting, oldest first. Upholding an appeal records that '
                'the decision was wrong; it credits nothing. The user submits '
                'again and the verification runs properly — the lockout was '
                'already released when their submission was rejected.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DecisionButtons extends ConsumerStatefulWidget {
  const _DecisionButtons({required this.appeal});

  final AppealModel appeal;

  @override
  ConsumerState<_DecisionButtons> createState() => _DecisionButtonsState();
}

class _DecisionButtonsState extends ConsumerState<_DecisionButtons> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _decide(uphold: false),
            icon: const Icon(Icons.thumb_down_outlined),
            label: const Text('Decline'),
          ),
        ),
        const SizedBox(width: AppTheme.gapSm),
        Expanded(
          child: FilledButton.icon(
            onPressed: _busy ? null : () => _decide(uphold: true),
            icon: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.thumb_up_outlined),
            label: const Text('Uphold'),
          ),
        ),
      ],
    );
  }

  Future<void> _decide({required bool uphold}) async {
    final response = await _askForAnswer(uphold: uphold);
    if (response == null || !mounted) return;

    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(appealActionsProvider)
          .resolve(
            appealId: widget.appeal.id!,
            uphold: uphold,
            response: response,
          );
      messenger.showSnackBar(
        SnackBar(content: Text(uphold ? 'Appeal upheld.' : 'Appeal declined.')),
      );
    } on AppealValidationException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('The decision was not recorded. $error')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Asks for the written answer both outcomes require.
  ///
  /// Deliberately not `showRejectionReasonDialog`: that one is worded for
  /// refusing something, and this dialog is also used to *uphold*. Reusing it
  /// would put "Reject" on the button that agrees with the user.
  Future<String?> _askForAnswer({required bool uphold}) {
    return showDialog<String>(
      context: context,
      builder: (context) => _AnswerDialog(uphold: uphold),
    );
  }
}

class _AnswerDialog extends StatefulWidget {
  const _AnswerDialog({required this.uphold});

  final bool uphold;

  @override
  State<_AnswerDialog> createState() => _AnswerDialogState();
}

class _AnswerDialogState extends State<_AnswerDialog> {
  // A StatefulWidget rather than a controller made inside an async helper —
  // that pattern leaked one controller per dialog in three screens before
  // `showRejectionReasonDialog` was extracted, and the same trap applies here.
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final problem = AppealModel.validateResponse(_controller.text);

    return AlertDialog(
      title: Text(widget.uphold ? 'Uphold this appeal' : 'Decline this appeal'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.uphold
                ? 'Tell them the decision was wrong and what to do next — '
                      'usually, submit again.'
                : 'Tell them why the original decision stands.',
          ),
          const SizedBox(height: AppTheme.gapMd),
          TextField(
            controller: _controller,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            maxLength: AppealModel.responseMax,
            decoration: const InputDecoration(
              hintText: 'The user reads this exactly as you write it.',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // Disabled until there is something to send, and the helper text says
          // why — rather than accepting an empty answer and failing at the
          // rules, which give no reason.
          onPressed: problem != null
              ? null
              : () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(widget.uphold ? 'Uphold' : 'Decline'),
        ),
      ],
    );
  }
}
