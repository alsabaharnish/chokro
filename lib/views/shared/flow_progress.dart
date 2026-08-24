import 'package:flutter/material.dart';

/// Compact progress shown below an AppBar for a short, fixed workflow.
///
/// It gives both a number and a text label, so progress is not communicated by
/// colour/position alone and remains clear to screen-reader users.
class FlowProgress extends StatelessWidget implements PreferredSizeWidget {
  const FlowProgress({
    super.key,
    required this.current,
    required this.total,
    required this.label,
  }) : assert(current >= 1 && current <= total);

  final int current;
  final int total;
  final String label;

  /// The bar has to declare its height to [AppBar], and that getter has no
  /// [BuildContext] to read a text scale from — so a hardcoded 42 was a height
  /// that only worked at scale 1.0. From Android's "Large" font setting (~1.3)
  /// upwards the row no longer fit and the strip overflowed: 18 px over at 1.3,
  /// 86 at 1.6, 178 at 2.0, on all four steps of the disposal flow.
  ///
  /// The platform dispatcher carries the same OS text scale that
  /// `MediaQuery.textScalerOf` hands the build below, and it is readable
  /// without a context. `scale(24) + 18` reproduces the old 42 exactly at
  /// scale 1.0, so nothing moves for a user who has not changed their font
  /// size, and grows from there.
  @override
  Size get preferredSize {
    final scaler = TextScaler.linear(
      WidgetsBinding.instance.platformDispatcher.textScaleFactor,
    );
    return Size.fromHeight(scaler.scale(24) + 18);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Semantics(
      label: 'Step $current of $total: $label',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                // Both labels flex. The step counter is the one that must stay
                // whole — "Step 3 of 4" is the progress — so the step name is
                // the one allowed to ellipsise when the two cannot both fit.
                Text(
                  'Step $current of $total',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: current / total,
              minHeight: 4,
              borderRadius: BorderRadius.circular(99),
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ],
        ),
      ),
    );
  }
}
