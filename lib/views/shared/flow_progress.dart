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

  @override
  Size get preferredSize => const Size.fromHeight(42);

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
                Text(
                  'Step $current of $total',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(label, style: theme.textTheme.labelMedium),
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
