import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

/// Push notification plumbing (F7.1).
///
/// ## What this class may and may not do
///
/// It registers *this* device's token and reads incoming messages. It does not
/// send anything, and there is no method here that could. §5.1 puts push sends
/// on the server side of the trust boundary alongside wallet writes, for the
/// same reason: a device that could push to other users could tell someone their
/// submission was approved when it was not. Sending lives in `server/src/push.js`
/// and holds the credentials to prove it.
///
/// ## Why the token lives in a subcollection
///
/// `users/{uid}/devices/{token}`, not a field on the user document.
///
/// The self-update rule on `users/{uid}` is `affectedKeys().hasOnly(['name'])` —
/// the tightest rule in the file, and the one that stops a user promoting
/// themselves to admin. Adding `fcmTokens` to that list to store an array would
/// widen exactly the rule that should never widen. A subcollection is invisible
/// to it: `match /users/{uid}` does not cover subcollections under rules_version
/// 2, so the devices rule is purely additive and the user rule is untouched.
///
/// It is also the better shape. A person has more than one device, the token
/// rotates, and dead tokens have to be deleted individually when FCM reports
/// them — all of which are one-document operations in a subcollection and
/// array-surgery on a field.
///
/// The token itself is the document ID, which makes registration idempotent:
/// app start and `onTokenRefresh` both write, and the same token lands on the
/// same document instead of accumulating duplicates.
///
/// ## Platform
///
/// Mobile only, matching the F7.1 row in §7. Web push needs a VAPID key pair and
/// a service worker, and the disposal flow that generates most notifications is
/// already mobile-only. [isSupported] is checked before every call rather than
/// letting the plugin throw on an unsupported platform.
class PushService {
  PushService({this._messaging, this._firestore});

  /// Injected by tests; null in production, where the lazy getters below resolve
  /// the real singletons on first use.
  final FirebaseMessaging? _messaging;
  final FirebaseFirestore? _firestore;

  /// Resolved on use, never in a field initializer.
  ///
  /// Same reasoning as `UserService._db`: as a `final` field this would run at
  /// construction and throw unless Firebase had already been initialised, which
  /// makes the class impossible to build in a unit test.
  FirebaseMessaging get _fcm => _messaging ?? FirebaseMessaging.instance;
  FirebaseFirestore get _db => _firestore ?? FirebaseFirestore.instance;

  /// Whether push is available on this build.
  ///
  /// False on web (no VAPID key configured) and on desktop. Every public method
  /// returns a benign value rather than throwing when this is false, so callers
  /// do not each have to guard.
  static bool get isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  /// The value written to `platform`, matching the vocabulary the rules accept.
  static String get _platformName {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
  }

  CollectionReference<Map<String, dynamic>> _devices(String uid) =>
      _db.collection('users').doc(uid).collection('devices');

  // ── permission ────────────────────────────────────────────────────────────

  /// Asks for notification permission, returning whether it was granted.
  ///
  /// On Android 13 and above this raises the runtime `POST_NOTIFICATIONS`
  /// prompt; below that, notifications are granted at install time and this
  /// returns true without showing anything. On iOS it is the standard prompt.
  ///
  /// `provisional: false` is deliberate. A provisional authorisation on iOS
  /// delivers quietly to the notification centre with no sound and no banner,
  /// which for a message that says "50 points added" is indistinguishable from
  /// not sending it at all.
  ///
  /// A denial is a legitimate answer, not an error. The submission history
  /// screen (F7.2) shows every decision regardless, so a user who says no still
  /// learns the outcome — they just have to open the app to do it.
  Future<bool> requestPermission() async {
    if (!isSupported) return false;

    try {
      final settings = await _fcm.requestPermission(
        alert: true,
        badge: true,
        sound: true,
        provisional: false,
      );

      return settings.authorizationStatus == AuthorizationStatus.authorized ||
          settings.authorizationStatus == AuthorizationStatus.provisional;
    } catch (err) {
      debugPrint('[push] Permission request failed: $err');
      return false;
    }
  }

  // ── registration ──────────────────────────────────────────────────────────

  /// Registers this device against [uid] and returns the token, or null.
  ///
  /// Safe to call repeatedly — the token is the document ID, so a second call
  /// with the same token rewrites one document rather than adding another.
  ///
  /// The write carries **only** `platform` and `updatedAt`, and that is a hard
  /// requirement rather than tidiness. The rule is:
  ///
  ///     allow create, update: if isSelf(uid)
  ///       && request.resource.data.keys().hasOnly(['platform', 'updatedAt'])
  ///       && request.resource.data.updatedAt == request.time
  ///
  /// `hasOnly` means an extra field — a device name, an app version, anything
  /// that looks harmless — fails the write with permission-denied, and the
  /// failure reads like a rules misconfiguration rather than an extra key. The
  /// same trap as [UserService.updateName]; the same answer.
  ///
  /// `set` without `merge` is what keeps the key set exact on a rewrite.
  ///
  /// Never throws. A failure here must not break sign-in, which is the flow that
  /// calls it.
  Future<String?> registerDevice(String uid) async {
    if (!isSupported || uid.isEmpty) return null;

    try {
      final token = await _fcm.getToken();
      if (token == null || token.isEmpty) {
        // Normal on an emulator without Google Play services, and on a device
        // where the user declined the permission prompt.
        debugPrint('[push] No FCM token available on this device.');
        return null;
      }

      await _devices(uid).doc(token).set({
        'platform': _platformName,
        'updatedAt': FieldValue.serverTimestamp(),
      });

      return token;
    } catch (err) {
      debugPrint('[push] Device registration failed: $err');
      return null;
    }
  }

  /// Retires this device's token for [uid].
  ///
  /// MUST BE CALLED BEFORE `signOut`, not after.
  ///
  /// Once the session ends, `isSelf(uid)` is false and the rules refuse the
  /// delete — the document would be stranded, and the next decision for the
  /// previous user would light up the phone of whoever signed in afterwards.
  /// Shared and borrowed phones are the norm in this project's setting, so that
  /// is a real leak of one user's rejection reason to another, not a
  /// hypothetical one.
  ///
  /// [deleteToken] also asks FCM to discard the token itself, so the next
  /// sign-in mints a fresh one rather than resurrecting the document we just
  /// removed.
  ///
  /// Never throws. Sign-out must not be blocked by a failed cleanup.
  Future<void> unregisterDevice(String uid) async {
    if (!isSupported || uid.isEmpty) return;

    try {
      final token = await _fcm.getToken();
      if (token != null && token.isNotEmpty) {
        await _devices(uid).doc(token).delete();
      }
      await _fcm.deleteToken();
    } catch (err) {
      debugPrint('[push] Device unregistration failed: $err');
    }
  }

  /// Fires when FCM rotates this device's token.
  ///
  /// Rotation happens on reinstall, on a data clear, and occasionally at FCM's
  /// discretion. A token that rotates without being re-registered is a device
  /// that silently stops receiving anything, with no error anywhere — so this
  /// stream is not optional plumbing.
  Stream<String> get onTokenRefresh =>
      isSupported ? _fcm.onTokenRefresh : const Stream<String>.empty();

  // ── incoming ──────────────────────────────────────────────────────────────

  /// Messages that arrive while the app is open and on screen.
  ///
  /// Android deliberately does **not** raise a tray notification for a message
  /// carrying a `notification` block while the app is in the foreground, so
  /// nothing appears unless we render it. See `pushMessageProvider` for what the
  /// app does with these.
  Stream<RemoteMessage> get onMessage => isSupported
      ? FirebaseMessaging.onMessage
      : const Stream<RemoteMessage>.empty();

  /// Fires when a tray notification is tapped and the app was in the background.
  Stream<RemoteMessage> get onMessageOpenedApp => isSupported
      ? FirebaseMessaging.onMessageOpenedApp
      : const Stream<RemoteMessage>.empty();

  /// The notification that launched the app from a terminated state, if any.
  ///
  /// Separate from [onMessageOpenedApp] because the app was not running to
  /// receive the event — this is the only way to recover it, and it must be
  /// read once at startup or the tap is lost.
  Future<RemoteMessage?> initialMessage() async {
    if (!isSupported) return null;
    try {
      return await _fcm.getInitialMessage();
    } catch (err) {
      debugPrint('[push] Reading the initial message failed: $err');
      return null;
    }
  }
}
