/// Activating App Check at startup (SEC-10, NFR-E-9).
///
/// Separate from `main.dart` so the decision this makes is testable and so the
/// reasoning sits next to it rather than in a startup sequence that already
/// carries four other concerns.
///
/// ## Why activation must never fail startup
///
/// Every provider here can be unavailable for an ordinary reason: a web build
/// whose reCAPTCHA key is not provisioned yet, an Android device with no Play
/// Services, an iOS simulator where App Attest does not exist, a desktop
/// target with no provider at all. None of those should black-screen the app.
///
/// The server holds the decision that matters. `APP_CHECK_ENFORCED` is
/// fail-closed once set, so a build that cannot attest is refused THERE, with
/// a clear status, rather than refusing to start HERE with a blank screen.
/// Activation is therefore best-effort and says so when it fails.
///
/// ## The web key is a deployment input, not a constant
///
/// reCAPTCHA site keys differ per Firebase project and per environment, and a
/// wrong one fails at runtime in a way that looks like a network problem. It is
/// read from `--dart-define=CHOKRO_RECAPTCHA_SITE_KEY=...` so a build carries
/// its own, and an unset key skips web activation with a message rather than
/// activating against a key that cannot work.
library;

import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

/// The reCAPTCHA v3 site key for the web build.
///
/// Empty by default, which is a meaningful value: it means this build was not
/// given one, and web activation is skipped rather than attempted with a key
/// that is certain to be rejected.
const String recaptchaSiteKey = String.fromEnvironment(
  'CHOKRO_RECAPTCHA_SITE_KEY',
);

/// What [activateAppCheck] decided, for logs and for tests.
enum AppCheckActivation {
  /// Activated against real attestation providers.
  activated,

  /// Activated with debug providers, which require the printed debug token to
  /// be registered in the Firebase console.
  debug,

  /// Deliberately skipped — no web site key was supplied to this build.
  skippedNoWebKey,

  /// Attempted and threw. Requests will be sent unattested.
  failed,
}

/// Performs the activation. Injectable so the decision above it is testable
/// without a Firebase binding, which a unit test has no way to provide.
typedef AppCheckActivator =
    Future<void> Function(
      WebProvider web,
      AndroidAppCheckProvider android,
      AppleAppCheckProvider apple,
    );

Future<void> _activate(
  WebProvider web,
  AndroidAppCheckProvider android,
  AppleAppCheckProvider apple,
) => FirebaseAppCheck.instance.activate(
  providerWeb: web,
  providerAndroid: android,
  providerApple: apple,
);

/// Turns App Check on, and never throws.
///
/// [debugProviders] forces the debug providers on every platform. It defaults
/// to [kDebugMode], so a release build cannot accidentally ship attesting with
/// a debug provider — which would make attestation meaningless while still
/// reporting success, and is therefore worse than not attesting at all.
Future<AppCheckActivation> activateAppCheck({
  bool? debugProviders,
  AppCheckActivator? activator,
  String webKey = recaptchaSiteKey,
}) async {
  final activate = activator ?? _activate;
  final debug = debugProviders ?? kDebugMode;

  // Web cannot activate without a key, and attempting it anyway produces a
  // runtime failure that reads like a network fault. Skipping is the honest
  // outcome, and it is reported rather than silent.
  if (kIsWeb && !debug && webKey.isEmpty) {
    debugPrint(
      '[appcheck] Skipped: no reCAPTCHA site key. Build with '
      '--dart-define=CHOKRO_RECAPTCHA_SITE_KEY=<key> to attest the web build. '
      'Requests will be REFUSED if the server has APP_CHECK_ENFORCED=true.',
    );
    return AppCheckActivation.skippedNoWebKey;
  }

  try {
    await activate(
      // The debug provider needs no key; it prints a token on first run that
      // is registered in the Firebase console.
      debug ? WebDebugProvider() : ReCaptchaV3Provider(webKey),
      debug
          ? const AndroidDebugProvider()
          : const AndroidPlayIntegrityProvider(),
      // App Attest with a DeviceCheck fallback rather than App Attest alone.
      //
      // Not for the version floor — this app requires iOS 15 and App Attest
      // arrived in 14. It is for the cases where App Attest is present and
      // still cannot produce a key: a device whose Secure Enclave attestation
      // Apple declines, a build whose App ID has not had the capability
      // enabled, or Apple's attestation service being unreachable. Alone,
      // each of those is an install that cannot talk to an enforcing server
      // and reports it to the user as a network error.
      debug
          ? const AppleDebugProvider()
          : const AppleAppAttestWithDeviceCheckFallbackProvider(),
    );

    if (debug) {
      debugPrint(
        '[appcheck] Active with DEBUG providers. The debug token printed '
        'above must be registered in Firebase console → App Check → Apps → '
        'Manage debug tokens, or the server will refuse attested requests.',
      );
      return AppCheckActivation.debug;
    }
    return AppCheckActivation.activated;
  } catch (error, stack) {
    // Never fatal. See the library comment: the server is where a build that
    // cannot attest gets refused, with a status that says so.
    debugPrint(
      '[appcheck] Activation failed: $error\n$stack\n'
      '[appcheck] Requests will be sent unattested. They will be REFUSED if '
      'the server has APP_CHECK_ENFORCED=true.',
    );
    return AppCheckActivation.failed;
  }
}
