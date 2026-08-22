import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/account_profile_controller.dart';
import '../../controllers/auth_controller.dart';
import '../../core/account_profile.dart';
import '../../core/theme.dart';

IconData accountProfileIcon(AccountProfile profile) => switch (profile) {
  AccountProfile.admin => Icons.admin_panel_settings_outlined,
  AccountProfile.greenpreneur => Icons.storefront_outlined,
  AccountProfile.champion => Icons.eco_outlined,
};

/// A visible reminder that one account may contain several working profiles.
class AccountProfileSwitcher extends ConsumerWidget {
  const AccountProfileSwitcher({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;
    if (user == null) return const SizedBox.shrink();

    final profiles = accountProfilesForRole(user.role);
    final active = ref.watch(activeAccountProfileProvider);
    final theme = Theme.of(context);

    return Card(
      color: theme.colorScheme.secondaryContainer.withValues(alpha: .48),
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: theme.colorScheme.secondaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                accountProfileIcon(active),
                color: theme.colorScheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Using ${active.label}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    profiles.length == 1
                        ? active.description
                        : '${profiles.length} profiles are available under this account.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            if (profiles.length > 1) ...[
              const SizedBox(width: AppTheme.gapSm),
              OutlinedButton(
                onPressed: () => showAccountProfilePicker(context, ref),
                child: const Text('Switch'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Opens the same accessible picker from the dashboard, profile and app bar.
Future<void> showAccountProfilePicker(
  BuildContext context,
  WidgetRef ref, {
  bool returnHome = false,
}) async {
  final user = ref.read(currentUserProvider).value;
  if (user == null) return;

  final active = ref.read(activeAccountProfileProvider);
  final selected = await showModalBottomSheet<AccountProfile>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppTheme.gapMd,
          AppTheme.gapSm,
          AppTheme.gapMd,
          AppTheme.gapLg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Choose a profile',
              style: Theme.of(
                sheetContext,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              'Your sign-in stays the same. Only the workspace and navigation change.',
              style: Theme.of(sheetContext).textTheme.bodyMedium?.copyWith(
                color: Theme.of(sheetContext).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppTheme.gapMd),
            RadioGroup<AccountProfile>(
              groupValue: active,
              onChanged: (value) {
                if (value != null) Navigator.of(sheetContext).pop(value);
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final profile in accountProfilesForRole(user.role))
                    Card(
                      margin: const EdgeInsets.only(bottom: AppTheme.gapSm),
                      child: RadioListTile<AccountProfile>(
                        value: profile,
                        secondary: Icon(accountProfileIcon(profile)),
                        title: Text(profile.label),
                        subtitle: Text(profile.description),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );

  if (selected == null || selected == active || !context.mounted) return;
  final changed = ref
      .read(accountProfileControllerProvider.notifier)
      .select(selected);
  if (changed && returnHome && context.mounted) context.go('/home');
}
