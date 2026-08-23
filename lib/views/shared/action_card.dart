import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Which container colour an [ActionCard]'s icon sits on.
///
/// A small fixed set rather than a free `Color`, so the home screen cannot drift
/// into eight subtly different greens. The tone carries meaning: [primary] is
/// the thing we want the user to do, [neutral] is somewhere to look at their own
/// records, [admin] marks a privileged action.
enum ActionTone { primary, neutral, admin }

/// A tappable row: icon, title, one line of explanation, chevron.
///
/// ## Why this exists
///
/// The home screen had **eight** hand-written copies of this widget — around 300
/// lines of `Card > InkWell > Padding > Row > CircleAvatar + Column + Icon` that
/// differed only in their icon, strings and colour. They had already drifted:
/// one was missing its `SizedBox` separator so it butted against the card above,
/// another had two stacked, and the disabled-state handling was inconsistent
/// between them.
///
/// One widget also means the accessibility work is done once. Each card is a
/// single semantic button with a merged label, rather than the four unrelated
/// nodes a screen reader used to walk through.
class ActionCard extends StatefulWidget {
  const ActionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.tone = ActionTone.neutral,
    this.badgeCount = 0,
    this.disabledSubtitle,
  });

  final IconData icon;
  final String title;

  /// Shown when the card is enabled.
  final String subtitle;

  /// Shown instead of [subtitle] when [onTap] is null. Saying *why* something is
  /// unavailable is the difference between a disabled control and a broken one.
  final String? disabledSubtitle;

  /// Null disables the card.
  final VoidCallback? onTap;

  final ActionTone tone;

  /// A count worth interrupting for — pending reviews, say. Zero hides it.
  final int badgeCount;

  @override
  State<ActionCard> createState() => _ActionCardState();
}

class _ActionCardState extends State<ActionCard> {
  bool _hovered = false;

  bool get _enabled => widget.onTap != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (
      Color iconBackground,
      Color iconColour,
      Color accent,
    ) = switch (widget.tone) {
      ActionTone.primary => (
        scheme.primaryContainer,
        scheme.onPrimaryContainer,
        scheme.primary,
      ),
      ActionTone.neutral => (
        scheme.tertiaryContainer,
        scheme.onTertiaryContainer,
        scheme.tertiary,
      ),
      ActionTone.admin => (
        scheme.secondaryContainer,
        scheme.onSecondaryContainer,
        scheme.secondary,
      ),
    };

    final body = widget.subtitle;
    final shownSubtitle = _enabled ? body : (widget.disabledSubtitle ?? body);

    return Semantics(
      button: true,
      enabled: _enabled,
      label:
          '${widget.title}. $shownSubtitle'
          '${widget.badgeCount > 0 ? ' ${widget.badgeCount} awaiting review.' : ''}',
      excludeSemantics: true,
      child: MouseRegion(
        onEnter: _enabled ? (_) => setState(() => _hovered = true) : null,
        onExit: _enabled ? (_) => setState(() => _hovered = false) : null,
        cursor: _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          constraints: const BoxConstraints(minHeight: 112),
          transform: _hovered
              ? Matrix4.translationValues(0, -2, 0)
              : Matrix4.identity(),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(AppTheme.radiusMd),
            border: Border.all(
              color: _hovered
                  ? accent.withValues(alpha: .45)
                  : scheme.outlineVariant,
            ),
            boxShadow: _hovered
                ? [
                    BoxShadow(
                      color: scheme.shadow.withValues(alpha: .1),
                      blurRadius: 24,
                      offset: const Offset(0, 10),
                    ),
                  ]
                : const [],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppTheme.radiusMd - 1),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.onTap,
                child: Opacity(
                  // Dim the whole card rather than only greying the text: a
                  // disabled card that looks enabled invites a dead tap.
                  opacity: _enabled ? 1 : .5,
                  child: Padding(
                    padding: const EdgeInsets.all(18),
                    child: Row(
                      children: [
                        Container(
                          width: 52,
                          height: 52,
                          decoration: BoxDecoration(
                            color: iconBackground,
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: Icon(widget.icon, color: iconColour, size: 24),
                        ),
                        const SizedBox(width: AppTheme.gapMd),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                widget.title,
                                style: theme.textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: AppTheme.gapXs),
                              Text(
                                shownSubtitle,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (widget.badgeCount > 0) ...[
                          const SizedBox(width: AppTheme.gapSm),
                          _CountBadge(count: widget.badgeCount),
                        ],
                        // This compact circular affordance is easier to parse
                        // than a loose chevron at the edge of a wide card.
                        if (_enabled) ...[
                          const SizedBox(width: AppTheme.gapSm),
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: _hovered
                                  ? accent.withValues(alpha: .12)
                                  : scheme.surfaceContainerLow,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              Icons.arrow_forward_rounded,
                              size: 17,
                              color: _hovered
                                  ? accent
                                  : scheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The count of outstanding items.
///
/// Material's [Badge] is built to sit on top of another widget; used inline it
/// needed a dummy `SizedBox` child, which is what the home screen did. This is
/// just the pill.
class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.error,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        // A three-digit badge stretches the row and nobody reads the exact
        // number past a point.
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
          color: scheme.onError,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// A small caps label separating groups of cards.
///
/// The admin cards used to run straight on from the user's own, so the home
/// screen read as one undifferentiated list of eight things and an administrator
/// had to know by memory which four were theirs.
class SectionHeading extends StatelessWidget {
  const SectionHeading(this.label, {super.key, this.icon});

  final String label;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12, top: AppTheme.gapXs),
      child: Row(
        children: [
          if (icon != null) ...[
            Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(
                icon,
                size: 17,
                color: theme.colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 10),
          ],
          Text(
            label,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -.3,
            ),
          ),
        ],
      ),
    );
  }
}
