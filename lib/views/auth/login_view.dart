import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../controllers/auth_controller.dart';
import '../../core/auth_errors.dart';
import '../../core/validators.dart';
import '../shared/app_snackbar.dart';
import '../shared/auth_frame.dart';

class LoginView extends ConsumerStatefulWidget {
  const LoginView({super.key});

  @override
  ConsumerState<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends ConsumerState<LoginView> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  /// Lets the email field's keyboard "next" key move focus to the password
  /// rather than dismissing itself, which is what it did before.
  final _passwordFocus = FocusNode();

  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  /// Sends a password-reset email (F1.1).
  ///
  /// Confirms the same way whether or not the address has an account — in the
  /// failure branch as well as the success one. A form that answered "no such
  /// account" would let anyone test which email addresses hold accounts, which
  /// is the same leak `authErrorMessage` avoids by keeping the three credential
  /// failures indistinguishable.
  ///
  /// The failure branch used to undo exactly that: it reported
  /// `authErrorMessage`, whose answer for `user-not-found` is "That email and
  /// password do not match" — a password on a screen that asks for none, and a
  /// confirmation that the address is unregistered. `passwordResetMessage`
  /// reports only the failures that are about the request itself.
  ///
  /// The email field is validated first, and reused, so someone who has already
  /// typed their address does not type it twice.
  Future<void> _forgotPassword() async {
    FocusScope.of(context).unfocus();

    final email = _emailController.text.trim();
    final invalid = validateEmail(email);

    if (invalid != null) {
      AppSnackBar.of(
        context,
      ).failure('Enter your email address first — $invalid.');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset your password?'),
        content: Text(
          'We will email a reset link to $email. Open it on this device and '
          'choose a new password.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send link'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    await ref.read(authControllerProvider.notifier).sendPasswordReset(email);
    if (!mounted) return;

    final error = ref.read(authControllerProvider).error;
    final notify = AppSnackBar.of(context);

    // Only failures about the *request* are reported. A failure that would
    // reveal whether the address is registered is folded back into the same
    // neutral confirmation a success gets — see `passwordResetMessage`. What
    // was here before reported `authErrorMessage`, so a reset for an unknown
    // address answered "That email and password do not match", which both
    // named a password nobody had typed and confirmed the account was absent.
    // An error that never became an `AuthFailure` did not come from Firebase
    // Auth at all, so it says nothing about who exists and must not be swallowed
    // into the neutral confirmation.
    final reportable = switch (error) {
      null => null,
      AuthFailure(:final code) => passwordResetMessage(code),
      _ => 'The reset link could not be sent. Try again in a moment.',
    };

    if (reportable != null) {
      notify.failure(reportable);
      return;
    }

    notify.info('If an account exists for $email, a reset link is on its way.');
  }

  Future<void> _submit() async {
    // Dismiss the keyboard first: the error snackbar appears at the bottom of
    // the screen, and an open keyboard covered it entirely on a small phone.
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) return;

    // Spoken as well as marked `liveRegion`: a live region on a node that is
    // newly *inserted*, rather than one whose label changes, is not reliably
    // announced on iOS.
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Signing in…',
      Directionality.of(context),
    );

    await ref
        .read(authControllerProvider.notifier)
        .signIn(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );

    if (!mounted) return;
    final error = ref.read(authControllerProvider).error;
    if (error == null) return;

    // The controller has already converted the vendor exception into something
    // readable. `error.toString()` used to land here, which put
    // "[firebase_auth/invalid-credential] The supplied auth credential is
    // incorrect, malformed or has expired." in front of someone who had
    // mistyped their password.
    //
    // `AppSnackBar` replaces a hand-built SnackBar that set
    // `backgroundColor: errorContainer` and left the content colour at
    // SnackBar's `onInverseSurface` default — 1.70:1 against that pink, so the
    // message was unreadable. It also collapses the one-at-a-time handling that
    // was written out here: tapping Sign In twice used to stack snackbars.
    AppSnackBar.of(
      context,
    ).failure(error is AuthFailure ? error.message : authErrorMessage(null));
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(authControllerProvider).isLoading;
    return AuthFrame(
      title: 'Welcome back',
      subtitle: 'Sign in to continue building your verified impact.',
      child: AutofillGroup(
        // AutofillGroup lets the platform password manager see the email and
        // password as one credential and offer to save it.
        child: Form(
          key: _formKey,
          // Only re-validates a field that is *already* showing an error, so
          // '2 more characters' clears as the user types them instead of
          // standing there contradicting the field it describes — while
          // nothing turns red before the first submit. `onUserInteraction`
          // would be too eager: it paints "that does not look like an email
          // address" under a half-typed address.
          autovalidateMode: AutovalidateMode.onUserInteractionIfError,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                // `username` first: iOS maps only the *first* hint to a
                // UITextContentType, and hinting this field as `email` alone
                // meant the saved Chokro credential was never offered back —
                // registration saved it, sign-in could not fill it. Android
                // reads the whole list and keeps the email classification.
                autofillHints: const [
                  AutofillHints.username,
                  AutofillHints.email,
                ],
                autocorrect: false,
                // Email addresses are case-insensitive and never
                // capitalised; the default sentence-case keyboard made
                // every address start with a capital on iOS.
                textCapitalization: TextCapitalization.none,
                enabled: !isLoading,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.email_outlined),
                ),
                validator: validateEmail,
                onFieldSubmitted: (_) => _passwordFocus.requestFocus(),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _passwordController,
                focusNode: _passwordFocus,
                obscureText: _obscurePassword,
                textInputAction: TextInputAction.done,
                autofillHints: const [AutofillHints.password],
                enabled: !isLoading,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outlined),
                  suffixIcon: IconButton(
                    tooltip: _obscurePassword
                        ? 'Show password'
                        : 'Hide password',
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: isLoading
                        ? null
                        : () => setState(
                            () => _obscurePassword = !_obscurePassword,
                          ),
                  ),
                ),
                // Only "required" on sign-in. A minimum length here was
                // wrong: it is a check on the password being *created*,
                // and applying it at sign-in refuses to even try an
                // older short password, showing a validation error where
                // the truthful answer is "that is not your password".
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Enter your password' : null,
                // The keyboard's done key submits, so the user never has
                // to dismiss it to reach the button.
                onFieldSubmitted: (_) => isLoading ? null : _submit(),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: isLoading ? null : _forgotPassword,
                  child: const Text('Forgot password?'),
                ),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: isLoading ? null : _submit,
                child: isLoading
                    // Named, because the button loses its own label while it
                    // spins. Against a cold-start host that can take 30-60 s
                    // to wake, a screen-reader user otherwise gets pure silence
                    // and taps again.
                    ? Semantics(
                        liveRegion: true,
                        label: 'Signing in…',
                        child: const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : const Text('Sign in'),
              ),
              const SizedBox(height: 12),
              // Wrap, not Row — the idiom auth_frame.dart already uses. As a
              // Row this clipped at large text sizes and the overflowing half
              // of 'Create account' was dead to touch, on the first screen of
              // the app and the only route to registration.
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('New to Chokro?'),
                  TextButton(
                    onPressed: isLoading ? null : () => context.go('/register'),
                    child: const Text('Create account'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
