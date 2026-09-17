/// Activation chooses the right providers, and never takes the app down.
///
/// The property that matters most is the one a passing build would not show
/// you: **a release build must never attest with a debug provider.** That
/// combination reports success, satisfies an enforcing server, and proves
/// nothing — attestation that any caller can obtain is worse than none,
/// because the console says the control is on.
library;

import 'package:chokro/core/app_check_setup.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter_test/flutter_test.dart';

/// Captures the providers activation was asked for.
class _Spy {
  WebProvider? web;
  AndroidAppCheckProvider? android;
  AppleAppCheckProvider? apple;
  int calls = 0;

  Future<void> call(
    WebProvider w,
    AndroidAppCheckProvider a,
    AppleAppCheckProvider ap,
  ) async {
    calls++;
    web = w;
    android = a;
    apple = ap;
  }
}

void main() {
  test('a release build attests with real providers', () async {
    final spy = _Spy();

    final result = await activateAppCheck(
      debugProviders: false,
      activator: spy.call,
      webKey: 'site-key',
    );

    expect(result, AppCheckActivation.activated);
    expect(spy.android, isA<AndroidPlayIntegrityProvider>());
    expect(spy.apple, isA<AppleAppAttestWithDeviceCheckFallbackProvider>());
    expect(spy.web, isA<ReCaptchaV3Provider>());
  });

  test('a release build never attests with a debug provider', () async {
    // The whole point. A debug provider in a shipped build makes the control
    // report itself as working while proving nothing about the caller.
    final spy = _Spy();

    await activateAppCheck(
      debugProviders: false,
      activator: spy.call,
      webKey: 'site-key',
    );

    expect(spy.android, isNot(isA<AndroidDebugProvider>()));
    expect(spy.apple, isNot(isA<AppleDebugProvider>()));
    expect(spy.web, isNot(isA<WebDebugProvider>()));
  });

  test('a debug build attests with debug providers', () async {
    final spy = _Spy();

    final result = await activateAppCheck(
      debugProviders: true,
      activator: spy.call,
      webKey: '',
    );

    expect(result, AppCheckActivation.debug);
    expect(spy.android, isA<AndroidDebugProvider>());
    expect(spy.apple, isA<AppleDebugProvider>());
    expect(spy.web, isA<WebDebugProvider>());
  });

  test('a debug build needs no reCAPTCHA key', () async {
    // The debug provider prints a token instead of using a key, so a local run
    // must not be gated on a console step that only matters for release.
    final spy = _Spy();

    final result = await activateAppCheck(
      debugProviders: true,
      activator: spy.call,
      webKey: '',
    );

    expect(result, AppCheckActivation.debug);
    expect(spy.calls, 1);
  });

  test('a failure is reported, not thrown', () async {
    // Every reason this can fail is ordinary: no Play Services, a simulator
    // without App Attest, a key not yet provisioned. None of them should
    // black-screen the app — the server refuses an unattested request with a
    // status that says so, which is the honest place for that refusal.
    final result = await activateAppCheck(
      debugProviders: false,
      webKey: 'site-key',
      activator: (_, _, _) async => throw StateError('no provider here'),
    );

    expect(result, AppCheckActivation.failed);
  });

  test('a synchronous throw is caught too', () async {
    final result = await activateAppCheck(
      debugProviders: false,
      webKey: 'site-key',
      activator: (_, _, _) => throw StateError('thrown before the future'),
    );

    expect(result, AppCheckActivation.failed);
  });

  test('the reCAPTCHA key is a build input with no default', () async {
    // A key baked in as a constant is one that is wrong for every environment
    // but the one it was copied from, and a wrong key fails at runtime looking
    // exactly like a network fault.
    expect(recaptchaSiteKey, isEmpty);
  });
}
