import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme.dart';

/// Shown when a navigation lands on a path with no route.
///
/// The router had no `errorBuilder`, which meant go_router's own bare-bones
/// error page — an unstyled exception dump with no way back. Reachable in
/// practice from a stale deep link, a mistyped URL on the web build, or a route
/// removed between app versions.
class RouteErrorView extends StatelessWidget {
  const RouteErrorView({super.key, required this.location});

  /// The path that failed to resolve. Shown because it is the one useful fact
  /// here, and it is the user's own input rather than internal detail.
  final String location;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Page not found')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.gapXl),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppTheme.maxFormWidth),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.explore_off_outlined,
                  size: 56,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: AppTheme.gapMd),
                Text(
                  'There is nothing here',
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: AppTheme.gapSm),
                Text(
                  'The link you followed points at "$location", which this '
                  'version of the app does not have.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: AppTheme.gapLg),
                FilledButton.icon(
                  onPressed: () => context.go('/home'),
                  icon: const Icon(Icons.home_outlined),
                  label: const Text('Go to home'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
