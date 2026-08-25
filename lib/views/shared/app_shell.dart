import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../controllers/account_profile_controller.dart';
import '../../controllers/admin_workload_controller.dart';
import '../../controllers/auth_controller.dart';
import '../../controllers/cart_controller.dart';
import '../../core/account_profile.dart';
import '../../core/constants.dart';
import '../../core/network_errors.dart';
import '../../core/theme.dart';
import 'account_profile_switcher.dart';
import 'app_snackbar.dart';
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
  const AppShell({
    super.key,
    required this.title,
    required this.child,
    this.floatingActionButton,
  });

  final String title;
  final Widget child;

  /// The screen's primary create action, if it has one.
  ///
  /// Exists so that a destination with a floating action button does not have
  /// to opt out of the shell to keep it. The Greenpreneur's two nav
  /// destinations did exactly that — they built their own bare `Scaffold`, so
  /// selecting "Listings" in the navigation bar removed the navigation bar, and
  /// because they are reached with `go` rather than `push` there was no back
  /// button either. The only marked way out was a "Switch to 3ZERO Champion"
  /// action, which escaped by silently changing the active profile.
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider).value;
    final activeProfile = ref.watch(activeAccountProfileProvider);
    final scheme = Theme.of(context).colorScheme;
    // Watched at the shell rather than on the shop screen, so a buyer who adds
    // something and navigates away can still see they have a cart open.
    final cartCount = ref.watch(cartCountProvider);
    // Signing out is not instant: it first unregisters the FCM token, which is
    // a network round-trip. Without this the menu item stayed live throughout,
    // so a user on a slow connection re-confirmed and fired a second signOut.
    final isSigningOut = ref.watch(authControllerProvider).isLoading;
    final suspended = user != null && !user.isActive;
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
        // Named for the screen it opens, like every other destination. 'Eco'
        // was the only bare abbreviation in the bar and the only label that did
        // not match its screen's title, so an admin could not tell which queue
        // it was without tapping it.
        ShellDestination(
          '/admin/claims',
          Icons.eco_outlined,
          Icons.eco,
          'Eco-actions',
        ),
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
          '/seller/sales',
          Icons.query_stats_outlined,
          Icons.query_stats,
          'Sales',
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

      // Say why, rather than bouncing. `requireAdmin`/`requireSeller` in
      // router.dart send a suspended user back to /home, which the shell then
      // rendered as "nothing happened": the most prominent control on the
      // screen was inert with no explanation, while the home cards two inches
      // below explained themselves properly. The Champion destinations are all
      // `requireSignedIn` and keep working, so only these two prefixes refuse.
      if (suspended &&
          (target.startsWith('/admin/') || target.startsWith('/seller/'))) {
        AppSnackBar.of(context).info('Unavailable while suspended.');
        return;
      }

      // `go`, not `push`: these are peers, and pushing would grow a stack of
      // Home → Wallet → Home the back button then has to unwind.
      context.go(target);
    }

    // `atCap` travels with the count. The admin queues are read through
    // `.limit(QueryLimits.reviewQueue)`, so a saturated badge is a floor, not a
    // total — rendering it as a bare number told an admin working a 300-item
    // backlog that they had 50, and the number never moved as they worked. The
    // cart has no cap, so it is always exact.
    ({int count, bool atCap}) badgeFor(String path) => switch (path) {
      '/market' => (count: cartCount, atCap: false),
      '/admin/disposals' => (
        count: adminWorkload.disposals.pending,
        atCap: adminWorkload.disposals.atCap,
      ),
      '/admin/claims' => (
        count: adminWorkload.claims.pending,
        atCap: adminWorkload.claims.atCap,
      ),
      '/admin/appeals' => (
        count: adminWorkload.appeals.pending,
        atCap: adminWorkload.appeals.atCap,
      ),
      _ => (count: 0, atCap: false),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        // Two-dimensional on purpose — see AppConstants.railMinHeight.
        final isWide =
            constraints.maxWidth >= AppConstants.webBreakpoint &&
            constraints.maxHeight >= AppConstants.railMinHeight;
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

        // Android's back gesture should walk back to the start destination
        // before it leaves the app — that is the platform convention, and
        // `NavigationBar` selections are made with `go`, which replaces the
        // stack rather than growing it. So every tab but Home sat on a
        // single-entry stack, and one back gesture from Wallet, Shop, History
        // or any admin queue closed Chokro outright. Only that case is
        // intercepted: a pushed screen still has something to pop, and Home
        // itself is where back is supposed to exit.
        final interceptBack = isDestination && location != '/home' && !canPop;

        return PopScope(
          canPop: !interceptBack,
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) return;
            context.go('/home');
          },
          child: Scaffold(
            backgroundColor: scheme.surface,
            floatingActionButton: floatingActionButton,
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
                        showAccountProfilePicker(
                          context,
                          ref,
                          returnHome: true,
                        );
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
                    PopupMenuItem(
                      enabled: !isSigningOut,
                      value: _AccountAction.signOut,
                      child: ListTile(
                        leading: const Icon(Icons.logout),
                        title: Text(
                          isSigningOut ? 'Signing out…' : 'Sign out',
                        ),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                  // PopupMenuButton already wraps its icon in an IconButton with
                  // this tooltip and its own expanded-state semantics. Nesting a
                  // second Tooltip here makes two semantics owners re-parent the
                  // avatar while the menu route animates, which can trip
                  // RenderObject's parentDataDirty assertion on web.
                  icon: _AccountAvatar(
                    name: user?.name,
                    photoUrl: user?.hasProfilePhoto == true
                        ? user!.profilePhotoUrl
                        : null,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppTheme.gapSm,
                  ),
                  offset: const Offset(0, 8),
                ),
                const SizedBox(width: AppTheme.gapSm),
              ],
            ),
            body: isWide && isDestination
                ? Row(
                    children: [
                      NavigationRail(
                        // Belt and braces with the height floor above: the rail
                        // is never the only thing standing between a user and a
                        // destination they cannot reach.
                        scrollable: true,
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
                          child: BrandMark(
                            size: 42,
                            showWordmark: expandedRail,
                          ),
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

    // Captured before the await: the route this was invoked from is gone by the
    // time the answer arrives. A deliberate, security-relevant action that
    // reports nothing on failure leaves the user believing they signed out on a
    // handset the codebase itself describes as often shared or borrowed.
    final notify = AppSnackBar.of(context);
    await ref.read(authControllerProvider.notifier).signOut();
    final error = ref.read(authControllerProvider).error;
    if (error != null) {
      notify.failure('Could not sign out. ${friendlyErrorMessage(error)}');
    }
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
  final ({int count, bool atCap}) badge;

  @override
  Widget build(BuildContext context) {
    if (badge.count <= 0) return Icon(icon);
    // `Badge.count` cannot say "50+", so a capped queue uses the general
    // constructor. Semantics carries the same distinction in words, because the
    // "+" is a single glyph a screen reader would otherwise drop.
    if (!badge.atCap) {
      return Badge.count(count: badge.count, child: Icon(icon));
    }
    return Semantics(
      label: 'at least ${badge.count} waiting',
      child: Badge(
        label: ExcludeSemantics(child: Text('${badge.count}+')),
        child: Icon(icon),
      ),
    );
  }
}

class _AccountAvatar extends StatelessWidget {
  const _AccountAvatar({required this.name, required this.photoUrl});

  final String? name;
  final String? photoUrl;

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

    final fallback = initials.isEmpty
        ? Icon(Icons.person_outline, size: 20, color: scheme.onPrimaryContainer)
        : Text(
            initials,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: scheme.onPrimaryContainer,
              fontWeight: FontWeight.w800,
            ),
          );

    return Container(
      width: 38,
      height: 38,
      clipBehavior: Clip.antiAlias,
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
      child: photoUrl == null || photoUrl!.isEmpty
          ? fallback
          : CachedNetworkImage(
              imageUrl: photoUrl!,
              width: 38,
              height: 38,
              fit: BoxFit.cover,
              placeholder: (_, _) => fallback,
              errorWidget: (_, _, _) => fallback,
            ),
    );
  }
}
