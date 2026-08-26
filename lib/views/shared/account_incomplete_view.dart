import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/auth_controller.dart';
import '../../core/network_errors.dart';
import '../../core/theme.dart';
import 'app_snackbar.dart';

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
class AccountIncompleteView extends ConsumerStatefulWidget {
  const AccountIncompleteView({super.key});

  @override
  ConsumerState<AccountIncompleteView> createState() =>
      _AccountIncompleteViewState();
}

class _AccountIncompleteViewState extends ConsumerState<AccountIncompleteView> {
  bool _checking = false;

  /// Re-reads the profile and says what it found.
  ///
  /// Both buttons on this screen used to be fire-and-forget, so the app's
  /// designated escape hatch from a broken account could fail twice over in
  /// silence — returning the user to exactly the trapped state this screen
  /// exists to end, with no evidence anything had been attempted. Repeated taps
  /// then read as a frozen screen.
  Future<void> _retry() async {
    final notify = AppSnackBar.of(context);
    setState(() => _checking = true);
    try {
      final user = await ref.refresh(currentUserProvider.future);
      if (!mounted) return;
      // On success the router's gate moves on by itself and this screen is
      // gone, so there is only ever a message to show in the failing case.
      if (user == null) {
        notify.failure(
          'Your profile is still missing. Sign out and register again, or ask '
          'a 3ZERO Admin to check the account.',
        );
      }
    } catch (error) {
      if (!mounted) return;
      notify.failure(
        'The account could not be checked. ${friendlyErrorMessage(error)}',
      );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _signOut() async {
    final notify = AppSnackBar.of(context);
    await ref.read(authControllerProvider.notifier).signOut();
    if (!mounted) return;
    final error = ref.read(authControllerProvider).error;
    if (error != null) {
      notify.failure('Could not sign out. ${friendlyErrorMessage(error)}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSigningOut = ref.watch(authControllerProvider).isLoading;
    final busy = isSigningOut || _checking;

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
                    // Refreshing re-subscribes, and if the document is there
                    // after all the router's gate moves on by itself.
                    onPressed: busy ? null : _retry,
                    icon: _checking
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh),
                    label: Text(_checking ? 'Checking…' : 'Try again'),
                  ),
                  const SizedBox(height: AppTheme.gapSm),
                  OutlinedButton.icon(
                    onPressed: busy ? null : _signOut,
                    icon: const Icon(Icons.logout),
                    label: Text(isSigningOut ? 'Signing out…' : 'Sign out'),
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
