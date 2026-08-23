import 'package:flutter/material.dart';

/// Chokro's compact visual signature.
///
/// The same art is used for the installed app icon, web splash, and in-product
/// navigation so Chokro has one recognisable signature everywhere.
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
        boxShadow: [
          BoxShadow(
            color: scheme.primary.withValues(alpha: .2),
            blurRadius: size * .35,
            offset: Offset(0, size * .12),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(size * .3),
        child: Image.asset(
          'assets/brand/chokro_app_icon.png',
          width: size,
          height: size,
          fit: BoxFit.cover,
          filterQuality: FilterQuality.medium,
        ),
      ),
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
