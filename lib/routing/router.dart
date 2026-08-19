import 'package:firebase_auth/firebase_auth.dart' show User;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../controllers/auth_controller.dart';
import '../models/user_model.dart';
import '../views/auth/login_view.dart';
import '../views/auth/register_view.dart';
import '../views/home/home_view.dart';
import '../views/seller_application/seller_application_view.dart';
import '../views/admin/admin_applications_view.dart';
import '../views/admin/admin_claims_view.dart';
import '../views/claims/claim_history_view.dart';
import '../views/claims/claim_submit_view.dart';
import '../views/admin/admin_bins_view.dart';
import '../views/admin/admin_users_view.dart';
import '../views/admin/points_policy_view.dart';
import '../views/history/submission_history_view.dart';
import '../views/profile/profile_view.dart';
import '../views/wallet/wallet_ledger_view.dart';
import '../views/disposal/scan_view.dart';
import '../views/disposal/photo_view.dart';
import '../views/disposal/location_view.dart';
import '../views/disposal/declare_view.dart';
import '../views/admin/admin_disposals_view.dart';
import '../views/shared/account_incomplete_view.dart';
import '../views/shared/startup_error_view.dart';
import '../views/shared/route_error_view.dart';
import '../views/shared/splash_view.dart';

/// Shown while Firebase Auth is still resolving who — if anyone — is signed in.
const String splashPath = '/splash';

/// A destination deferred until the auth gate can decide on it.
///
/// The gate has to send an unresolved or anonymous visitor somewhere — the splash
/// or the sign-in screen — and until now that destination replaced the one they
/// asked for, permanently. Two paths lost:
///
///  * An administrator cold-opening `/admin/bins` waited on the splash and then
///    landed on `/home`.
///  * A **push tap from a terminated state** (F7.1). `main.dart` reads
///    `initialMessage()` in a post-frame callback and calls `go('/history')`; if
///    the gate had not resolved by that moment, the redirect swallowed it. That is
///    the notification path most worth demonstrating, and it silently went to the
///    wrong screen.
///
/// Held in memory rather than as a `?from=` query parameter, because the URL bar
/// is not the right place for it on mobile and a cold-start deep link is already
/// in `state.matchedLocation` on the first redirect pass.
///
/// SECURITY: consuming this returns a *location*, which sends the request back
/// through `GoRouter`'s matching and through the target route's own `redirect`.
/// A buyer who somehow arrives with `/admin/users` remembered still meets
/// `requireAdmin` and still bounces to `/home`. Nothing here grants access; it
/// only restores an intention.
class PendingDestination {
  String? _path;

  /// Records where the visitor was trying to go.
  ///
  /// Last write wins. If someone taps a notification while sitting on the splash,
  /// that newer intention is the right one to honour.
  void remember(String path) => _path = path;

  /// Returns the remembered path and forgets it.
  ///
  /// Cleared on read so a later sign-out and sign-in as somebody else cannot
  /// teleport the new session to a screen the previous one had asked for.
  String? consume() {
    final path = _path;
    _path = null;
    return path;
  }
}

final pendingDestinationProvider = Provider<PendingDestination>((ref) {
  // Outlives the redirect passes that write and read it.
  ref.keepAlive();
  return PendingDestination();
});

/// Notifies go_router when the facts its redirects depend on have changed.
///
/// ## Why this class exists
///
/// `routerProvider` used to `ref.watch` both the auth state and the user
/// document, which meant a **new `GoRouter` instance** on every change to
/// either. `MaterialApp.router` rebuilt with a new `routerConfig` throws away
/// the `Navigator` and starts again at `initialLocation`, so any write to
/// `users/{uid}` — an administrator flipping a role, a suspension lapsing —
/// silently teleported the user to `/home`, losing an in-progress disposal
/// three screens deep. Startup alone did it twice, as auth and then the user
/// document resolved.
///
/// The router is now built exactly once and re-evaluates its redirects through
/// this listenable instead. `notifyListeners` re-runs `redirect`; it does not
/// touch the navigation stack.
///
/// Only the gate-relevant facts are forwarded, so an unrelated field changing
/// on the user document does not cost a redirect pass.
class _AuthGateListenable extends ChangeNotifier {
  _AuthGateListenable(this._ref) {
    _signature = _currentSignature();

    // Both sources must be listened to, not just the profile.
    //
    // `currentUserProvider` returns `Stream.value(null)` from its own `loading`
    // branch, so its value is an indistinguishable `null` both while auth is
    // resolving and once auth has resolved to signed-out. Watching only that
    // stream meant the signature read "anonymous" from the first frame and never
    // *changed* when auth actually reported — so no notification fired, redirect
    // never re-ran, and the app sat on the splash screen forever. The auth
    // stream's own resolution state is the fact that changes.
    _ref.listen<AsyncValue<User?>>(
      firebaseAuthStateProvider,
      (_, _) => _refresh(),
    );
    _ref.listen<AsyncValue<UserModel?>>(
      currentUserProvider,
      (_, _) => _refresh(),
    );
  }

  final Ref _ref;
  late String _signature;

  void _refresh() {
    final next = _currentSignature();
    if (next == _signature) return;
    _signature = next;
    notifyListeners();
  }

  /// Everything `redirect` actually reads, flattened to a comparable string.
  ///
  /// Resolution state is part of it: "not signed in" and "we do not know yet"
  /// lead to different destinations, so they must not compare equal.
  String _currentSignature() {
    final auth = _ref.read(firebaseAuthStateProvider);
    if (auth.isLoading && !auth.hasValue) return 'auth:unresolved';
    if (auth.hasError && !auth.hasValue) return 'auth:failed';
    if (auth.value == null) return 'auth:anonymous';

    // Same three-way order as `resolve()` below, for the same reason: a retained
    // stale null makes `hasValue` true while the profile is still loading.
    final profile = _ref.read(currentUserProvider);
    final user = profile.value;

    if (user != null) {
      // Only the gate-relevant fields. A name or a wallet balance changing must
      // not cost a redirect pass.
      return 'user:${user.uid}|${user.role}|${user.status}'
          '|${user.suspendedUntil}';
    }

    if (profile.isLoading) return 'profile:unresolved';
    if (profile.hasError) return 'profile:failed';
    return 'profile:missing';
  }
}

final _authGateProvider = Provider<_AuthGateListenable>((ref) {
  // Riverpod 3 auto-disposes by default. Without this the gate was torn down the
  // instant it was created — nothing depended on it, so its `ref.listen`
  // subscriptions were cancelled before Firebase ever reported, `notifyListeners`
  // never fired, and the app sat on the splash screen forever.
  ref.keepAlive();

  final listenable = _AuthGateListenable(ref);
  ref.onDispose(listenable.dispose);
  return listenable;
});

/// Shown when Firebase has a session but Firestore has no profile for it.
const String accountIncompletePath = '/account-incomplete';

/// Auth or profile could not be read because the service/network failed.
const String startupErrorPath = '/startup-error';

/// What the gate knows about the signed-in account at redirect time.
enum _Gate {
  /// Auth has not reported yet, or the user document is still loading. Not the
  /// same as signed out — treating it as such is what flashed the login screen
  /// on every cold start.
  unresolved,
  anonymous,

  /// Signed in, but `users/{uid}` does not exist. Registration writes the auth
  /// account and the profile in two steps, so a failure between them leaves an
  /// account that can authenticate and do nothing else. Both the old code and my
  /// first attempt at this gate left such a user on an endless spinner; there is
  /// no role to gate on and no name to greet, so the only honest move is to say
  /// so and offer a way out.
  profileMissing,

  /// A read failed. It must not be presented as a missing profile.
  failed,

  signedIn,
}

final routerProvider = Provider<GoRouter>((ref) {
  // `watch`, so the dependency edge keeps the gate alive for as long as the
  // router exists. It is safe here precisely because `_authGateProvider` returns
  // one stable instance and never re-emits — so this never rebuilds the router,
  // which is the whole point (see [_AuthGateListenable]). Watching
  // `currentUserProvider` directly, as this used to, is what rebuilt it.
  final refreshListenable = ref.watch(_authGateProvider);
  final pending = ref.watch(pendingDestinationProvider);

  /// The signed-in account, or null. Read fresh on each redirect pass.
  ({_Gate gate, UserModel? user}) resolve() {
    final auth = ref.read(firebaseAuthStateProvider);

    // Auth itself has not reported yet.
    if (auth.isLoading && !auth.hasValue) {
      return (gate: _Gate.unresolved, user: null);
    }
    if (auth.hasError && !auth.hasValue) {
      return (gate: _Gate.failed, user: null);
    }
    if (auth.value == null) return (gate: _Gate.anonymous, user: null);

    // Signed in as far as Firebase is concerned. Now the profile that carries
    // the role — and the order of these three checks matters.
    //
    // `currentUserProvider` returns `Stream.value(null)` from its own `loading`
    // branch, so when auth resolves and it switches over to `watchUser(uid)`,
    // Riverpod *retains that null as the previous value* while the new
    // subscription loads. `hasValue` is therefore true with `value == null`, and
    // a `isLoading && !hasValue` test does not fire. Reading that as "no
    // document" flashed the account-recovery screen at every signed-in user on
    // every cold start.
    //
    // `watchUser` emits null for a genuinely absent document too, so the only
    // thing separating "still fetching" from "really not there" is `isLoading`.
    final profile = ref.read(currentUserProvider);
    final user = profile.value;

    // A profile in hand wins, even mid-refresh — no reason to show a spinner
    // over data we already have.
    if (user != null) return (gate: _Gate.signedIn, user: user);

    // No profile yet, but still arriving. Wait.
    if (profile.isLoading) return (gate: _Gate.unresolved, user: null);

    // A failed read is not evidence that the document does not exist.
    if (profile.hasError) return (gate: _Gate.failed, user: null);

    // Settled, signed in, and `users/{uid}` does not exist.
    return (gate: _Gate.profileMissing, user: null);
  }

  /// Guards a route that requires an administrator.
  ///
  /// Waiting on [_Gate.unresolved] rather than bouncing to `/home` matters for
  /// deep links: an administrator opening `/admin/users` from a notification
  /// would otherwise be redirected away in the moment before their profile
  /// loaded, and land somewhere they did not ask for.
  String? requireAdmin(BuildContext context, GoRouterState state) {
    final (gate: gate, user: user) = resolve();
    return switch (gate) {
      _Gate.unresolved => splashPath,
      _Gate.anonymous => '/login',
      _Gate.profileMissing => accountIncompletePath,
      _Gate.failed => startupErrorPath,
      _Gate.signedIn => user!.isAdmin ? null : '/home',
    };
  }

  String? requireSignedIn(BuildContext context, GoRouterState state) {
    final (gate: gate, user: _) = resolve();
    return switch (gate) {
      _Gate.unresolved => splashPath,
      _Gate.anonymous => '/login',
      _Gate.profileMissing => accountIncompletePath,
      _Gate.failed => startupErrorPath,
      _Gate.signedIn => null,
    };
  }

  return GoRouter(
    initialLocation: '/home',
    refreshListenable: refreshListenable,
    errorBuilder: (context, state) =>
        RouteErrorView(location: state.uri.toString()),
    redirect: (context, state) {
      final location = state.matchedLocation;
      final isAuthRoute = location == '/login' || location == '/register';
      final isSplash = location == splashPath;
      final isIncomplete = location == accountIncompletePath;
      final isStartupError = location == startupErrorPath;

      final (gate: gate, user: _) = resolve();

      /// Whether [location] is somewhere worth returning to.
      ///
      /// The gate's own waypoints are not: remembering `/splash` or `/login`
      /// would restore the screen the visitor was sent to rather than the one
      /// they asked for.
      bool isRealDestination() =>
          !isSplash &&
          !isAuthRoute &&
          !isIncomplete &&
          !isStartupError &&
          location != '/home';

      switch (gate) {
        case _Gate.unresolved:
          // Hold on the splash. Anywhere else would either flash the login
          // screen at a signed-in user or show a shell with no data in it.
          if (isSplash) return null;
          if (isRealDestination()) pending.remember(location);
          return splashPath;

        case _Gate.anonymous:
          if (isAuthRoute) return null;
          // Kept across sign-in too: someone who follows a link, is asked to
          // sign in, and does so should arrive where the link pointed.
          if (isRealDestination()) pending.remember(location);
          return '/login';

        case _Gate.profileMissing:
          return isIncomplete ? null : accountIncompletePath;

        case _Gate.failed:
          return isStartupError ? null : startupErrorPath;

        case _Gate.signedIn:
          // Nothing to do on the splash but leave it, and an authenticated user
          // has no business on the sign-in screen or the recovery screen.
          //
          // `/home` is the fallback, not the destination. Hardcoding it here is
          // what discarded admin deep links and terminated-state push taps.
          if (isSplash || isAuthRoute || isIncomplete || isStartupError) {
            return pending.consume() ?? '/home';
          }
          return null;
      }
    },
    routes: [
      GoRoute(
        path: splashPath,
        builder: (context, state) => const SplashView(),
      ),
      GoRoute(
        path: accountIncompletePath,
        builder: (context, state) => const AccountIncompleteView(),
      ),
      GoRoute(
        path: startupErrorPath,
        builder: (context, state) => const StartupErrorView(),
      ),
      GoRoute(path: '/login', builder: (context, state) => const LoginView()),
      GoRoute(
        path: '/register',
        builder: (context, state) => const RegisterView(),
      ),
      GoRoute(path: '/home', builder: (context, state) => const HomeView()),
      GoRoute(
        path: '/apply-seller',
        builder: (context, state) => const SellerApplicationView(),
        redirect: (context, state) {
          final signedIn = requireSignedIn(context, state);
          if (signedIn != null) return signedIn;
          // Already a seller: the application form has nothing to offer.
          return resolve().user!.isSeller ? '/home' : null;
        },
      ),
      GoRoute(
        // Declared before '/claims/new' is irrelevant to go_router (paths are
        // matched exactly), but kept adjacent so the pair is obvious.
        path: '/claims',
        builder: (context, state) => const ClaimHistoryView(),
        redirect: requireSignedIn,
      ),
      GoRoute(
        path: '/claims/new',
        builder: (context, state) => const ClaimSubmitView(),
        redirect: requireSignedIn,
      ),
      GoRoute(
        path: '/profile',
        builder: (context, state) => const ProfileView(),
        redirect: requireSignedIn,
      ),
      GoRoute(
        path: '/history',
        builder: (context, state) => const SubmissionHistoryView(),
        redirect: requireSignedIn,
      ),
      GoRoute(
        path: '/wallet',
        builder: (context, state) => const WalletLedgerView(),
        redirect: requireSignedIn,
      ),
      GoRoute(
        path: '/dispose/scan',
        builder: (context, state) => const ScanView(),
        redirect: requireSignedIn,
      ),
      GoRoute(
        path: '/dispose/photo',
        builder: (context, state) => const DisposalPhotoView(),
        redirect: requireSignedIn,
      ),
      GoRoute(
        path: '/dispose/location',
        builder: (context, state) => const DisposalLocationView(),
        redirect: requireSignedIn,
      ),
      GoRoute(
        path: '/dispose/declare',
        builder: (context, state) => const DisposalDeclareView(),
        redirect: requireSignedIn,
      ),
      GoRoute(
        path: '/admin/applications',
        builder: (context, state) => const AdminApplicationsView(),
        redirect: requireAdmin,
      ),
      GoRoute(
        path: '/admin/claims',
        builder: (context, state) => const AdminClaimsView(),
        redirect: requireAdmin,
      ),
      GoRoute(
        path: '/admin/bins',
        builder: (context, state) => const AdminBinsView(),
        redirect: requireAdmin,
      ),
      GoRoute(
        path: '/admin/users',
        builder: (context, state) => const AdminUsersView(),
        redirect: requireAdmin,
      ),
      GoRoute(
        path: '/admin/points',
        builder: (context, state) => const PointsPolicyView(),
        redirect: requireAdmin,
      ),
      GoRoute(
        path: '/admin/disposals',
        builder: (context, state) => const AdminDisposalsView(),
        redirect: requireAdmin,
      ),
    ],
  );
});
