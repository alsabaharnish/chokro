import 'package:flutter/material.dart';

import '../../core/theme.dart';
import 'brand_mark.dart';

/// Responsive presentation shared by sign-in and registration.
///
/// Wide screens receive an intentional brand panel instead of a narrow phone
/// form floating in a large blank canvas. On phones the same form becomes one
/// calm, scrollable card that remains usable with the keyboard and large text.
class AuthFrame extends StatelessWidget {
  const AuthFrame({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;

          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  scheme.surface,
                  scheme.primaryContainer.withValues(alpha: .32),
                ],
              ),
            ),
            child: Row(
              children: [
                if (wide) const Expanded(flex: 11, child: _BrandPanel()),
                Expanded(
                  flex: wide ? 10 : 1,
                  child: SafeArea(
                    child: Center(
                      child: SingleChildScrollView(
                        keyboardDismissBehavior:
                            ScrollViewKeyboardDismissBehavior.onDrag,
                        padding: EdgeInsets.symmetric(
                          horizontal: wide ? AppTheme.gapXl : AppTheme.gapMd,
                          vertical: AppTheme.gapLg,
                        ),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: AppTheme.maxFormWidth,
                          ),
                          child: Card(
                            color: scheme.surface.withValues(alpha: .94),
                            shadowColor: scheme.shadow.withValues(alpha: .15),
                            child: Padding(
                              padding: EdgeInsets.all(
                                constraints.maxWidth < 380
                                    ? AppTheme.gapMd
                                    : AppTheme.gapLg,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (!wide) ...[
                                    const Align(
                                      alignment: Alignment.centerLeft,
                                      child: BrandMark(
                                        size: 44,
                                        showWordmark: true,
                                      ),
                                    ),
                                    const SizedBox(height: AppTheme.gapXl),
                                  ],
                                  Text(
                                    'YOUR IMPACT ACCOUNT',
                                    style: Theme.of(context)
                                        .textTheme
                                        .labelSmall
                                        ?.copyWith(
                                          color: scheme.primary,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: 1.15,
                                        ),
                                  ),
                                  const SizedBox(height: AppTheme.gapSm),
                                  Text(
                                    title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -.6,
                                        ),
                                  ),
                                  const SizedBox(height: AppTheme.gapSm),
                                  Text(
                                    subtitle,
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: scheme.onSurfaceVariant,
                                          height: 1.45,
                                        ),
                                  ),
                                  const SizedBox(height: AppTheme.gapXl),
                                  child,
                                  const SizedBox(height: AppTheme.gapMd),
                                  Divider(color: scheme.outlineVariant),
                                  const SizedBox(height: AppTheme.gapMd),
                                  Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Icon(
                                        Icons.lock_outline_rounded,
                                        size: 17,
                                        color: scheme.onSurfaceVariant,
                                      ),
                                      const SizedBox(width: AppTheme.gapSm),
                                      Expanded(
                                        child: Text(
                                          'Your account keeps rewards and activity securely connected to you.',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: scheme.onSurfaceVariant,
                                              ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BrandPanel extends StatelessWidget {
  const _BrandPanel();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.all(AppTheme.gapXl),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(32),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [scheme.primary, scheme.tertiary],
            ),
          ),
          child: Stack(
            children: [
              const Positioned(right: -80, top: -60, child: _Orb(size: 260)),
              const Positioned(
                left: -110,
                bottom: -130,
                child: _Orb(size: 340),
              ),
              Padding(
                padding: const EdgeInsets.all(48),
                // Scrollable, like the form half already is. In a short browser
                // window this panel — the first thing every desktop visitor
                // sees — clipped its three trust pills with no way to reach
                // them. The `Spacer` has to go with it: `Expanded` under a
                // scroll view's unbounded main axis asserts at runtime.
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      BrandMark(
                        size: 56,
                        showWordmark: true,
                        foregroundColor: scheme.onPrimary,
                      ),
                      const SizedBox(height: AppTheme.gap2Xl),
                      Text(
                        'Every responsible action should count.',
                        style: theme.textTheme.displaySmall?.copyWith(
                          color: scheme.onPrimary,
                          fontWeight: FontWeight.w800,
                          height: 1.1,
                          letterSpacing: -1,
                        ),
                      ),
                      const SizedBox(height: AppTheme.gapMd),
                      Text(
                        'Verify recycling, build a transparent impact record, '
                        'and earn rewards you can trust.',
                        style: theme.textTheme.titleMedium?.copyWith(
                          color: scheme.onPrimary.withValues(alpha: .82),
                          height: 1.5,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                      const SizedBox(height: AppTheme.gapXl),
                      const Wrap(
                        spacing: 12,
                        runSpacing: 12,
                        children: [
                          _TrustPill(
                            icon: Icons.verified_user_outlined,
                            label: 'Verified evidence',
                          ),
                          _TrustPill(
                            icon: Icons.account_balance_wallet_outlined,
                            label: 'Auditable rewards',
                          ),
                          _TrustPill(
                            icon: Icons.storefront_outlined,
                            label: 'Circular marketplace',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Orb extends StatelessWidget {
  const _Orb({required this.size});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Theme.of(context).colorScheme.onPrimary.withValues(alpha: .07),
    ),
  );
}

class _TrustPill extends StatelessWidget {
  const _TrustPill({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: onPrimary.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: onPrimary.withValues(alpha: .16)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: onPrimary),
          const SizedBox(width: 8),
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: onPrimary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
