import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/auth_controller.dart';
import '../../core/network_errors.dart';
import '../../core/theme.dart';
import 'app_snackbar.dart';

/// Recovery UI when Auth or the signed-in profile cannot be read.
///
/// A connection/service failure is not a missing account. Retrying these
/// providers preserves the destination held by the router and avoids telling a
/// healthy user to register again.
class StartupErrorView extends ConsumerWidget {
  const StartupErrorView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final auth = ref.watch(firebaseAuthStateProvider);
    final isSigningOut = ref.watch(authControllerProvider).isLoading;

    void retry() {
      ref.invalidate(firebaseAuthStateProvider);
      ref.invalidate(currentUserProvider);
    }

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTheme.gapXl),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppTheme.maxFormWidth,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.cloud_off_outlined,
                    size: 56,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: AppTheme.gapMd),
                  Text(
                    'Could not open your account',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppTheme.gapSm),
                  Text(
                    'Chokro could not reach the account service. Your profile '
                    'has not been changed. Check your connection and try again.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppTheme.gapLg),
                  FilledButton.icon(
                    onPressed: isSigningOut ? null : retry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                  if (auth.value != null) ...[
                    const SizedBox(height: AppTheme.gapSm),
                    OutlinedButton.icon(
                      // Awaited and reported. Fire-and-forget left a user on
                      // the app's recovery screen believing they had signed
                      // out on a handset the codebase itself describes as
                      // often shared or borrowed.
                      onPressed: isSigningOut
                          ? null
                          : () async {
                              final notify = AppSnackBar.of(context);
                              await ref
                                  .read(authControllerProvider.notifier)
                                  .signOut();
                              final error = ref
                                  .read(authControllerProvider)
                                  .error;
                              if (error != null) {
                                notify.failure(
                                  'Could not sign out. '
                                  '${friendlyErrorMessage(error)}',
                                );
                              }
                            },
                      icon: const Icon(Icons.logout),
                      label: Text(isSigningOut ? 'Signing out…' : 'Sign out'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
