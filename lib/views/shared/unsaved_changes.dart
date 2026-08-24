import 'package:flutter/material.dart';

/// Asks before a back gesture throws away work the user has typed.
///
/// ## Why this exists
///
/// A search for `PopScope` across `lib/` returned one hit, and it was a comment
/// in `declare_view.dart` explaining a deliberate omission. Every form in the
/// app was therefore one stray back-swipe from losing everything in it, with no
/// warning and no way back: the listing editor with its six fields and its
/// already-uploaded photographs, the Greenpreneur application, and the appeal
/// form, whose whole content is a piece of writing with a twenty-character
/// minimum that someone composed in one go.
///
/// Losing a form silently is the kind of defect that never appears in a bug
/// report, because the person who hit it assumes they did something wrong.
///
/// ## The shape of the guard
///
/// [PopScope] cannot decide asynchronously — it is told after the fact whether
/// the pop happened — so the route is held closed while the question is asked
/// and popped by hand on a yes. That also means the guard must not be armed
/// when there is nothing to lose, or an empty form would interrogate everyone
/// who opened it by mistake. Hence [hasChanges].
class UnsavedChangesGuard extends StatelessWidget {
  const UnsavedChangesGuard({
    super.key,
    required this.hasChanges,
    required this.child,
    this.title = 'Discard your changes?',
    this.message =
        'What you have entered here has not been saved, and leaving now loses '
        'it.',
    this.stayLabel = 'Keep editing',
    this.leaveLabel = 'Discard',
  });

  /// Whether there is anything worth protecting. False disarms the guard
  /// entirely, so an untouched form closes on the first back gesture.
  final bool hasChanges;

  final Widget child;
  final String title;
  final String message;
  final String stayLabel;
  final String leaveLabel;

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !hasChanges,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;

        final navigator = Navigator.of(context);
        final discard = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(title),
            content: Text(message),
            actions: [
              // The safe choice is the one that stays, and it is the one the
              // eye lands on last — the destructive action must not be the
              // button someone taps by reflex.
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: Text(leaveLabel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(stayLabel),
              ),
            ],
          ),
        );

        if (discard == true) navigator.pop();
      },
      child: child,
    );
  }
}
