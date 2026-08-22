import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/appeals_controller.dart';
import '../../core/theme.dart';
import '../../models/appeal_model.dart';
import '../shared/content_state.dart';

/// Raising an appeal against a rejection (F5.4).
///
/// ## What an appeal can and cannot do
///
/// It cannot pay. Resolving an appeal moves no points, which is precisely what
/// lets the whole decision live in `firestore.rules` rather than on the server
/// — the same shape `sellerApplications` already uses.
///
/// The substantive remedy for a wrong rejection is different and better: a
/// rejection releases the bin lockout (§7.4), so a legitimate submission can be
/// made again and go through the full verification pipeline. An appeal is how a
/// user says the decision was wrong and gets an answer in writing; it is not a
/// second route to a payout that skips the checks.
///
/// The screen says all of that before the text field, because a user who thinks
/// they are requesting their 50 points will be disappointed by an upheld appeal.
class AppealFormView extends ConsumerStatefulWidget {
  const AppealFormView({
    super.key,
    required this.subjectType,
    required this.subjectId,
  });

  final AppealSubject subjectType;
  final String subjectId;

  @override
  ConsumerState<AppealFormView> createState() => _AppealFormViewState();
}

class _AppealFormViewState extends ConsumerState<AppealFormView> {
  final _formKey = GlobalKey<FormState>();
  final _message = TextEditingController();
  bool _sending = false;
  bool _sent = false;

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (_sent) {
      return Scaffold(
        appBar: AppBar(title: const Text('Appeal sent')),
        body: ContentEmpty(
          icon: Icons.mark_email_read_outlined,
          title: 'A 3ZERO Admin will read this',
          message:
              'You will see their answer on your appeals screen. Points are not '
              'awarded by an appeal — if the rejection was wrong, submit again '
              'and the checks will run properly this time.',
          actionLabel: 'My appeals',
          onAction: () => context.go('/appeals'),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Appeal a decision')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.gapMd,
            AppTheme.gapMd,
            AppTheme.gapMd,
            AppTheme.gap2Xl,
          ),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppTheme.maxContentWidth,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Card(
                      color: theme.colorScheme.surfaceContainerHighest,
                      margin: EdgeInsets.zero,
                      child: Padding(
                        padding: const EdgeInsets.all(AppTheme.gapMd),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Appealing a ${widget.subjectType.label.toLowerCase()}',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: AppTheme.gapXs),
                            Text(
                              'A 3ZERO Admin reads what you write and answers '
                              'in writing. An appeal does not award points on its '
                              'own — where a rejection was wrong, the fix is to '
                              'submit again so the checks can run.',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: AppTheme.gapLg),
                    TextFormField(
                      controller: _message,
                      textCapitalization: TextCapitalization.sentences,
                      minLines: 5,
                      maxLines: 12,
                      maxLength: AppealModel.messageMax,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Why do you think the decision was wrong?',
                        alignLabelWithHint: true,
                        helperText:
                            'Be specific: what the photograph shows, where you '
                            'were, what you disposed of.',
                      ),
                      validator: AppealModel.validateMessage,
                    ),

                    const SizedBox(height: AppTheme.gapMd),
                    FilledButton.icon(
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.send_outlined),
                      label: Text(_sending ? 'Sending…' : 'Send appeal'),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _send() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    setState(() => _sending = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(appealActionsProvider)
          .raise(
            subjectType: widget.subjectType,
            subjectId: widget.subjectId,
            message: _message.text,
          );
      if (!mounted) return;
      setState(() => _sent = true);
    } on AppealValidationException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(_failureMessage(error))));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Rules refuse an appeal that does not name the caller's own *rejected*
  /// submission, and they give no reason for it. This names the two conditions
  /// so the user is not left with "missing or insufficient permissions".
  String _failureMessage(Object error) {
    if (error.toString().contains('permission-denied')) {
      return 'That appeal was refused. You can only appeal your own '
          'submissions, and only ones that were rejected.';
    }
    return 'The appeal could not be sent. $error';
  }
}
