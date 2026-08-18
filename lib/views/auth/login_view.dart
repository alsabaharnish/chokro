import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../controllers/auth_controller.dart';
import '../../core/auth_errors.dart';
import '../../core/theme.dart';
import '../../core/validators.dart';

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
  /// Confirms the same way whether or not the address has an account. Firebase
  /// does not report which, and this must not imply it either — a form that
  /// answered "no such account" would let anyone test which email addresses hold
  /// accounts. That is the same leak `authErrorMessage` avoids by keeping the
  /// three credential failures indistinguishable, and it would be a poor place to
  /// undo it.
  ///
  /// The email field is validated first, and reused, so someone who has already
  /// typed their address does not type it twice.
  Future<void> _forgotPassword() async {
    FocusScope.of(context).unfocus();

    final email = _emailController.text.trim();
    final invalid = validateEmail(email);

    if (invalid != null) {
      final scheme = Theme.of(context).colorScheme;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Enter your email address first — $invalid.'),
            backgroundColor: scheme.errorContainer,
          ),
        );
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
    final scheme = Theme.of(context).colorScheme;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          // A malformed address is worth reporting — that is about the text
          // typed, not about who exists. Anything else confirms, including the
          // case where no account has that address.
          content: Text(
            error == null
                ? 'If an account exists for $email, a reset link is on its way.'
                : (error is AuthFailure ? error.message : authErrorMessage(null)),
          ),
          backgroundColor: error == null ? null : scheme.errorContainer,
          showCloseIcon: true,
        ),
      );
  }

  Future<void> _submit() async {
    // Dismiss the keyboard first: the error snackbar appears at the bottom of
    // the screen, and an open keyboard covered it entirely on a small phone.
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) return;

    await ref.read(authControllerProvider.notifier).signIn(
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );

    if (!mounted) return;
    final error = ref.read(authControllerProvider).error;
    if (error == null) return;

    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      // One message at a time. Tapping Sign In twice used to stack snackbars,
      // so the second attempt's result queued behind the first.
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            // The controller has already converted the vendor exception into
            // something readable. `error.toString()` used to land here, which
            // put "[firebase_auth/invalid-credential] The supplied auth
            // credential is incorrect, malformed or has expired." in front of
            // someone who had mistyped their password.
            error is AuthFailure ? error.message : authErrorMessage(null),
          ),
          backgroundColor: scheme.errorContainer,
          showCloseIcon: true,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(authControllerProvider).isLoading;
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppTheme.gapLg),
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: AppTheme.maxFormWidth),
              // AutofillGroup lets the platform password manager see the email
              // and password as one credential and offer to save it.
              child: AutofillGroup(
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Icon(Icons.eco,
                          size: 64, color: theme.colorScheme.primary),
                      const SizedBox(height: AppTheme.gapMd),
                      Text(
                        'Chokro',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: AppTheme.gapSm),
                      Text(
                        'Sign in to continue',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: AppTheme.gapXl),
                      TextFormField(
                        controller: _emailController,
                        keyboardType: TextInputType.emailAddress,
                        textInputAction: TextInputAction.next,
                        autofillHints: const [AutofillHints.email],
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
                      const SizedBox(height: AppTheme.gapMd),
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
                            tooltip:
                                _obscurePassword ? 'Show password' : 'Hide password',
                            icon: Icon(_obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined),
                            onPressed: () => setState(
                                () => _obscurePassword = !_obscurePassword),
                          ),
                        ),
                        // Only "required" on sign-in. A minimum length here was
                        // wrong: it is a check on the password being *created*,
                        // and applying it at sign-in refuses to even try an
                        // older short password, showing a validation error where
                        // the truthful answer is "that is not your password".
                        validator: (v) => (v == null || v.isEmpty)
                            ? 'Enter your password'
                            : null,
                        // The keyboard's done key submits, so the user never has
                        // to dismiss it to reach the button.
                        onFieldSubmitted: (_) => isLoading ? null : _submit(),
                      ),
                      const SizedBox(height: AppTheme.gapLg),
                      FilledButton(
                        onPressed: isLoading ? null : _submit,
                        child: isLoading
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Text('Sign In'),
                      ),
                      const SizedBox(height: AppTheme.gapSm),
                      TextButton(
                        onPressed: isLoading ? null : _forgotPassword,
                        child: const Text('Forgot your password?'),
                      ),
                      TextButton(
                        onPressed: isLoading ? null : () => context.go('/register'),
                        child: const Text("Don't have an account? Register"),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
