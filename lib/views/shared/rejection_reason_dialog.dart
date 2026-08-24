import 'package:flutter/material.dart';

import '../../core/theme.dart';
import '../../core/validators.dart';

/// Asks an administrator why they are rejecting something.
///
/// ## Why this is shared
///
/// Three screens — the disposal queue, the claim queue and the seller
/// applications list — each had their own near-identical copy of this dialog,
/// and **all three leaked** a `TextEditingController` created inside a helper
/// method and never disposed. Every rejection dialog opened left one behind.
/// Making it a `StatefulWidget` gives the controller a lifecycle to be disposed
/// against, which a local in an `async` helper never had.
///
/// The three copies also disagreed. Two allowed an empty reason through to the
/// controller, which then rejected it with an error snackbar; one blocked the
/// button silently with no explanation. Now the Reject button is simply disabled
/// until there is something to send, and says why.
///
/// Returns the trimmed reason, or null if the administrator cancelled. Never
/// returns an empty string, so callers do not need to re-check.
Future<String?> showRejectionReasonDialog(
  BuildContext context, {
  required String title,
  required String hintText,
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _RejectionReasonDialog(
      title: title,
      hintText: hintText,
    ),
  );
}

class _RejectionReasonDialog extends StatefulWidget {
  const _RejectionReasonDialog({required this.title, required this.hintText});

  final String title;
  final String hintText;

  @override
  State<_RejectionReasonDialog> createState() => _RejectionReasonDialogState();
}

class _RejectionReasonDialogState extends State<_RejectionReasonDialog> {
  final _controller = TextEditingController();

  /// A reason this short is not a reason. The user reads it and has to be able
  /// to act on it — "no" tells them nothing and makes an appeal unanswerable.
  static const int _minLength = TextLimits.rejectionReasonMin;

  /// The ceiling comes from `firestore.rules`, which caps
  /// `sellerApplications.reason` at 500 characters and refuses a longer write
  /// with a bare `permission-denied`. Disposal and claim rejections travel to
  /// the trusted service instead and have no stored ceiling, but this dialog is
  /// shared by all three, so it is bounded by the tightest of them rather than
  /// letting one queue fail in a way the other two do not.
  static const int _maxLength = TextLimits.rejectionReasonMax;

  @override
  void initState() {
    super.initState();
    // Drives the Reject button's enabled state as the administrator types.
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  String get _reason => _controller.text.trim();
  bool get _isValid =>
      _reason.length >= _minLength && _reason.length <= _maxLength;

  void _submit() {
    if (!_isValid) return;
    Navigator.of(context).pop(_reason);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = _minLength - _reason.length;

    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'The person who submitted this is shown your reason, so write it '
            'for them to read.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.gapMd),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: 3,
            minLines: 3,
            maxLength: _maxLength,
            textCapitalization: TextCapitalization.sentences,
            // Enter inserts a newline in a multiline field, so submission is the
            // button's job. Keeps the keyboard's action key honest.
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: widget.hintText,
              helperText: _isValid
                  ? 'This is shown to the user.'
                  : '$remaining more character${remaining == 1 ? '' : 's'}',
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
          onPressed: _isValid ? _submit : null,
          style: FilledButton.styleFrom(
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
          ),
          child: const Text('Reject'),
        ),
      ],
    );
  }
}
