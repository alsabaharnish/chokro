import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../controllers/account_profile_controller.dart';
import '../../controllers/admin_workload_controller.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/cart_controller.dart';
import '../../core/account_profile.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import 'account_profile_switcher.dart';
import 'brand_mark.dart';

enum _AccountAction { switchProfile, profile, signOut }

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
    final activeProfile = ref.watch(activeAccountProfileProvider);
    final scheme = Theme.of(context).colorScheme;
    // Watched at the shell rather than on the shop screen, so a buyer who adds
    // something and navigates away can still see they have a cart open.
    final cartCount = ref.watch(cartCountProvider);
    final adminWorkload =
        user?.isAdmin == true && activeProfile == AccountProfile.admin
        ? ref.watch(adminWorkloadProvider)
        : AdminWorkload.empty;

    // One account can have multiple profiles, but each profile gets a focused
    // workspace. Permissions still come from [user]; this only controls which
    // destinations are presented as the current person's primary tools.
    final destinations = switch (activeProfile) {
      AccountProfile.admin => const <ShellDestination>[
        ShellDestination('/home', Icons.home_outlined, Icons.home, 'Home'),
        ShellDestination(
          '/admin/dashboard',
          Icons.insights_outlined,
          Icons.insights,
          'Dashboard',
        ),
        ShellDestination(
          '/admin/disposals',
          Icons.fact_check_outlined,
          Icons.fact_check,
          'Disposals',
        ),
        ShellDestination('/admin/claims', Icons.eco_outlined, Icons.eco, 'Eco'),
        ShellDestination(
          '/admin/appeals',
          Icons.gavel_outlined,
          Icons.gavel,
          'Appeals',
        ),
      ],
      AccountProfile.greenpreneur => const <ShellDestination>[
        ShellDestination('/home', Icons.home_outlined, Icons.home, 'Home'),
        ShellDestination(
          '/seller/products',
          Icons.inventory_2_outlined,
          Icons.inventory_2,
          'Listings',
        ),
        ShellDestination(
          '/seller/orders',
          Icons.local_shipping_outlined,
          Icons.local_shipping,
          'Orders',
        ),
        ShellDestination(
          '/profile',
          Icons.person_outline,
          Icons.person,
          'Profile',
        ),
      ],
      AccountProfile.champion => const <ShellDestination>[
        ShellDestination('/home', Icons.home_outlined, Icons.home, 'Home'),
        // Shopping is a top-level Champion destination because the spend path
        // completes the points economy (§7.1).
        ShellDestination(
          '/market',
          Icons.storefront_outlined,
          Icons.storefront,
          'Shop',
        ),
        ShellDestination(
          '/wallet',
          Icons.account_balance_wallet_outlined,
          Icons.account_balance_wallet,
          'Wallet',
        ),
        ShellDestination(
          '/history',
          Icons.receipt_long_outlined,
          Icons.receipt_long,
          'History',
        ),
      ],
    };

    final location = GoRouterState.of(context).matchedLocation;
    final index = destinations.indexWhere((d) => d.path == location);

    // -1 means the current screen is not one of the destinations — a bin
    // scanner, a claim form, an admin sub-screen. Previously this fell back to
    // 0, so the shell claimed the user was on Home while they were somewhere
    // else entirely. `NavigationBar` has no "nothing selected" state, so the
    // whole bar is hidden instead: on those screens the app bar's back button is
    // the way out, and a nav bar highlighting the wrong tab is worse than none.
    final isDestination = index >= 0;
    final canPop = Navigator.of(context).canPop();

    void onSelect(int i) {
      final target = destinations[i].path;
      if (target == location) return;
      // `go`, not `push`: these are peers, and pushing would grow a stack of
      // Home → Wallet → Home the back button then has to unwind.
      context.go(target);
    }

    int badgeFor(String path) => switch (path) {
      '/market' => cartCount,
      '/admin/disposals' => adminWorkload.disposals.pending,
      '/admin/claims' => adminWorkload.claims.pending,
      '/admin/appeals' => adminWorkload.appeals.pending,
      _ => 0,
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= AppConstants.webBreakpoint;
        final expandedRail = constraints.maxWidth >= 1280;
        final content = DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [scheme.surfaceContainerLow, scheme.surface],
              stops: const [0, .72],
            ),
          ),
          child: child,
        );

        return Scaffold(
          backgroundColor: scheme.surface,
          appBar: AppBar(
            backgroundColor: scheme.surfaceContainerLowest.withValues(
              alpha: .97,
            ),
            shape: Border(
              bottom: BorderSide(
                color: scheme.outlineVariant.withValues(alpha: .82),
              ),
            ),
            leading: !isDestination && !canPop
                ? IconButton(
                    tooltip: 'Back to home',
                    onPressed: () => context.go('/home'),
                    icon: const Icon(Icons.arrow_back),
                  )
                : null,
            title: location == '/home' && !isWide
                ? const BrandMark(size: 34, showWordmark: true)
                : Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
            actions: [
              PopupMenuButton<_AccountAction>(
                tooltip: 'Account menu',
                onSelected: (action) {
                  switch (action) {
                    case _AccountAction.switchProfile:
                      showAccountProfilePicker(context, ref, returnHome: true);
                    case _AccountAction.profile:
                      context.push('/profile');
                    case _AccountAction.signOut:
                      _confirmSignOut(context, ref);
                  }
                },
                itemBuilder: (context) => [
                  if (user != null &&
                      accountProfilesForRole(user.role).length > 1)
                    PopupMenuItem(
                      value: _AccountAction.switchProfile,
                      child: ListTile(
                        leading: Icon(accountProfileIcon(activeProfile)),
                        title: const Text('Switch profile'),
                        subtitle: Text(activeProfile.label),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
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
                // PopupMenuButton already wraps its icon in an IconButton with
                // this tooltip and its own expanded-state semantics. Nesting a
                // second Tooltip here makes two semantics owners re-parent the
                // avatar while the menu route animates, which can trip
                // RenderObject's parentDataDirty assertion on web.
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
                              icon: _DestinationIcon(
                                icon: d.icon,
                                badge: badgeFor(d.path),
                              ),
                              selectedIcon: _DestinationIcon(
                                icon: d.selectedIcon,
                                badge: badgeFor(d.path),
                              ),
                              label: Text(d.label),
                            ),
                          )
                          .toList(),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: content),
                  ],
                )
              : content,
          bottomNavigationBar: isWide || !isDestination
              ? null
              : DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  child: NavigationBar(
                    selectedIndex: index,
                    onDestinationSelected: onSelect,
                    destinations: destinations
                        .map(
                          (d) => NavigationDestination(
                            icon: _DestinationIcon(
                              icon: d.icon,
                              badge: badgeFor(d.path),
                            ),
                            selectedIcon: _DestinationIcon(
                              icon: d.selectedIcon,
                              badge: badgeFor(d.path),
                            ),
                            label: d.label,
                          ),
                        )
                        .toList(),
                  ),
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

/// A navigation icon that can carry an unread-style count.
///
/// Only the shop destination uses it today. Written as a widget rather than
/// inlined twice because the rail and the bar both need it, and the pair drifting
/// apart is exactly how the home screen's eight hand-written cards went wrong.
class _DestinationIcon extends StatelessWidget {
  const _DestinationIcon({required this.icon, required this.badge});

  final IconData icon;
  final int badge;

  @override
  Widget build(BuildContext context) {
    if (badge <= 0) return Icon(icon);
    return Badge.count(count: badge, child: Icon(icon));
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
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [scheme.primaryContainer, scheme.tertiaryContainer],
        ),
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
