import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../controllers/auth_controller.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import 'brand_mark.dart';

enum _AccountAction { profile, signOut }

class ShellDestination {
  const ShellDestination(this.path, this.icon, this.selectedIcon, this.label);

  final String path;
  final IconData icon;

  /// The filled variant, shown when this destination is the current one.
  /// Material 3 uses the outline/fill pair to mark selection; without it the
  /// only cue was the indicator pill.
  final IconData selectedIcon;

  final String label;
}

/// The app frame: title bar, navigation, sign-out.
class AppShell extends ConsumerWidget {
  const AppShell({super.key, required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;
    final scheme = Theme.of(context).colorScheme;

    final destinations = <ShellDestination>[
      const ShellDestination('/home', Icons.home_outlined, Icons.home, 'Home'),
      const ShellDestination(
        '/wallet',
        Icons.account_balance_wallet_outlined,
        Icons.account_balance_wallet,
        'Wallet',
      ),
      const ShellDestination(
        '/history',
        Icons.receipt_long_outlined,
        Icons.receipt_long,
        'History',
      ),
      if (user != null && user.isAdmin)
        const ShellDestination(
          '/admin/disposals',
          Icons.fact_check_outlined,
          Icons.fact_check,
          'Review',
        ),
    ];

    final location = GoRouterState.of(context).matchedLocation;
    final index = destinations.indexWhere((d) => d.path == location);

    // -1 means the current screen is not one of the destinations — a bin
    // scanner, a claim form, an admin sub-screen. Previously this fell back to
    // 0, so the shell claimed the user was on Home while they were somewhere
    // else entirely. `NavigationBar` has no "nothing selected" state, so the
    // whole bar is hidden instead: on those screens the app bar's back button is
    // the way out, and a nav bar highlighting the wrong tab is worse than none.
    final isDestination = index >= 0;

    void onSelect(int i) {
      final target = destinations[i].path;
      if (target == location) return;
      // `go`, not `push`: these are peers, and pushing would grow a stack of
      // Home → Wallet → Home the back button then has to unwind.
      context.go(target);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= AppConstants.webBreakpoint;
        final expandedRail = constraints.maxWidth >= 1280;

        return Scaffold(
          backgroundColor: scheme.surfaceContainerLow,
          appBar: AppBar(
            shape: Border(bottom: BorderSide(color: scheme.outlineVariant)),
            title: location == '/home' && !isWide
                ? const BrandMark(size: 34, showWordmark: true)
                : Text(title),
            actions: [
              PopupMenuButton<_AccountAction>(
                tooltip: 'Account menu',
                onSelected: (action) {
                  switch (action) {
                    case _AccountAction.profile:
                      context.push('/profile');
                    case _AccountAction.signOut:
                      _confirmSignOut(context, ref);
                  }
                },
                itemBuilder: (context) => [
                  if (location != '/profile')
                    const PopupMenuItem(
                      value: _AccountAction.profile,
                      child: ListTile(
                        leading: Icon(Icons.person_outline),
                        title: Text('Profile'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  const PopupMenuItem(
                    value: _AccountAction.signOut,
                    child: ListTile(
                      leading: Icon(Icons.logout),
                      title: Text('Sign out'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
                icon: _AccountAvatar(name: user?.name),
                padding: const EdgeInsets.symmetric(horizontal: AppTheme.gapSm),
                offset: const Offset(0, 8),
              ),
              const SizedBox(width: AppTheme.gapSm),
            ],
          ),
          body: isWide && isDestination
              ? Row(
                  children: [
                    NavigationRail(
                      extended: expandedRail,
                      selectedIndex: index,
                      onDestinationSelected: onSelect,
                      labelType: expandedRail
                          ? NavigationRailLabelType.none
                          : NavigationRailLabelType.all,
                      groupAlignment: -.72,
                      minExtendedWidth: 220,
                      leading: Padding(
                        padding: const EdgeInsets.only(
                          top: AppTheme.gapMd,
                          bottom: AppTheme.gapXl,
                        ),
                        child: BrandMark(size: 42, showWordmark: expandedRail),
                      ),
                      destinations: destinations
                          .map(
                            (d) => NavigationRailDestination(
                              icon: Icon(d.icon),
                              selectedIcon: Icon(d.selectedIcon),
                              label: Text(d.label),
                            ),
                          )
                          .toList(),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: child),
                  ],
                )
              : child,
          bottomNavigationBar: isWide || !isDestination
              ? null
              : NavigationBar(
                  selectedIndex: index,
                  onDestinationSelected: onSelect,
                  destinations: destinations
                      .map(
                        (d) => NavigationDestination(
                          icon: Icon(d.icon),
                          selectedIcon: Icon(d.selectedIcon),
                          label: d.label,
                        ),
                      )
                      .toList(),
                ),
        );
      },
    );
  }

  /// Signing out was a single unguarded tap on an icon in the app bar, sitting
  /// where a "more" or "profile" button usually lives. Easy to hit by accident,
  /// and the cost is re-entering a password.
  Future<void> _confirmSignOut(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'You will need your email and password to sign back in. Nothing you '
          'have submitted is lost.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Stay signed in'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;
    await ref.read(authControllerProvider.notifier).signOut();
  }
}

class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({required this.name});

  final String? name;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final words = (name ?? '')
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    final initials = words.isEmpty
        ? ''
        : words.length == 1
        ? words.first.characters.first.toUpperCase()
        : (words.first.characters.first + words.last.characters.first)
              .toUpperCase();

    return Container(
      width: 38,
      height: 38,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        shape: BoxShape.circle,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: initials.isEmpty
          ? Icon(
              Icons.person_outline,
              size: 20,
              color: scheme.onPrimaryContainer,
            )
          : Text(
              initials,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: scheme.onPrimaryContainer,
                fontWeight: FontWeight.w800,
              ),
            ),
    );
  }
}
