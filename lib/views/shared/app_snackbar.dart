import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// SnackBars that stay readable, and that say what kind of news they carry.
///
/// ## The bug this exists to stop repeating
///
/// [SnackBar] takes a `backgroundColor` but leaves `contentTextStyle` alone, and
/// the unset default is `onInverseSurface` — a colour chosen for the *default*
/// dark pill. Four call sites overrode the background with
/// `colorScheme.errorContainer`, a pale pink, and left the near-white default
/// text on top of it. Measured against this app's own scheme:
///
/// | background | foreground | ratio |
/// | --- | --- | --- |
/// | `inverseSurface` (default) | `onInverseSurface` | 11.55 |
/// | `errorContainer` | `onInverseSurface` (what shipped) | **1.70** |
/// | `errorContainer` | `onErrorContainer` | 4.97 |
///
/// 1.70:1 against a WCAG AA floor of 4.5 is not "low contrast", it is invisible.
/// Every failed sign-in, every failed registration, and every failed
/// application review reported itself in text the user could not read. Dark
/// mode was worse, at 1.56.
///
/// So the pairing is not something a call site should be able to get wrong: a
/// background is never chosen without the matching foreground.
///
/// ## Why colour is not the only signal
///
/// The four sites that did colour their SnackBar conveyed "this failed" with
/// hue alone — nothing for a screen reader, nothing for a colour-blind user, and
/// nothing at all in the 39 sites that used the neutral default for successes
/// and failures alike. Each variant here carries an icon as well, and the icon
/// is what makes the two distinguishable without colour vision.
///
/// ## Why it captures rather than taking a context
///
/// Most of these are shown *after* an `await`, where the originating
/// `BuildContext` may be gone — which is why call sites were already hand-rolling
/// `final messenger = ScaffoldMessenger.of(context);` before the gap.
/// [AppSnackBar.of] does that capture once, together with the colours it needs,
/// so the result is safe to hold across an await without a `mounted` dance.
class AppSnackBar {
  const AppSnackBar._(this._messenger, this._scheme);

  final ScaffoldMessengerState _messenger;
  final ColorScheme _scheme;

  /// Captures the messenger and the palette now, for use after an await.
  factory AppSnackBar.of(BuildContext context) => AppSnackBar._(
    ScaffoldMessenger.of(context),
    Theme.of(context).colorScheme,
  );

  /// Something did not work. Longer on screen than a success, because it
  /// usually asks the reader to do something about it.
  ///
  /// [actionLabel] and [onAction] attach the remedy the message names. A
  /// message that states a remedy and withholds it — "An account already
  /// exists. Sign in instead." — leaves the reader to dismiss the bar, find a
  /// small text link, and retype what they just entered.
  void failure(String message, {String? actionLabel, VoidCallback? onAction}) =>
      _show(
        message,
        background: _scheme.errorContainer,
        foreground: _scheme.onErrorContainer,
        icon: Icons.error_outline,
        duration: const Duration(seconds: 6),
        actionLabel: actionLabel,
        onAction: onAction,
      );

  /// Something worked, and the result is not otherwise visible on screen.
  void success(String message) => _show(
    message,
    background: _scheme.successContainer,
    foreground: _scheme.onSuccessContainer,
    icon: Icons.check_circle_outline,
    duration: const Duration(seconds: 4),
  );

  /// Neutral news — a state change the user asked for and can already see.
  void info(String message) => _show(
    message,
    background: _scheme.inverseSurface,
    foreground: _scheme.onInverseSurface,
    icon: Icons.info_outline,
    duration: const Duration(seconds: 4),
  );

  void _show(
    String message, {
    required Color background,
    required Color foreground,
    required IconData icon,
    required Duration duration,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    _messenger
      // Queued SnackBars are shown one after another, so without this an error
      // raised while an earlier message was still up waited its turn behind it.
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          backgroundColor: background,
          duration: duration,
          content: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: foreground),
              const SizedBox(width: AppTheme.gapSm),
              Expanded(
                child: Text(message, style: TextStyle(color: foreground)),
              ),
            ],
          ),
          // `textColor` is not optional here. SnackBarAction defaults to
          // `inversePrimary`, which against `errorContainer` repeats exactly
          // the contrast mistake this class was written to end — so the colour
          // is set here rather than left to each caller to remember.
          action: (actionLabel != null && onAction != null)
              ? SnackBarAction(
                  label: actionLabel,
                  textColor: foreground,
                  onPressed: onAction,
                )
              : null,
          // The theme turns the close affordance on for every SnackBar; it
          // inherits `onSurface` unless it is told otherwise, which is the same
          // mismatch as the text.
          closeIconColor: foreground,
        ),
      );
  }
}
