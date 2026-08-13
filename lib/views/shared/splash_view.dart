import 'package:flutter/material.dart';

import '../../core/theme.dart';

/// Held while Firebase Auth resolves who is signed in.
///
/// This screen is the fix for a visible startup flaw: the router's redirect used
/// to read an unresolved auth state as "signed out", so every cold start showed
/// a signed-in user the login screen for a frame or two before replacing it with
/// their home screen. Waiting on a branded screen is honest — we genuinely do
/// not know yet — and it is what a user expects an app to do while it starts.
class SplashView extends StatelessWidget {
  const SplashView({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.eco, size: 72, color: theme.colorScheme.primary),
            const SizedBox(height: AppTheme.gapMd),
            Text(
              'Chokro',
              style: theme.textTheme.headlineSmall?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: AppTheme.gapXl),
            SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: theme.colorScheme.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
