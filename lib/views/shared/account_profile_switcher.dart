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
      color: theme.colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: LayoutBuilder(
          builder: (context, constraints) {
            Widget summary() => Row(
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(15),
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
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: AppTheme.gapXs),
                      Text(
                        profiles.length == 1
                            ? active.description
                            : '${profiles.length} workspaces are ready to use.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );

            if (profiles.length == 1) return summary();

            final switchButton = OutlinedButton.icon(
              onPressed: () => showAccountProfilePicker(context, ref),
              icon: const Icon(Icons.swap_horiz_rounded, size: 18),
              label: const Text('Switch'),
            );

            if (constraints.maxWidth < 520) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  summary(),
                  const SizedBox(height: AppTheme.gapMd),
                  switchButton,
                ],
              );
            }

            return Row(
              children: [
                Expanded(child: summary()),
                const SizedBox(width: AppTheme.gapMd),
                switchButton,
              ],
            );
          },
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
