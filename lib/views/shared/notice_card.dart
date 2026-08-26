import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// What a notice is telling the reader, which decides its colour.
///
/// A tone rather than a pair of raw `Color`s, deliberately. The private copies
/// of this widget each took `background`/`foreground` arguments, so every call
/// site picked its own pairing — which is how three screens ended up rendering
/// the same kind of message in three different colours, and how a caller could
/// pass a background without the matching `on-` colour and produce unreadable
/// text. The scheme owns the pairing here; callers choose meaning.
enum NoticeTone {
  /// Neutral context — a fact the reader needs, not a problem.
  info,

  /// Something the reader should notice before acting, but which is not a
  /// failure: low stock, an account limit, a pending state.
  warning,

  /// Something is wrong or blocked, and the reader has to do something about it.
  error,

  /// Something is confirmed and in good order.
  success,
}

/// The label and callback for a notice's single follow-up action.
class NoticeAction {
  const NoticeAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

/// A tinted panel that states one thing and, optionally, offers the one action
/// that resolves it.
///
/// ## Why this is shared
///
/// Three screens had each grown a private `_Notice` with the same name and a
/// different API — `admin_bins_view` (title + body + action, raw colours),
/// `product_detail_view` (a `Card` with icon + message) and
/// `claim_submit_view` (an inline row with a `tone` colour). A reader moving
/// between an admin console and the shop met the same kind of message in three
/// visual treatments, and the next person adding a fourth screen had three
/// prior arts to choose from.
///
/// Both card shapes are covered here: [title] is optional, so the
/// icon-plus-sentence form is this widget with the title left off.
class NoticeCard extends StatelessWidget {
  const NoticeCard({
    super.key,
    required this.icon,
    required this.message,
    this.title,
    this.tone = NoticeTone.info,
    this.action,
  });

  final IconData icon;

  /// The body. One or two sentences: what is true, and what to do about it.
  final String message;

  /// An optional short heading. Omitted, the notice is a single sentence beside
  /// its icon — which is the right shape for a passing remark and the wrong one
  /// for something the reader has to act on.
  final String? title;

  final NoticeTone tone;
  final NoticeAction? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (Color background, Color foreground) = switch (tone) {
      NoticeTone.info => (
        scheme.surfaceContainerHighest,
        scheme.onSurfaceVariant,
      ),
      NoticeTone.warning => (scheme.warningContainer, scheme.onWarningContainer),
      NoticeTone.error => (scheme.errorContainer, scheme.onErrorContainer),
      NoticeTone.success => (scheme.successContainer, scheme.onSuccessContainer),
    };

    final heading = title;
    final follow = action;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppTheme.gapMd),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(AppTheme.radiusSm),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: foreground, size: 20),
          const SizedBox(width: AppTheme.gapSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (heading != null) ...[
                  Text(
                    heading,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: foreground,
                    ),
                  ),
                  const SizedBox(height: AppTheme.gapXs),
                ],
                Text(
                  message,
                  style:
                      (heading == null
                              ? theme.textTheme.bodyMedium
                              : theme.textTheme.bodySmall)
                          ?.copyWith(color: foreground),
                ),
                if (follow != null) ...[
                  const SizedBox(height: AppTheme.gapSm),
                  OutlinedButton(
                    onPressed: follow.onPressed,
                    style: OutlinedButton.styleFrom(
                      // Inherited, the button would take its label from the
                      // page's `primary` and its outline from `outline`, both
                      // of which are chosen against `surface` — not against the
                      // tinted panel it is sitting on. On `errorContainer` that
                      // was the same low-contrast pairing `app_snackbar.dart`
                      // documents.
                      foregroundColor: foreground,
                      side: BorderSide(color: foreground.withValues(alpha: .4)),
                    ),
                    child: Text(follow.label),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
