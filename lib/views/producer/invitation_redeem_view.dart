import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../../core/api_config.dart';
import '../../core/theme.dart';
import '../../core/validators.dart';
import '../shared/app_snackbar.dart';
import '../shared/auth_frame.dart';
import '../shared/notice_card.dart';

/// Redeeming a producer invitation (EPR-4, SEC-8).
///
/// ## Why this screen is not the registration form
///
/// `/register` creates a Champion: a name, an email and a password, and the
/// account exists. This creates a *member of a company's compliance workspace*,
/// and the difference is that the invitation token is the authorisation. There
/// is no self-registration into a producer organisation — a company's
/// compliance data is not something anyone should be able to join by filling in
/// a form — so this screen has no email field at all. The address is bound to
/// the token, server-side, and cannot be changed here.
///
/// ## Why the password rules come from the server
///
/// The policy is fetched rather than duplicated. A copy in Dart would be a
/// second definition of a control, and the two would drift — a form that
/// accepts what the server refuses is a person retyping a password they were
/// told was fine. So the client shows what the server says and lets the server
/// decide.
class InvitationRedeemView extends StatefulWidget {
  const InvitationRedeemView({super.key, required this.token});

  final String token;

  @override
  State<InvitationRedeemView> createState() => _InvitationRedeemViewState();
}

class _InvitationRedeemViewState extends State<InvitationRedeemView> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _client = http.Client();

  bool _submitting = false;
  bool _obscure = true;
  List<String> _requirements = const [];
  List<String> _rejected = const [];

  @override
  void initState() {
    super.initState();
    _loadPolicy();
  }

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _client.close();
    super.dispose();
  }

  Future<void> _loadPolicy() async {
    try {
      final response = await _client
          .get(ApiConfig.path('/epr/password-policy'))
          .timeout(ApiConfig.coldStartTimeout);
      if (response.statusCode != 200 || !mounted) return;
      final body = jsonDecode(response.body);
      final requirements = body is Map<String, dynamic>
          ? body['requirements']
          : null;
      if (requirements is List) {
        setState(() {
          _requirements = requirements.whereType<String>().toList();
        });
      }
    } catch (_) {
      // The form still works: the server validates regardless, and a missing
      // hint list is better than a screen that will not load because the free
      // instance is asleep.
    }
  }

  Future<void> _submit() async {
    if (_formKey.currentState?.validate() != true) return;

    final snack = AppSnackBar.of(context);
    setState(() {
      _submitting = true;
      _rejected = const [];
    });

    try {
      final response = await _client
          .post(
            ApiConfig.path('/epr/invitations/redeem'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode({
              'token': widget.token,
              'name': _name.text.trim(),
              'password': _password.text,
            }),
          )
          .timeout(ApiConfig.coldStartTimeout);

      final body = jsonDecode(response.body);
      final map = body is Map<String, dynamic> ? body : const <String, dynamic>{};

      if (response.statusCode == 201) {
        // Sign in with the credential just set, so the person lands in the
        // workspace rather than at a login form typing what they typed twice.
        await FirebaseAuth.instance.signInWithEmailAndPassword(
          email: map['email'] as String,
          password: _password.text,
        );
        // The address is verified from the workspace, which is where the
        // verification gate explains why it matters (EPR-5).
        await FirebaseAuth.instance.currentUser?.sendEmailVerification();
        if (!mounted) return;
        snack.success('Welcome. Verify your email address to continue.');
        context.go('/producer');
        return;
      }

      if (!mounted) return;

      if (map['error'] == 'weak_password') {
        final problems = map['problems'];
        setState(() {
          _submitting = false;
          _rejected = problems is List
              ? problems.whereType<String>().toList()
              : const [];
        });
        // Re-validating shows the server's own list under the field.
        _formKey.currentState?.validate();
        return;
      }

      setState(() => _submitting = false);
      snack.failure(
        map['message'] as String? ??
            'This invitation could not be redeemed. Ask for a new link.',
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      snack.failure(
        'Could not reach the service. It may be waking up — try again in a '
        'moment.',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AuthFrame(
      title: 'Join your company workspace',
      subtitle:
          'You have been invited to Chokro’s EPR producer portal. Set a name '
          'and a password to accept.',
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.token.isEmpty)
              const NoticeCard(
                icon: Icons.link_off_outlined,
                tone: NoticeTone.error,
                title: 'No invitation in this link',
                message:
                    'Open the invitation link you were sent, in full. Ask the '
                    'person who invited you for a new one if it was truncated.',
              )
            else ...[
              const NoticeCard(
                icon: Icons.mail_lock_outlined,
                message:
                    'Your work email address comes from the invitation and '
                    'cannot be changed here. That is what makes the link usable '
                    'only by you.',
              ),
              const SizedBox(height: AppTheme.gapLg),

              TextFormField(
                controller: _name,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Your name',
                  helperText:
                      'Shown to colleagues and recorded on the activity trail.',
                ),
                validator: validateName,
              ),
              const SizedBox(height: AppTheme.gapMd),

              TextFormField(
                controller: _password,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Choose a password',
                  // The server's own refusal, verbatim, under the field it
                  // concerns — not in a snackbar that slides away.
                  errorText: _rejected.isEmpty ? null : _rejected.join(' '),
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(
                      _obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    ),
                    tooltip: _obscure ? 'Show password' : 'Hide password',
                  ),
                ),
                validator: (value) => (value == null || value.isEmpty)
                    ? 'Choose a password.'
                    : null,
                onFieldSubmitted: (_) => _submitting ? null : _submit(),
              ),

              if (_requirements.isNotEmpty) ...[
                const SizedBox(height: AppTheme.gapSm),
                for (final requirement in _requirements)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 2),
                    child: Text(
                      '•  $requirement',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: AppTheme.gapXs),
                Text(
                  'A compliance workspace has no second factor yet, so the '
                  'password is the only one.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],

              const SizedBox(height: AppTheme.gapLg),
              FilledButton(
                onPressed: _submitting ? null : _submit,
                child: Text(_submitting ? 'Joining…' : 'Accept invitation'),
              ),
            ],

            const SizedBox(height: AppTheme.gapMd),
            TextButton(
              onPressed: () => context.go('/login'),
              child: const Text('Already have an account? Sign in'),
            ),
          ],
        ),
      ),
    );
  }
}
