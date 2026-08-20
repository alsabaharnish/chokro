import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/api_config.dart';
import '../../core/theme.dart';

/// A calm, labelled loading state for full-page reads.
///
/// ## Why this can explain itself after a few seconds
///
/// Anything that calls the trusted service waits up to
/// [ApiConfig.coldStartTimeout] — ninety seconds — because Render's free
/// instance sleeps after about fifteen minutes idle and takes 30–60 seconds to
/// wake. That timeout is correct: cutting it shorter would fail requests that
/// were going to succeed.
///
/// What was wrong was the silence. A spinner with no explanation is
/// indistinguishable from a broken screen after about five seconds, so a waking
/// server looked exactly like a hung one — and the honest error message, when it
/// finally arrived, arrived a minute and a half after the user had given up and
/// concluded the feature did not work.
///
/// [slowHint] is shown once [slowAfter] has passed, turning a silent wait into a
/// stated one.
class ContentLoading extends StatefulWidget {
  const ContentLoading({
    super.key,
    this.label = 'Loading…',
    this.slowHint,
    this.slowAfter = const Duration(seconds: 5),
  });

  final String label;

  /// Shown after [slowAfter]. Null means this read is local and a delay would
  /// be a genuine surprise, so there is nothing useful to add.
  final String? slowHint;

  final Duration slowAfter;

  /// The standard wording for anything that waits on the trusted service.
  static const String serverWakingHint =
      'The server sleeps when it is idle and takes up to a minute to wake. '
      'Still waiting…';

  @override
  State<ContentLoading> createState() => _ContentLoadingState();
}

class _ContentLoadingState extends State<ContentLoading> {
  Timer? _timer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    if (widget.slowHint != null) {
      _timer = Timer(widget.slowAfter, () {
        if (mounted) setState(() => _slow = true);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      label: widget.label,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.gapXl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
                const SizedBox(height: AppTheme.gapMd),
                Text(
                  widget.label,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (_slow && widget.slowHint != null) ...[
                  const SizedBox(height: AppTheme.gapSm),
                  Text(
                    widget.slowHint!,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An inline note that appears only once a wait has become surprising.
///
/// The full-page [ContentLoading] covers a screen that has nothing to show yet.
/// This covers the other case: a form the user is looking at, with a button that
/// says "Registering…" and then says it for ninety seconds because the trusted
/// service is waking up. Renders nothing at all until [after], so a fast
/// response never shows it.
class SlowServerNote extends StatefulWidget {
  const SlowServerNote({
    super.key,
    this.message = ContentLoading.serverWakingHint,
    this.after = const Duration(seconds: 5),
  });

  final String message;
  final Duration after;

  @override
  State<SlowServerNote> createState() => _SlowServerNoteState();
}

class _SlowServerNoteState extends State<SlowServerNote> {
  Timer? _timer;
  bool _show = false;

  @override
  void initState() {
    super.initState();
    _timer = Timer(widget.after, () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_show) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: AppTheme.gapSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: AppTheme.gapSm),
          Expanded(
            child: Text(
              widget.message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Reusable empty state with a useful next action instead of a dead end.
class ContentEmpty extends StatelessWidget {
  const ContentEmpty({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapXl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  size: 30,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(height: AppTheme.gapMd),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppTheme.gapSm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: AppTheme.gapLg),
                FilledButton.icon(
                  onPressed: onAction,
                  icon: const Icon(Icons.arrow_forward),
                  label: Text(actionLabel!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
