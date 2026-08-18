import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../controllers/auth_controller.dart';
import '../../core/constants.dart';

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

    final destinations = <ShellDestination>[
      const ShellDestination(
          '/home', Icons.home_outlined, Icons.home, 'Home'),
      const ShellDestination('/wallet', Icons.account_balance_wallet_outlined,
          Icons.account_balance_wallet, 'Wallet'),
      const ShellDestination('/history', Icons.receipt_long_outlined,
          Icons.receipt_long, 'History'),
      if (user != null && user.isAdmin)
        const ShellDestination('/admin/disposals', Icons.fact_check_outlined,
            Icons.fact_check, 'Review'),
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

        return Scaffold(
          appBar: AppBar(
            title: Text(title),
            actions: [
              // Not a navigation destination: the bar is already carrying four
              // on an admin account, and the profile is somewhere you visit and
              // come back from rather than a peer of Home. `push` gives the back
              // button that makes that true.
              if (location != '/profile')
                IconButton(
                  tooltip: 'Your profile',
                  icon: const Icon(Icons.person_outline),
                  onPressed: () => context.push('/profile'),
                ),
              IconButton(
                tooltip: 'Sign out',
                icon: const Icon(Icons.logout),
                onPressed: () => _confirmSignOut(context, ref),
              ),
            ],
          ),
          body: isWide && isDestination
              ? Row(
                  children: [
                    NavigationRail(
                      selectedIndex: index,
                      onDestinationSelected: onSelect,
                      labelType: NavigationRailLabelType.all,
                      destinations: destinations
                          .map((d) => NavigationRailDestination(
                                icon: Icon(d.icon),
                                selectedIcon: Icon(d.selectedIcon),
                                label: Text(d.label),
                              ))
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
                      .map((d) => NavigationDestination(
                            icon: Icon(d.icon),
                            selectedIcon: Icon(d.selectedIcon),
                            label: d.label,
                          ))
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

    if (confirmed != true) return;
    await ref.read(authControllerProvider.notifier).signOut();
  }
}
