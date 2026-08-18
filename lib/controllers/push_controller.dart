import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/push_service.dart';
import 'auth_controller.dart' show firebaseAuthStateProvider;

final pushServiceProvider = Provider<PushService>((ref) => PushService());

/// Keeps this device's FCM token in step with whoever is signed in (F7.1).
///
/// ## Why a listener rather than a call in `signIn`
///
/// A token has to be registered on every path that produces a session, not just
/// the one where a form was submitted: a cold start with a session already in
/// place, a token rotation, an account recovered after a failed registration.
/// Hanging registration off the auth stream covers all of them with one rule —
/// *whenever there is a uid, this device is registered against it* — instead of
/// three call sites that will drift.
///
/// This mirrors `_AuthGateListenable` in `routing/router.dart`, which reached the
/// same conclusion for the same reason.
///
/// ## Why sign-out is not handled here
///
/// Deregistration cannot be driven by the uid going null, because by then the
/// session is gone and `isSelf(uid)` in the rules is false — the delete would be
/// refused and the token stranded on the device. It has to happen *before*
/// `signOut`, which is why `AuthController.signOut` calls
/// `PushService.unregisterDevice` directly.
///
/// ## Permission timing
///
/// The prompt is raised on first sign-in rather than on first launch. A
/// permission dialog shown before the user knows what the app does is the one
/// most likely to be dismissed, and Android only asks once — a reflexive "no
/// thanks" on the splash screen costs the feature permanently.
final pushRegistrarProvider = Provider<PushRegistrar>((ref) {
  // Riverpod 3 auto-disposes by default, and nothing in the widget tree reads
  // this for its value — only for its effect. Without keepAlive the listener is
  // torn down the moment it is created, exactly as `_authGateProvider` was.
  ref.keepAlive();

  final registrar = PushRegistrar(ref);
  ref.onDispose(registrar.dispose);
  return registrar;
});

class PushRegistrar {
  PushRegistrar(this._ref) {
    if (!PushService.isSupported) return;

    // Register for whoever is signed in now, and again whenever that changes.
    _ref.listen<AsyncValue<Object?>>(
      firebaseAuthStateProvider,
      (_, _) => unawaited(_sync()),
      fireImmediately: true,
    );

    // A rotated token is a device that has silently stopped receiving anything,
    // with no error raised anywhere. Re-registering is the only signal.
    _refreshSub = _ref.read(pushServiceProvider).onTokenRefresh.listen((_) {
      unawaited(_sync());
    });
  }

  final Ref _ref;
  StreamSubscription<String>? _refreshSub;

  /// The uid the current token is registered against, so a repeated auth event
  /// for the same user does not re-write the document on every rebuild.
  String? _registeredFor;
  bool _busy = false;

  Future<void> _sync() async {
    if (_busy) return;

    final uid = _ref.read(firebaseAuthStateProvider).asData?.value?.uid;

    if (uid == null) {
      // Signed out. The document was already removed by
      // `AuthController.signOut`; all that is left is to forget the uid so the
      // next sign-in registers again.
      _registeredFor = null;
      return;
    }

    if (uid == _registeredFor) return;

    _busy = true;
    try {
      final push = _ref.read(pushServiceProvider);

      // Asked once per session, at the first moment the user has context for
      // what they are agreeing to. A denial is final on Android, so this is not
      // retried on later sign-ins within the same install.
      final granted = await push.requestPermission();
      if (!granted) {
        debugPrint('[push] Notifications not permitted; skipping registration.');
        return;
      }

      final token = await push.registerDevice(uid);
      if (token != null) _registeredFor = uid;
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _refreshSub?.cancel();
  }
}

/// Messages that arrive while the app is open and on screen.
///
/// Android does not raise a tray notification for a foreground message, which
/// is correct — a system notification for something the user is already looking
/// at is noise. The app renders these as an in-app banner instead; see
/// `ChokroApp` in `main.dart`.
final pushMessageProvider = StreamProvider<RemoteMessage>((ref) {
  return ref.watch(pushServiceProvider).onMessage;
});

/// Tray notifications tapped while the app was backgrounded.
final pushOpenedProvider = StreamProvider<RemoteMessage>((ref) {
  return ref.watch(pushServiceProvider).onMessageOpenedApp;
});

/// Where a notification wants to take the user.
///
/// The server sets `data.route`; this refuses anything it does not recognise
/// rather than passing an arbitrary string to `go`. A malformed or hostile
/// payload should land the user somewhere harmless, not on an error screen —
/// and `go_router` would otherwise render `RouteErrorView` for an unknown path.
String? routeForMessage(RemoteMessage message) {
  // Must agree with the routes `server/src/push.js` emits, and every entry must
  // be a real path in `routing/router.dart` — an unknown one would otherwise
  // render `RouteErrorView`. `push.test.js` mirrors this set and fails if the
  // server starts emitting something not listed here.
  //
  // `/claims/new` is where a *rejected* eco-action goes: it credits nothing, so
  // the wallet has no entry to show, while that screen lists each claim's status
  // and reason.
  const known = {'/history', '/wallet', '/home', '/claims/new'};
  final route = message.data['route'];
  if (route is String && known.contains(route)) return route;
  return null;
}

/// One line of copy for the in-app banner.
///
/// Falls back to the data payload when the notification block is absent, which
/// is the case for a data-only message.
String bannerTextFor(RemoteMessage message) {
  final body = message.notification?.body;
  if (body != null && body.trim().isNotEmpty) return body.trim();

  final title = message.notification?.title;
  if (title != null && title.trim().isNotEmpty) return title.trim();

  return 'A submission of yours was decided.';
}
