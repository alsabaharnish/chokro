import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/profile_controller.dart';
import '../../core/constants.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../core/validators.dart';
import '../../models/user_model.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';

/// Profile management (F1.1).
///
/// What a user is allowed to change here is decided by `firestore.rules`, not by
/// this screen, and the rule is narrow: the diff may contain `name` and nothing
/// else. So the name is a field, and everything else on this screen is a fact.
///
/// Email is deliberately read-only. Changing a Firebase Auth email requires a
/// recent re-authentication and invalidates the sign-in the user is currently
/// holding; the rules do not permit writing it to the profile document either.
/// Showing it greyed out with a reason is honest — offering an input that could
/// only ever fail would not be.
class ProfileView extends ConsumerStatefulWidget {
  const ProfileView({super.key});

  @override
  ConsumerState<ProfileView> createState() => _ProfileViewState();
}

class _ProfileViewState extends ConsumerState<ProfileView> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();

  /// The name as stored, so "Save" can be offered only when something changed.
  String? _storedName;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Seeds the field from the profile, and re-seeds when the stored name
  /// changes underneath us — an admin renaming an account, or this screen's own
  /// save landing.
  ///
  /// Guarded on [_storedName] rather than done once in `initState`, because the
  /// profile stream may not have produced a value by then.
  void _syncFromProfile(UserModel user) {
    if (_storedName == user.name) return;

    final wasUnedited = _name.text == (_storedName ?? '');
    _storedName = user.name;

    // Only overwrite what the user is typing if they had not started editing.
    // Clobbering a half-typed name because a snapshot arrived would be worse
    // than showing a stale one.
    if (wasUnedited) _name.text = user.name;
  }

  bool get _isDirty => _name.text.trim() != (_storedName ?? '').trim();

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;

    final messenger = ScaffoldMessenger.of(context);
    await ref.read(profileControllerProvider.notifier).rename(_name.text);

    if (!mounted) return;
    final state = ref.read(profileControllerProvider);
    messenger.hideCurrentSnackBar();

    state.when(
      data: (_) {
        FocusScope.of(context).unfocus();
        messenger.showSnackBar(const SnackBar(content: Text('Name updated.')));
      },
      loading: () {},
      error: (error, _) => messenger.showSnackBar(
        SnackBar(
          content: Text(
            error is ProfileFailure
                ? error.message
                : 'The name could not be saved. Try again.',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(currentUserProvider);
    final saving = ref.watch(profileControllerProvider).isLoading;

    return AppShell(
      title: 'Profile',
      child: async.when(
        loading: () => const ContentLoading(label: 'Loading your profile…'),
        error: (error, _) => _Message(
          icon: Icons.error_outline,
          text:
              'Your profile could not be loaded. Check your connection and '
              'try again.',
        ),
        data: (user) {
          if (user == null) {
            return const _Message(
              icon: Icons.person_off_outlined,
              text: 'You are not signed in.',
            );
          }

          _syncFromProfile(user);

          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppTheme.maxFormWidth,
              ),
              child: ListView(
                padding: const EdgeInsets.all(AppTheme.gapMd),
                children: [
                  _Avatar(name: user.name),
                  const SizedBox(height: AppTheme.gapMd),

                  if (!user.isActive) ...[
                    _SuspensionNotice(user: user),
                    const SizedBox(height: AppTheme.gapMd),
                  ],

                  Text(
                    'Your name',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: AppTheme.gapSm),
                  Form(
                    key: _formKey,
                    child: TextFormField(
                      controller: _name,
                      enabled: !saving,
                      validator: validateName,
                      // Deliberately `onChanged` rather than a controller
                      // listener. `_syncFromProfile` writes `_name.text` from
                      // inside `build`, and a listener would fire on that write
                      // and call `setState` mid-build, which Flutter rejects
                      // outright. `onChanged` fires only for real typing, which
                      // is the only case the dirty check cares about.
                      onChanged: (_) => setState(() {}),
                      textCapitalization: TextCapitalization.words,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) {
                        if (_isDirty && !saving) _save();
                      },
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppTheme.gapSm),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.icon(
                      // Offered only when there is a change to save. A live
                      // "Save" that writes the same name would still cost a
                      // round trip and still say "Name updated".
                      onPressed: (_isDirty && !saving) ? _save : null,
                      icon: saving
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check, size: 18),
                      label: Text(saving ? 'Saving…' : 'Save'),
                    ),
                  ),

                  const SizedBox(height: AppTheme.gapLg),
                  Text(
                    'Account',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: AppTheme.gapSm),
                  _Fact(
                    icon: Icons.mail_outline,
                    label: 'Email',
                    value: user.email.isEmpty ? 'Not recorded' : user.email,
                    note: 'Used to sign in, and cannot be changed here.',
                  ),
                  _Fact(
                    icon: Icons.badge_outlined,
                    label: 'Role',
                    value: _roleLabel(user.role),
                    note: switch (user.role) {
                      AppConstants.roleAdmin =>
                        'You can review submissions and manage accounts.',
                      AppConstants.roleSeller =>
                        'You can list products in the marketplace.',
                      _ => null,
                    },
                  ),
                  _Fact(
                    icon: Icons.event_outlined,
                    label: 'Member since',
                    // Null only in the moment between registering and the
                    // server timestamp coming back, which `formatAge` reads as
                    // "just now" — which is exactly right at that moment.
                    value: user.createdAt == null
                        ? 'Just now'
                        : formatDate(user.createdAt!),
                  ),

                  if (user.role == AppConstants.roleBuyer) ...[
                    const SizedBox(height: AppTheme.gapLg),
                    OutlinedButton.icon(
                      onPressed: () => context.push('/apply-seller'),
                      icon: const Icon(Icons.storefront_outlined),
                      label: const Text('Apply to become a seller'),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  static String _roleLabel(String role) => switch (role) {
    AppConstants.roleAdmin => 'Administrator',
    AppConstants.roleSeller => 'Seller',
    AppConstants.roleBuyer => 'Buyer',
    _ => role,
  };
}

/// Initials on a coloured disc. No photo upload exists, and inventing one would
/// mean a storage bucket and a moderation problem F1.1 never asked for.
class _Avatar extends StatelessWidget {
  const _Avatar({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials = _initials(name);

    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            shape: BoxShape.circle,
          ),
          child: initials.isEmpty
              ? Icon(
                  Icons.person,
                  size: 36,
                  color: theme.colorScheme.onPrimaryContainer,
                )
              : Text(
                  initials,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onPrimaryContainer,
                  ),
                ),
        ),
      ],
    );
  }

  /// First letters of the first and last words, upper-cased.
  static String _initials(String name) {
    final words = name
        .trim()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '';
    if (words.length == 1) return words.first.characters.first.toUpperCase();
    return (words.first.characters.first + words.last.characters.first)
        .toUpperCase();
  }
}

/// A read-only account fact.
class _Fact extends StatelessWidget {
  const _Fact({
    required this.icon,
    required this.label,
    required this.value,
    this.note,
  });

  final IconData icon;
  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.gapMd),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: AppTheme.gapMd),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(value, style: theme.textTheme.bodyLarge),
                if (note != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    note!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Why the account cannot act, with the date if there is one.
class _SuspensionNotice extends StatelessWidget {
  const _SuspensionNotice({required this.user});

  final UserModel user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final until = user.suspendedUntil;

    return Container(
      padding: const EdgeInsets.all(AppTheme.gapMd),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.gpp_bad_outlined,
            color: theme.colorScheme.onErrorContainer,
          ),
          const SizedBox(width: AppTheme.gapSm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Account suspended',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
                const SizedBox(height: AppTheme.gapXs),
                Text(
                  until == null
                      ? 'Most actions are unavailable. Contact an '
                            'administrator to have this reviewed.'
                      : 'Most actions are unavailable until '
                            '${formatDate(until)}.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onErrorContainer,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapXl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: AppTheme.gapMd),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
