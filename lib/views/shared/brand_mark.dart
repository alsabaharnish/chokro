import 'package:flutter/material.dart';

/// Chokro's compact visual signature.
///
/// This stays code-native so it is crisp at every density, adapts to dark mode,
/// and does not add another network or asset dependency to startup.
class BrandMark extends StatelessWidget {
  const BrandMark({
    super.key,
    this.size = 48,
    this.showWordmark = false,
    this.foregroundColor,
  });

  final double size;
  final bool showWordmark;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final mark = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * .3),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primary, scheme.tertiary],
        ),
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: .2),
            blurRadius: size * .35,
            offset: Offset(0, size * .12),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(Icons.eco_rounded, size: size * .58, color: scheme.onPrimary),
    );

    if (!showWordmark) {
      return Semantics(label: 'Chokro', image: true, child: mark);
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ExcludeSemantics(child: mark),
        const SizedBox(width: 12),
        Text(
          'Chokro',
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.w800,
            letterSpacing: -.4,
            color: foregroundColor,
          ),
        ),
      ],
    );
  }
}
