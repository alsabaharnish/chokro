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
class ActionCard extends StatelessWidget {
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

  bool get _enabled => onTap != null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (Color iconBackground, Color iconColour) = switch (tone) {
      ActionTone.primary => (scheme.primaryContainer, scheme.onPrimaryContainer),
      ActionTone.neutral => (
          scheme.tertiaryContainer,
          scheme.onTertiaryContainer,
        ),
      ActionTone.admin => (
          scheme.secondaryContainer,
          scheme.onSecondaryContainer,
        ),
    };

    final body = subtitle;
    final shownSubtitle = _enabled ? body : (disabledSubtitle ?? body);

    return Card(
      // Dim the whole card rather than only greying the text: a disabled card
      // that looks enabled invites the tap that does nothing.
      child: Opacity(
        opacity: _enabled ? 1 : 0.55,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppTheme.gapMd),
            child: Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: iconBackground,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(icon, color: iconColour, size: 22),
                ),
                const SizedBox(width: AppTheme.gapMd),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        shownSubtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ),
                ),
                if (badgeCount > 0) ...[
                  const SizedBox(width: AppTheme.gapSm),
                  _CountBadge(count: badgeCount),
                ],
                // The chevron is a hint that tapping goes somewhere. On a
                // disabled card it would be a lie, so it is dropped rather than
                // dimmed — which is what the original code did in three places
                // and forgot in the other five.
                if (_enabled)
                  Icon(
                    Icons.chevron_right,
                    color: scheme.onSurfaceVariant,
                  ),
              ],
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
      padding: const EdgeInsets.only(bottom: AppTheme.gapSm, top: AppTheme.gapXs),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 15, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
          ],
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}
