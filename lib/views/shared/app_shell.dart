import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../controllers/auth_controller.dart';
import '../../core/constants.dart';

class ShellDestination {
  final String path;
  final IconData icon;
  final String label;
  const ShellDestination(this.path, this.icon, this.label);
}

class AppShell extends ConsumerWidget {
  final String title;
  final Widget child;

  const AppShell({super.key, required this.title, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;

    final destinations = <ShellDestination>[
      const ShellDestination('/home', Icons.home_outlined, 'Home'),
      const ShellDestination('/wallet', Icons.account_balance_wallet_outlined, 'Wallet'),
      if (user != null && !user.isSeller)
        const ShellDestination('/apply-seller', Icons.storefront_outlined, 'Sell'),
      if (user != null && user.isAdmin)
        const ShellDestination('/admin/applications', Icons.fact_check_outlined, 'Review'),
    ];

    final location = GoRouterState.of(context).matchedLocation;
    var index = destinations.indexWhere((d) => d.path == location);
    if (index < 0) index = 0;

    void onSelect(int i) => context.go(destinations[i].path);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= AppConstants.webBreakpoint;

        return Scaffold(
          appBar: AppBar(
            title: Text(title),
            actions: [
              IconButton(
                tooltip: 'Sign out',
                icon: const Icon(Icons.logout),
                onPressed: () =>
                    ref.read(authControllerProvider.notifier).signOut(),
              ),
            ],
          ),
          body: isWide
              ? Row(
                  children: [
                    NavigationRail(
                      selectedIndex: index,
                      onDestinationSelected: onSelect,
                      labelType: NavigationRailLabelType.all,
                      destinations: destinations
                          .map((d) => NavigationRailDestination(
                                icon: Icon(d.icon),
                                label: Text(d.label),
                              ))
                          .toList(),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: child),
                  ],
                )
              : child,
          bottomNavigationBar: isWide
              ? null
              : NavigationBar(
                  selectedIndex: index,
                  onDestinationSelected: onSelect,
                  destinations: destinations
                      .map((d) => NavigationDestination(
                            icon: Icon(d.icon),
                            label: d.label,
                          ))
                      .toList(),
                ),
        );
      },
    );
  }
}
