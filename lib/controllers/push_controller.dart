import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/push_service.dart';
import 'auth_controller.dart' show firebaseAuthStateProvider;

final pushServiceProvider = Provider<PushService>((ref) => PushService());

/// Current operating-system notification permission, read without prompting.
final pushPermissionProvider = FutureProvider.autoDispose<PushPermissionStatus>(
  (ref) => ref.watch(pushServiceProvider).permissionStatus(),
);

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
/// Registration starts automatically when permission is already available.
/// A person who has not decided yet first gets an explanation and an explicit
/// enable action on Profile; only that action opens the system prompt.
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
      unawaited(_sync(forceRegistration: true, forcePermissionCheck: true));
    });
  }

  final Ref _ref;
  StreamSubscription<String>? _refreshSub;

  /// The uid the current token is registered against, so a repeated auth event
  /// for the same user does not re-write the document on every rebuild.
  String? _registeredFor;
  bool _busy = false;
  bool _queued = false;
  bool _forceRegistration = false;
  bool _forcePermissionCheck = false;

  /// Permission is checked at most once per signed-in session unless Profile
  /// explicitly asks for a refresh after the person changes device settings.
  String? _permissionCheckedFor;
  bool _permissionGranted = false;

  /// Coalesces auth and token events instead of dropping any that arrive while
  /// an earlier permission/token operation is in flight.
  ///
  /// Dropping is particularly bad on a shared device: user B can sign in while
  /// user A's registration is still awaiting the OS, and the one event that
  /// should register B used to return at [_busy] and disappear permanently.
  Future<void> _sync({
    bool forceRegistration = false,
    bool forcePermissionCheck = false,
  }) async {
    _queued = true;
    _forceRegistration = _forceRegistration || forceRegistration;
    _forcePermissionCheck = _forcePermissionCheck || forcePermissionCheck;
    if (_busy) return;

    _busy = true;
    try {
      while (_queued) {
        final force = _forceRegistration;
        final recheckPermission = _forcePermissionCheck;
        _queued = false;
        _forceRegistration = false;
        _forcePermissionCheck = false;
        await _syncOnce(
          forceRegistration: force,
          forcePermissionCheck: recheckPermission,
        );
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _syncOnce({
    required bool forceRegistration,
    required bool forcePermissionCheck,
  }) async {
    final uid = _currentUid;

    if (uid == null) {
      // Signed out. The document was already removed by
      // `AuthController.signOut`; all that is left is to forget the uid so the
      // next sign-in registers again.
      _registeredFor = null;
      _permissionCheckedFor = null;
      _permissionGranted = false;
      return;
    }

    final push = _ref.read(pushServiceProvider);

    if (forcePermissionCheck || _permissionCheckedFor != uid) {
      // Read only. The system prompt belongs to the contextual action on the
      // profile screen, not to a background auth listener.
      final permission = await push.permissionStatus();
      if (_currentUid != uid) {
        _queued = true;
        return;
      }
      // A transient plugin failure is not a user decision. Leave it unchecked
      // so a later auth/token event can try the read again.
      if (permission == PushPermissionStatus.unavailable) return;
      _permissionCheckedFor = uid;
      _permissionGranted = permission == PushPermissionStatus.enabled;
    }

    if (!_permissionGranted) {
      debugPrint('[push] Notifications not permitted; skipping registration.');
      return;
    }

    // A lifecycle resume needs to refresh the permission card, not rewrite the
    // same Firestore device document every time the app returns to foreground.
    if (!forceRegistration && uid == _registeredFor) return;

    if (_currentUid != uid) {
      _queued = true;
      return;
    }

    final token = await push.registerDevice(uid);
    if (_currentUid != uid) {
      _queued = true;
      return;
    }
    if (token != null) _registeredFor = uid;
  }

  /// Opens the notification permission sheet after the app has explained why.
  Future<bool> enableNotifications() async {
    final uid = _currentUid;
    if (uid == null || !PushService.isSupported) return false;

    final granted = await _ref.read(pushServiceProvider).requestPermission();
    if (_currentUid != uid) {
      _queued = true;
      return false;
    }

    _permissionCheckedFor = uid;
    _permissionGranted = granted;
    if (granted) {
      _registeredFor = null;
      await _sync(forceRegistration: true);
    }
    _ref.invalidate(pushPermissionProvider);
    return granted;
  }

  /// Rechecks permission after the user returns from operating-system settings.
  Future<void> refreshPermission() async {
    await _sync(forcePermissionCheck: true);
    _ref.invalidate(pushPermissionProvider);
  }

  String? get _currentUid =>
      _ref.read(firebaseAuthStateProvider).asData?.value?.uid;

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
  // `/claims` is where a *rejected* eco-action goes: it credits nothing, so the
  // wallet has no entry to show and `/history` lists disposals only, while that
  // screen is the eco-action history with each claim's status and reason. It
  // briefly pointed at `/claims/new`, which is the submit form.
  const known = {'/history', '/wallet', '/home', '/claims'};
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

  // Some providers strip the notification block from a foreground/data-only
  // delivery. Accept equivalent copy from data without trusting its type.
  final dataBody = message.data['body'];
  if (dataBody is String && dataBody.trim().isNotEmpty) {
    return dataBody.trim();
  }

  final dataTitle = message.data['title'];
  if (dataTitle is String && dataTitle.trim().isNotEmpty) {
    return dataTitle.trim();
  }

  return 'A submission of yours was decided.';
}
