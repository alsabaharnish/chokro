import 'package:firebase_auth/firebase_auth.dart' show User;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../controllers/auth_controller.dart';
import '../controllers/account_profile_controller.dart';
import '../core/account_profile.dart';
import '../models/appeal_model.dart';
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
import '../views/disposal/bin_entry_view.dart';
import '../views/disposal/photo_view.dart';
import '../views/disposal/location_view.dart';
import '../views/disposal/declare_view.dart';
import '../views/donations/donation_view.dart';
import '../views/admin/admin_disposals_view.dart';
import '../views/admin/admin_appeals_view.dart';
import '../views/admin/admin_dashboard_view.dart';
import '../views/admin/admin_mass_queue_view.dart';
import '../views/admin/admin_producers_view.dart';
import '../views/producer/invitation_redeem_view.dart';
import '../views/producer/declaration_view.dart';
import '../views/producer/passports_view.dart';
import '../views/producer/producer_activity_view.dart';
import '../views/producer/producer_sdg_view.dart';
import '../views/producer/producer_dashboard_view.dart';
import '../views/producer/producer_members_view.dart';
import '../views/producer/producer_skus_view.dart';
import '../views/producer/sku_import_view.dart';
import '../views/appeals/appeal_form_view.dart';
import '../views/appeals/appeals_view.dart';
import '../views/market/catalog_view.dart';
import '../views/market/cart_view.dart';
import '../views/market/checkout_view.dart';
import '../views/market/product_detail_view.dart';
import '../views/orders/buyer_orders_view.dart';
import '../views/seller/product_edit_view.dart';
import '../views/seller/seller_orders_view.dart';
import '../views/seller/seller_products_view.dart';
import '../views/seller/seller_sales_view.dart';
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

  /// The current deferred intention without clearing it.
  ///
  /// Redirects need this during a cold anonymous launch: the first pass has
  /// already replaced the bin URL with `/splash`, but the second pass still
  /// needs to know that the visitor arrived through a bin QR so it can offer
  /// registration first. Only [consume] clears the value.
  String? get current => _path;

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
    // The third gate-relevant fact. `resolve()` reads it, so a change to it can
    // change where a visitor belongs — and anything `redirect` reads without
    // being listened to here is a redirect pass that never runs. It is what
    // returns a failed registration from `/register` to wherever it belongs.
    _ref.listen<bool>(registrationInFlightProvider, (_, _) => _refresh());
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
    if (_ref.read(registrationInFlightProvider)) return 'profile:provisioning';
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

/// Where a producer invitation link lands (EPR-4).
///
/// Treated as an auth route by the gate below, so an anonymous visitor holding
/// an invitation reaches the form that redeems it instead of the sign-in screen.
const String invitationRedeemPath = '/join';

/// Pure route policies, kept outside GoRouter so role/suspension agreement can
/// be tested without constructing Firebase-backed providers.
bool canAccessAdminRoutes(UserModel user) => user.isAdmin && user.isActive;

/// Whether this account may open the EPR producer portal (EPR-1).
///
/// The platform role and nothing else. Which *organisation* the account may
/// read, and what it may do there, is decided by a stored membership document —
/// in `firestore.rules`, in `requireOrgRole` on the server, and in the
/// workspace's own first frame. A route gate cannot resolve that without a
/// network read, and a gate that guessed at it would be a fourth copy of an
/// authorisation rule that already exists in three places that agree.
///
/// So this opens the door and the workspace says what is behind it: an
/// unverified address, a revoked membership and a suspended company each get
/// their own explanation rather than a bounce to `/home` with no reason given.
bool canAccessProducerRoutes(UserModel user) => user.isProducer && user.isActive;

/// Where an account belongs when it lands on a route it does not hold.
///
/// A producer has no citizen home to fall back to, so `/home` is the wrong
/// answer for one — it would send a compliance officer to a screen offering a
/// wallet, a shop and a bin scanner, none of which their account can use.
String homeFor(UserModel user) => user.isProducer ? '/producer' : '/home';

String? activeRouteRedirect(UserModel user) =>
    user.isActive ? null : homeFor(user);

/// Sends a producer away from the citizen home screen.
///
/// `/home` is the router's `initialLocation` and the fallback of several
/// redirects, so a producer reaches it by default rather than by asking. This
/// is what makes signing in as a producer land in the producer workspace.
String? producerHomeRedirect(UserModel user) =>
    user.isProducer ? '/producer' : null;

String? sellerRouteRedirect(UserModel user) {
  if (!user.isActive) return '/home';
  // A producer is not a Greenpreneur who has not applied yet — the roles are
  // disjoint (EPR-1) — so the application form is the wrong destination.
  if (user.isProducer) return '/producer';
  return user.isSeller ? null : '/apply-seller';
}

/// Converts browser and native deep-link URIs into a GoRouter-internal location.
///
/// Browser route information normally arrives as `/path?query`, while a cold
/// Android or iOS app link can retain its `https://host` origin. Redirects must
/// remember only the local path: returning an absolute URI after authentication
/// is not a valid in-app navigation target.
String restorableRouteLocation(Uri uri) {
  final buffer = StringBuffer(uri.path.isEmpty ? '/' : uri.path);
  if (uri.hasQuery) buffer.write('?${uri.query}');
  if (uri.hasFragment) buffer.write('#${uri.fragment}');
  return buffer.toString();
}

bool _isBinEntryLocation(String? value) {
  if (value == null) return false;
  final uri = Uri.tryParse(value);
  final path = uri?.path ?? value;
  return path.startsWith('/b/');
}

/// Auth screen chosen for an anonymous deep link.
///
/// Bin labels are a first-use acquisition path, so they lead to the short
/// registration form. A session that has just ended always leads to sign-in;
/// this distinction matters on borrowed phones.
String anonymousGateDestination(
  String location, {
  required bool sessionJustEnded,
  String? deferredLocation,
}) {
  final arrivedFromBin =
      _isBinEntryLocation(location) || _isBinEntryLocation(deferredLocation);
  return !sessionJustEnded && arrivedFromBin ? '/register' : '/login';
}

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

  /// The gate the previous redirect pass resolved to.
  ///
  /// Held here, in the provider body that builds the router exactly once,
  /// rather than on the listenable — the distinction that matters is only
  /// visible where the redirect runs. It exists so the anonymous branch can
  /// tell two cases apart that look identical to it: a visitor who was never
  /// signed in (remember where they were going) and a session that has just
  /// ended (forget it).
  _Gate? previousGate;

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

    // Settled, signed in, and `users/{uid}` does not exist. Which is the normal
    // middle of a registration, not evidence of a broken account: `signUp`
    // creates the Firebase account first and writes the profile second, and the
    // auth stream reports in between. Only once nobody is still writing it does
    // an absent profile mean what this gate takes it to mean.
    if (ref.read(registrationInFlightProvider)) {
      return (gate: _Gate.unresolved, user: null);
    }

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
      // The role alone is not authority. Firestore and the server both revoke
      // privileged actions during a live suspension, so the route must agree
      // instead of opening a console whose every request will be refused.
      _Gate.signedIn => canAccessAdminRoutes(user!) ? null : '/home',
    };
  }

  /// Guards the seller console (F4.1, F4.6).
  ///
  /// An administrator passes, matching `UserModel.isSeller`, the
  /// `role in ['seller', 'admin']` check in `firestore.rules` and
  /// `requireSeller` on the server. All four have to agree: a route that let a
  /// buyer through would show them a console whose every write the rules then
  /// refuse without saying why.
  String? requireSeller(BuildContext context, GoRouterState state) {
    final (gate: gate, user: user) = resolve();
    return switch (gate) {
      _Gate.unresolved => splashPath,
      _Gate.anonymous => '/login',
      _Gate.profileMissing => accountIncompletePath,
      _Gate.failed => startupErrorPath,
      // Sent to the application form rather than bounced to `/home`: a user who
      // reached this route wants to sell, and the next step exists.
      _Gate.signedIn => sellerRouteRedirect(user!),
    };
  }

  /// Guards the EPR producer portal (EPR-1, NFR-E-1).
  ///
  /// Waits on [_Gate.unresolved] rather than bouncing, for the same deep-link
  /// reason `requireAdmin` does: a producer opening `/producer/members` from a
  /// link would otherwise be redirected away in the moment before their profile
  /// loaded.
  ///
  /// A non-producer is sent to their own home, not shown an empty workspace.
  String? requireProducerRoute(BuildContext context, GoRouterState state) {
    final (gate: gate, user: user) = resolve();
    return switch (gate) {
      _Gate.unresolved => splashPath,
      _Gate.anonymous => '/login',
      _Gate.profileMissing => accountIncompletePath,
      _Gate.failed => startupErrorPath,
      // The role alone is not authority here either. A suspended producer is
      // refused by the rules and by the server, so the route agrees rather than
      // opening a workspace whose every request will be denied.
      _Gate.signedIn => canAccessProducerRoutes(user!) ? null : homeFor(user),
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

  String? requireActive(BuildContext context, GoRouterState state) {
    final signedIn = requireSignedIn(context, state);
    if (signedIn != null) return signedIn;
    return activeRouteRedirect(resolve().user!);
  }

  /// An active account currently working in its Champion profile.
  ///
  /// Admin and Greenpreneur roles both retain Champion capability, so this is
  /// a workspace check rather than a `role == buyer` check.
  String? requireChampion(BuildContext context, GoRouterState state) {
    final active = requireActive(context, state);
    if (active != null) return active;
    return ref.read(activeAccountProfileProvider) == AccountProfile.champion
        ? null
        : '/home';
  }

  return GoRouter(
    initialLocation: '/home',
    refreshListenable: refreshListenable,
    errorBuilder: (context, state) =>
        RouteErrorView(location: state.uri.toString()),
    redirect: (context, state) {
      final location = state.matchedLocation;
      // `/join` belongs here for the same reason `/register` does: it is a
      // place an anonymous visitor is *supposed* to be. It carries a
      // single-use invitation token in its query string, and the anonymous
      // branch below would otherwise redirect it to `/login` — dropping the
      // token, since a signed-out visitor has nothing to consume the pending
      // destination with, and there is no second copy of the link.
      final isAuthRoute =
          location == '/login' ||
          location == '/register' ||
          location == invitationRedeemPath;
      final isSplash = location == splashPath;
      final isIncomplete = location == accountIncompletePath;
      final isStartupError = location == startupErrorPath;

      final (gate: gate, user: _) = resolve();
      final wasSignedIn = previousGate == _Gate.signedIn;
      previousGate = gate;

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
          // A registration in progress stays on its own form.
          //
          // The splash is the right place to wait for a session we are only
          // *reading*. It is the wrong place to wait for one we are writing:
          // replacing `/register` mid-submit disposes `RegisterView`, and with
          // it both the button's "Creating your account…" spinner and the
          // `AppSnackBar` that reports failure — `_submit` guards that on
          // `mounted`, so a slow registration that failed said nothing at all.
          //
          // Staying put also means the two endings need no special handling.
          // Success resolves to `_Gate.signedIn`, whose branch already treats an
          // auth route as somewhere to leave. Failure resolves to
          // `_Gate.anonymous`, whose branch already returns null for one.
          final provisioning = ref.read(registrationInFlightProvider);
          if (isAuthRoute && provisioning) return null;
          // Hold on the splash. Anywhere else would either flash the login
          // screen at a signed-in user or show a shell with no data in it.
          if (isSplash) return null;
          // `state.uri`, not `matchedLocation`: the latter drops the query
          // string, and `/appeals/new?type=claim&id=abc` restored without it
          // becomes a form with no subject attached — which the rules then
          // refuse with a message naming two reasons that are both false.
          if (isRealDestination()) {
            pending.remember(restorableRouteLocation(state.uri));
          }
          return splashPath;

        case _Gate.anonymous:
          if (isAuthRoute) return null;
          // A session that has just ended is not an intention to return. The
          // sign-out fired this very pass while the user was still standing on,
          // say, `/wallet`, so remembering it meant the *next* person to sign in
          // on a shared handset landed on the previous one's screen.
          if (wasSignedIn) {
            pending.consume();
          } else if (isRealDestination()) {
            // Kept across sign-in: someone who follows a link, is asked to sign
            // in, and does so should arrive where the link pointed — query
            // string included, which is where /appeals/new carries its subject.
            pending.remember(restorableRouteLocation(state.uri));
          }
          // A bin QR is an acquisition path: the user has arrived to make
          // their first submission, and the smallest next step is the existing
          // three-field registration form. Its "Already a member?" action is
          // still one tap away. A deliberate sign-out continues to go to login
          // so a shared phone never implies the next person should create a new
          // account.
          return anonymousGateDestination(
            location,
            sessionJustEnded: wasSignedIn,
            deferredLocation: pending.current,
          );

        case _Gate.profileMissing:
          return isIncomplete ? null : accountIncompletePath;

        case _Gate.failed:
          return isStartupError ? null : startupErrorPath;

        case _Gate.signedIn:
          // Nothing to do on the splash but leave it, and an authenticated user
          // has no business on the sign-in screen or the recovery screen.
          //
          // The fallback is `homeFor(user)` rather than a hardcoded `/home`:
          // a producer account holds no citizen profile, so `/home` for one is
          // a screen offering a wallet, a shop and a bin scanner it cannot use
          // (EPR-1). Hardcoding a destination here is also what once discarded
          // admin deep links and terminated-state push taps, which is why the
          // remembered destination still wins.
          final signedInUser = resolve().user!;
          if (isSplash || isAuthRoute || isIncomplete || isStartupError) {
            return pending.consume() ?? homeFor(signedInUser);
          }
          // A producer that has arrived at the citizen home — by the router's
          // own `initialLocation`, or by a redirect that predates this role —
          // is moved to its own workspace.
          if (location == '/home') return producerHomeRedirect(signedInUser);
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
          final active = requireActive(context, state);
          if (active != null) return active;
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
        redirect: requireChampion,
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
        path: '/donate',
        builder: (context, state) => const DonationView(),
        redirect: requireActive,
      ),
      GoRoute(
        path: '/b/:payload',
        builder: (context, state) {
          final payload = state.pathParameters['payload'] ?? '';
          return BinEntryView(key: ValueKey(payload), payload: payload);
        },
        redirect: requireActive,
      ),
      GoRoute(
        path: '/dispose/scan',
        builder: (context, state) => const ScanView(),
        redirect: requireActive,
      ),
      GoRoute(
        path: '/dispose/photo',
        builder: (context, state) => const DisposalPhotoView(),
        redirect: requireActive,
      ),
      GoRoute(
        path: '/dispose/location',
        builder: (context, state) => const DisposalLocationView(),
        redirect: requireActive,
      ),
      GoRoute(
        path: '/dispose/declare',
        builder: (context, state) => const DisposalDeclareView(),
        redirect: requireActive,
      ),
      // ----- marketplace (F4.x) -----
      GoRoute(
        path: '/market',
        builder: (context, state) => const CatalogView(),
        redirect: requireSignedIn,
      ),
      GoRoute(
        path: '/market/:productId',
        builder: (context, state) =>
            ProductDetailView(productId: state.pathParameters['productId']!),
        redirect: requireSignedIn,
      ),
      GoRoute(
        path: '/cart',
        builder: (context, state) => const CartView(),
        redirect: requireSignedIn,
      ),
      GoRoute(
        path: '/checkout',
        builder: (context, state) => const CheckoutView(),
        redirect: requireActive,
      ),
      GoRoute(
        path: '/orders',
        builder: (context, state) => const BuyerOrdersView(),
        redirect: requireSignedIn,
      ),

      // ----- seller console (F4.1, F4.6) -----
      GoRoute(
        path: '/seller/products',
        builder: (context, state) => const SellerProductsView(),
        redirect: requireSeller,
      ),
      GoRoute(
        // Declared before the `:productId` route below, because go_router
        // matches in declaration order and `new` would otherwise be read as a
        // document id.
        path: '/seller/products/new',
        builder: (context, state) => const ProductEditView(),
        redirect: requireSeller,
      ),
      GoRoute(
        path: '/seller/products/:productId',
        builder: (context, state) =>
            ProductEditView(productId: state.pathParameters['productId']),
        redirect: requireSeller,
      ),
      GoRoute(
        path: '/seller/orders',
        builder: (context, state) => const SellerOrdersView(),
        redirect: requireSeller,
      ),
      GoRoute(
        path: '/seller/sales',
        builder: (context, state) => const SellerSalesView(),
        redirect: requireSeller,
      ),

      // ----- appeals (F5.4) -----
      GoRoute(
        path: '/appeals',
        builder: (context, state) => const AppealsView(),
        redirect: requireSignedIn,
      ),
      GoRoute(
        // Query parameters rather than path segments, because the pair is a
        // subject *reference* rather than a hierarchy — and because an appeal
        // against a claim and one against a disposal are the same screen.
        path: '/appeals/new',
        builder: (context, state) {
          final type =
              AppealSubject.fromName(state.uri.queryParameters['type']) ??
              AppealSubject.disposal;
          return AppealFormView(
            subjectType: type,
            subjectId: state.uri.queryParameters['id'] ?? '',
          );
        },
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
      GoRoute(
        path: '/admin/appeals',
        builder: (context, state) => const AdminAppealsView(),
        redirect: requireAdmin,
      ),
      GoRoute(
        path: '/admin/dashboard',
        builder: (context, state) => const AdminDashboardView(),
        redirect: requireAdmin,
      ),
      GoRoute(
        path: '/admin/producers',
        builder: (context, state) => const AdminProducersView(),
        redirect: requireAdmin,
      ),
      GoRoute(
        path: '/admin/mass-queue',
        builder: (context, state) => const AdminMassQueueView(),
        redirect: requireAdmin,
      ),

      // ---- EPR producer portal (EPR-1, NFR-E-1) ----
      //
      // Under `/producer/*`, laid out for a desktop browser. No new mobile
      // navigation destination is added to any citizen profile: these routes
      // are reachable only by a producer account, whose shell has its own
      // destination set.
      GoRoute(
        path: invitationRedeemPath,
        builder: (context, state) => InvitationRedeemView(
          // From the query string, and tolerant of an absent one: the view says
          // "no invitation in this link" rather than throwing, because a
          // truncated paste is the likeliest way to arrive here without a
          // token.
          token: state.uri.queryParameters['token'] ?? '',
        ),
      ),
      GoRoute(
        path: '/producer',
        builder: (context, state) => const ProducerDashboardView(),
        redirect: requireProducerRoute,
      ),
      GoRoute(
        path: '/producer/members',
        builder: (context, state) => const ProducerMembersView(),
        redirect: requireProducerRoute,
      ),
      GoRoute(
        path: '/producer/skus',
        builder: (context, state) => const ProducerSkusView(),
        redirect: requireProducerRoute,
      ),
      GoRoute(
        path: '/producer/skus/import',
        builder: (context, state) => const SkuImportView(),
        redirect: requireProducerRoute,
      ),
      GoRoute(
        path: '/producer/declaration',
        builder: (context, state) => const DeclarationView(),
        redirect: requireProducerRoute,
      ),
      GoRoute(
        path: '/producer/passports',
        builder: (context, state) => const PassportsView(),
        redirect: requireProducerRoute,
      ),
      GoRoute(
        path: '/producer/sdg',
        builder: (context, state) => const ProducerSdgView(),
        redirect: requireProducerRoute,
      ),
      GoRoute(
        path: '/producer/activity',
        builder: (context, state) => const ProducerActivityView(),
        redirect: requireProducerRoute,
      ),
    ],
  );
});
