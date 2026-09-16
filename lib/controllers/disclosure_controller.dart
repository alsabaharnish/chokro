/// Regulator disclosure state (SEC-13).
///
/// ## The unlock is client-side convenience, not the control
///
/// [disclosureUnlockProvider] tracks whether this Admin has stepped up
/// recently, so the screen knows whether to show the form or the padlock. It is
/// NOT what stops an unauthorised disclosure — the server does that, by reading
/// `auth_time` from the ID token and refusing a stale one.
///
/// The distinction matters because a client-side timer can be lied to and the
/// token claim cannot. This provider exists so the Admin is told what will
/// happen before they type a declaration, not so the rule is enforced here.
///
/// The client window is deliberately SHORTER than the server's, so the screen
/// asks for a password again slightly before the server would have refused —
/// an expired unlock discovered after filling in a form is a form to fill in
/// twice.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/disclosure_model.dart';
import '../services/disclosure_service.dart';

final disclosureServiceProvider = Provider<DisclosureService>(
  (ref) => DisclosureService(),
);

/// The server refuses an `auth_time` older than five minutes.
const Duration serverUnlockWindow = Duration(minutes: 5);

/// What the screen treats as unlocked. Thirty seconds of headroom.
const Duration clientUnlockWindow = Duration(minutes: 4, seconds: 30);

/// The clock, injectable so a test does not depend on wall time.
final disclosureClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

/// When this Admin last proved their password. Null until they do.
class DisclosureUnlockController extends Notifier<DateTime?> {
  @override
  DateTime? build() => null;

  void unlocked() => state = ref.read(disclosureClockProvider)();

  /// Dropped on purpose after a disclosure, so a second one is a second
  /// decision rather than a free one.
  void lock() => state = null;

  bool get isUnlocked {
    final at = state;
    if (at == null) return false;
    return ref.read(disclosureClockProvider)().difference(at) <
        clientUnlockWindow;
  }

  /// How long is left, or null when locked. Shown, so an Admin about to write
  /// a declaration knows whether they have time to finish it.
  Duration? get remaining {
    final at = state;
    if (at == null) return null;
    final left =
        clientUnlockWindow - ref.read(disclosureClockProvider)().difference(at);
    return left.isNegative ? null : left;
  }
}

final disclosureUnlockProvider =
    NotifierProvider<DisclosureUnlockController, DateTime?>(
      DisclosureUnlockController.new,
    );

/// The register. Readable without stepping up — see [DisclosureService].
final disclosureRegisterProvider =
    FutureProvider.autoDispose<DisclosureRegister>(
      (ref) => ref.watch(disclosureServiceProvider).register(),
    );
