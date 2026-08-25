import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../controllers/auth_controller.dart';
import '../../core/auth_errors.dart';
import '../../core/validators.dart';
import '../shared/app_snackbar.dart';
import '../shared/auth_frame.dart';

class RegisterView extends ConsumerStatefulWidget {
  const RegisterView({super.key});

  @override
  ConsumerState<RegisterView> createState() => _RegisterViewState();
}

class _RegisterViewState extends ConsumerState<RegisterView> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  final _emailFocus = FocusNode();
  final _passwordFocus = FocusNode();

  bool _obscurePassword = true;

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocus.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    if (!_formKey.currentState!.validate()) return;

    // See login_view: a live region on a newly inserted node is not reliably
    // announced on iOS, so the wait is spoken explicitly too.
    SemanticsService.sendAnnouncement(
      View.of(context),
      'Creating your account…',
      Directionality.of(context),
    );

    await ref
        .read(authControllerProvider.notifier)
        .signUp(
          name: _nameController.text.trim(),
          email: _emailController.text.trim(),
          password: _passwordController.text,
        );

    if (!mounted) return;
    final error = ref.read(authControllerProvider).error;
    if (error == null) {
      // Tell the platform's password manager the credential is worth saving.
      // Without this it never offers, because the fields are gone by the time
      // the router has replaced this screen with home.
      TextInput.finishAutofillContext();
      return;
    }

    // Was a hand-built SnackBar with `backgroundColor: errorContainer` over
    // SnackBar's default `onInverseSurface` text: 1.70:1, i.e. unreadable. So
    // every registration failure reported itself invisibly.
    //
    // The already-registered case carries the remedy it names. It is the most
    // common registration failure, and stating "Sign in instead" without
    // offering it left the user to dismiss the bar, hunt for a small text link
    // and retype the email they had just entered. `AuthFailure.code` is
    // retained precisely so callers can branch without re-parsing the message.
    final failure = error is AuthFailure ? error : null;
    final router = GoRouter.of(context);
    AppSnackBar.of(context).failure(
      failure?.message ?? authErrorMessage(null),
      actionLabel: failure?.code == 'email-already-in-use' ? 'Sign in' : null,
      onAction: failure?.code == 'email-already-in-use'
          ? () => router.go('/login')
          : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(authControllerProvider).isLoading;
    return AuthFrame(
      title: 'Create your account',
      subtitle: 'Turn responsible actions into a transparent impact record.',
      child: AutofillGroup(
        child: Form(
          key: _formKey,
          // Clears a stale validation message as the user fixes the field.
          // Without it, '2 more characters' kept saying so after they were
          // typed — a factually wrong instruction about the text currently in
          // the field, on the app's first-run screen.
          autovalidateMode: AutovalidateMode.onUserInteractionIfError,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _nameController,
                textCapitalization: TextCapitalization.words,
                textInputAction: TextInputAction.next,
                autofillHints: const [AutofillHints.name],
                enabled: !isLoading,
                decoration: const InputDecoration(
                  labelText: 'Full name',
                  prefixIcon: Icon(Icons.person_outlined),
                ),
                validator: validateName,
                onFieldSubmitted: (_) => _emailFocus.requestFocus(),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _emailController,
                focusNode: _emailFocus,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                // Paired with `email` so iOS types the field as well: the
                // sign-in screen hints `username` first, and the two halves of
                // one credential have to agree for the manager to fill it back.
                autofillHints: const [
                  AutofillHints.newUsername,
                  AutofillHints.email,
                ],
                autocorrect: false,
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
                autofillHints: const [AutofillHints.newPassword],
                enabled: !isLoading,
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outlined),
                  helperText: 'At least six characters',
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
                validator: validateNewPassword,
                onFieldSubmitted: (_) => isLoading ? null : _submit(),
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: isLoading ? null : _submit,
                child: isLoading
                    ? Semantics(
                        liveRegion: true,
                        label: 'Creating your account…',
                        child: const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : const Text('Create account'),
              ),
              const SizedBox(height: 12),
              // Wrap, not Row — see the sibling change in login_view.dart.
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text('Already a member?'),
                  TextButton(
                    onPressed: isLoading ? null : () => context.go('/login'),
                    child: const Text('Sign in'),
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
