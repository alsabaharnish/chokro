import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/account_profile_controller.dart';
import '../../controllers/profile_controller.dart';
import '../../controllers/push_controller.dart';
import '../../core/account_profile.dart';
import '../../core/image_delivery.dart';
import '../../core/constants.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../core/validators.dart';
import '../../models/user_model.dart';
import '../../services/push_service.dart';
import '../shared/account_profile_switcher.dart';
import '../shared/app_shell.dart';
import '../shared/app_snackbar.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';

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

class _ProfileViewState extends ConsumerState<ProfileView>
    with WidgetsBindingObserver {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  bool _notificationBusy = false;

  /// The name as stored, so "Save" can be offered only when something changed.
  String? _storedName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _name.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && PushService.isSupported) {
      // A denied permission can only be restored in system settings. Recheck
      // as soon as the user returns so the card updates and the device token is
      // registered without requiring another sign-in.
      unawaited(ref.read(pushRegistrarProvider).refreshPermission());
    }
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

  Future<void> _chooseProfilePhoto() async {
    final messenger = ScaffoldMessenger.of(context);

    try {
      final selected = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 90,
      );
      if (selected == null) return;

      final original = await selected.readAsBytes();
      final compressed = await FlutterImageCompress.compressWithList(
        original,
        quality: 78,
        minWidth: 640,
        minHeight: 640,
        keepExif: false,
      );
      if (compressed.isEmpty) {
        throw const ProfileFailure(
          'That picture could not be processed. Choose another one.',
        );
      }

      await ref
          .read(profileControllerProvider.notifier)
          .updatePhoto(compressed);
      if (!mounted) return;

      final result = ref.read(profileControllerProvider);
      messenger.hideCurrentSnackBar();
      result.when(
        data: (_) => messenger.showSnackBar(
          const SnackBar(content: Text('Profile picture updated.')),
        ),
        loading: () {},
        error: (error, _) => messenger.showSnackBar(
          SnackBar(
            content: Text(
              error is ProfileFailure
                  ? error.message
                  : 'The profile picture could not be saved. Try again.',
            ),
          ),
        ),
      );
    } on ProfileFailure catch (error) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } catch (_) {
      if (!mounted) return;
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            kIsWeb
                ? 'The picture picker could not be opened. Try another image.'
                : 'The photo library could not be opened. Check app permission.',
          ),
        ),
      );
    }
  }

  Future<void> _enableNotifications() async {
    if (_notificationBusy) return;
    setState(() => _notificationBusy = true);
    final notify = AppSnackBar.of(context);
    final granted = await ref.read(pushRegistrarProvider).enableNotifications();
    if (!mounted) return;
    setState(() => _notificationBusy = false);
    ref.invalidate(pushPermissionProvider);
    if (granted) {
      notify.success('Notifications are enabled on this device.');
    } else {
      notify.info(
        'Notifications remain off. You can enable them later from device settings.',
      );
    }
  }

  Future<void> _openNotificationSettings() async {
    final opened = await ref.read(pushServiceProvider).openAppSettings();
    if (!mounted || opened) return;
    AppSnackBar.of(context).failure(
      'Device settings could not be opened. Open Chokro in Settings and allow notifications.',
    );
  }

  Widget _notificationControl(AsyncValue<PushPermissionStatus> permission) {
    return permission.when(
      loading: () => const NoticeCard(
        icon: Icons.notifications_outlined,
        title: 'Checking notifications',
        message: 'Reading this device’s notification setting…',
      ),
      error: (_, _) => NoticeCard(
        icon: Icons.sync_problem_outlined,
        title: 'Notification setting unavailable',
        message:
            'The setting could not be read. Your in-app history still '
            'shows every decision.',
        tone: NoticeTone.warning,
        action: NoticeAction(
          label: 'Check again',
          onPressed: () => ref.invalidate(pushPermissionProvider),
        ),
      ),
      data: (status) => switch (status) {
        PushPermissionStatus.unsupported => const SizedBox.shrink(),
        PushPermissionStatus.enabled => const _Fact(
          icon: Icons.notifications_active_outlined,
          label: 'Notifications',
          value: 'Enabled on this device',
          note:
              'Chokro can alert you when a disposal or eco-action is decided.',
        ),
        PushPermissionStatus.notDetermined => NoticeCard(
          icon: Icons.notifications_outlined,
          title: _notificationBusy
              ? 'Enabling notifications…'
              : 'Know when a decision is ready',
          message:
              'Allow Chokro to alert you when a disposal or eco-action is '
              'approved or rejected. Your submission history remains '
              'available either way.',
          action: _notificationBusy
              ? null
              : NoticeAction(
                  label: 'Enable notifications',
                  onPressed: _enableNotifications,
                ),
        ),
        PushPermissionStatus.denied => NoticeCard(
          icon: Icons.notifications_off_outlined,
          title: 'Notifications are off',
          message:
              'Decision alerts are blocked for this device. Your histories '
              'still contain every result; device settings can restore alerts.',
          tone: NoticeTone.warning,
          action: NoticeAction(
            label: 'Open device settings',
            onPressed: _openNotificationSettings,
          ),
        ),
        PushPermissionStatus.unavailable => NoticeCard(
          icon: Icons.sync_problem_outlined,
          title: 'Notification setting unavailable',
          message:
              'The setting could not be read. Your in-app history still shows '
              'every decision.',
          tone: NoticeTone.warning,
          action: NoticeAction(
            label: 'Check again',
            onPressed: () => ref.invalidate(pushPermissionProvider),
          ),
        ),
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final async = ref.watch(currentUserProvider);
    final saving = ref.watch(profileControllerProvider).isLoading;
    final activeProfile = ref.watch(activeAccountProfileProvider);
    final notificationPermission = PushService.isSupported
        ? ref.watch(pushPermissionProvider)
        : null;

    return AppShell(
      title: 'Profile',
      child: async.when(
        loading: () => const ContentLoading(label: 'Loading your profile…'),
        // Told the user to "try again" on a screen that offered nothing to try
        // it with, and never named the cause — a permission-denied after a role
        // or suspension change looked identical to a flaky connection.
        error: (error, _) => ErrorRetry(
          error: error,
          title: 'Your profile',
          onRetry: () => ref.invalidate(currentUserProvider),
        ),
        data: (user) {
          // Watched rather than read off `user` directly, so a timed suspension
          // lifts the moment it expires. This screen has no refresh gesture, so
          // without it a lapsed suspension persisted for the whole session with
          // no discoverable remedy.
          final active = ref.watch(accountActivityProvider);
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
                  _Avatar(
                    user: user,
                    canEdit: activeProfile == AccountProfile.champion && active,
                    isBusy: saving,
                    onUpload: _chooseProfilePhoto,
                  ),
                  const SizedBox(height: AppTheme.gapMd),
                  const AccountProfileSwitcher(),
                  const SizedBox(height: AppTheme.gapMd),

                  if (!active) ...[
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
                    label: 'Profiles on this account',
                    value: accountProfilesForRole(
                      user.role,
                    ).map((profile) => profile.label).join('\n'),
                    note:
                        'Switching profiles changes your workspace, not your sign-in.',
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

                  if (notificationPermission != null) ...[
                    _notificationControl(notificationPermission),
                    const SizedBox(height: AppTheme.gapMd),
                  ],

                  if (user.role == AppConstants.roleBuyer) ...[
                    const SizedBox(height: AppTheme.gapLg),
                    // Gated like the donate button below it. Left enabled, the
                    // tap was refused by `requireSeller` and landed the user on
                    // /home — silently ejected from the screen they were on,
                    // with three controls on one screen disagreeing about the
                    // same suspension.
                    OutlinedButton.icon(
                      onPressed: active
                          ? () => context.push('/apply-seller')
                          : null,
                      icon: const Icon(Icons.storefront_outlined),
                      label: Text(
                        active
                            ? 'Become a 3ZERO Greenpreneur'
                            : 'Become a 3ZERO Greenpreneur — unavailable '
                                  'while suspended',
                      ),
                    ),
                  ],
                  const SizedBox(height: AppTheme.gapSm),
                  OutlinedButton.icon(
                    onPressed: active
                        ? () {
                            ref
                                .read(accountProfileControllerProvider.notifier)
                                .select(AccountProfile.champion);
                            context.push('/donate');
                          }
                        : null,
                    icon: const Icon(Icons.volunteer_activism_outlined),
                    label: const Text('Support green initiatives'),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The Champion portrait, with initials as a resilient fallback.
class _Avatar extends StatelessWidget {
  const _Avatar({
    required this.user,
    required this.canEdit,
    required this.isBusy,
    required this.onUpload,
  });

  final UserModel user;
  final bool canEdit;
  final bool isBusy;
  final VoidCallback onUpload;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final initials = _initials(user.name);
    final photoUrl = user.hasProfilePhoto ? user.profilePhotoUrl : null;

    return Column(
      children: [
        Semantics(
          image: true,
          label: photoUrl == null
              ? 'Profile picture placeholder for ${user.name}'
              : 'Profile picture for ${user.name}',
          child: Container(
            width: 88,
            height: 88,
            clipBehavior: Clip.antiAlias,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              shape: BoxShape.circle,
              border: Border.all(
                color: theme.colorScheme.primary.withValues(alpha: 0.22),
                width: 2,
              ),
            ),
            child: photoUrl == null
                ? _Initials(initials: initials)
                : CachedNetworkImage(
                    imageUrl: thumbnailUrl(photoUrl, width: 88),
                    memCacheWidth: decodeWidthFor(88),
                    width: 88,
                    height: 88,
                    fit: BoxFit.cover,
                    placeholder: (_, _) => const Center(
                      child: SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                    errorWidget: (_, _, _) => _Initials(initials: initials),
                  ),
          ),
        ),
        const SizedBox(height: AppTheme.gapSm),
        if (canEdit)
          TextButton.icon(
            onPressed: isBusy ? null : onUpload,
            icon: isBusy
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    photoUrl == null
                        ? Icons.add_a_photo_outlined
                        : Icons.edit_outlined,
                    size: 18,
                  ),
            label: Text(
              photoUrl == null ? 'Add profile picture' : 'Change picture',
            ),
          ),
        Text(
          !user.isActive
              ? 'Profile-picture changes are paused while this account is suspended.'
              : canEdit
              ? 'Your picture appears only on eco-action cards you submit with named sharing. Changing it later does not change earlier permission snapshots.'
              : 'Switch to your Champion profile to manage your public picture.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// Compiled once rather than on each call.
  static final RegExp _whitespace = RegExp(r'\s+');

  /// First letters of the first and last words, upper-cased.
  static String _initials(String name) {
    final words = name
        .trim()
        .split(_whitespace)
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return '';
    if (words.length == 1) return words.first.characters.first.toUpperCase();
    return (words.first.characters.first + words.last.characters.first)
        .toUpperCase();
  }
}

class _Initials extends StatelessWidget {
  const _Initials({required this.initials});

  final String initials;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return initials.isEmpty
        ? Icon(
            Icons.person,
            size: 40,
            color: theme.colorScheme.onPrimaryContainer,
          )
        : Text(
            initials,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.bold,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          );
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
                      ? 'Most actions are unavailable. Contact a 3ZERO Admin '
                            'to have this reviewed.'
                      // The admin sets an exact time, so show one. A bare
                      // date reads as "you are free on the 26th" when the
                      // account is blocked until that evening.
                      : 'Most actions are unavailable until '
                            '${formatDateTime(until)}.',
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
