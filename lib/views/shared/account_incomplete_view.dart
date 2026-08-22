import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/auth_controller.dart';
import '../../core/theme.dart';

/// Firebase has a session, but Firestore has no `users/{uid}` for it.
///
/// Registration creates the auth account first and the profile document second
/// (`AuthController.signUp`). If the second step fails — rules, connection, a
/// half-applied batch — the result is an account that can authenticate and do
/// nothing else: no role to gate routes on, no name to greet, no wallet.
///
/// Both the original code and the first version of this router's gate left such
/// a user watching a spinner that would never stop, because there was no state
/// that said "this will not resolve". This screen is that state. It cannot repair
/// the account from the client — writing a profile for an arbitrary uid is
/// exactly what the security rules refuse — so it does the two things it can:
/// retry, in case the read simply failed, and sign out, so the user is not
/// trapped.
class AccountIncompleteView extends ConsumerWidget {
  const AccountIncompleteView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isSigningOut = ref.watch(authControllerProvider).isLoading;

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
                    Icons.person_off_outlined,
                    size: 56,
                    color: theme.colorScheme.error,
                  ),
                  const SizedBox(height: AppTheme.gapMd),
                  Text(
                    'Your profile is missing',
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppTheme.gapSm),
                  Text(
                    'You are signed in, but the account details that go with '
                    'this sign-in could not be found. This usually means '
                    'registration was interrupted part-way through.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppTheme.gapLg),
                  FilledButton.icon(
                    // The profile stream may simply have failed to read.
                    // Invalidating re-subscribes, and if the document is there
                    // after all the router's gate moves on by itself.
                    onPressed: isSigningOut
                        ? null
                        : () => ref.invalidate(currentUserProvider),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                  const SizedBox(height: AppTheme.gapSm),
                  OutlinedButton.icon(
                    onPressed: isSigningOut
                        ? null
                        : () => ref
                              .read(authControllerProvider.notifier)
                              .signOut(),
                    icon: const Icon(Icons.logout),
                    label: const Text('Sign out'),
                  ),
                  const SizedBox(height: AppTheme.gapMd),
                  Text(
                    'If this keeps happening, register again with a different '
                    'email or ask a 3ZERO Admin to check the account.',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
