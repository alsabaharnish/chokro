/// The idle timeout (SEC-9).
///
/// ## WHY THIS IS ON THE CLIENT WHEN THE ABSOLUTE LIMIT IS ON THE SERVER
///
/// SEC-9 asks for both, and they defend against different adversaries.
///
/// The **absolute** session limit bounds the blast radius of a stolen
/// credential. There the client IS the attacker, so the rule is worthless
/// unless the server enforces it — and it does, from `auth_time`, in
/// `server/src/auth.js`.
///
/// The **idle** timeout defends against somebody walking up to a signed-in
/// machine that its owner left. The client is not the attacker; the device is
/// the thing at risk. Ending the session has to happen ON that device, and
/// enforcing it server-side would mean a write on every request in the product
/// to defend against an adversary who is not the one making them.
///
/// ## WHAT COUNTS AS ACTIVITY, AND WHAT DELIBERATELY DOES NOT
///
/// Pointer events, and keystrokes seen through `HardwareKeyboard` rather than
/// a `Focus` widget — see [_IdleSessionGuardState._onKey]. Not network calls,
/// not a rebuild, not a stream tick — a dashboard that polls would otherwise keep a session
/// alive forever in an empty office, which is the exact thing being guarded
/// against.
///
/// ## WHO IT APPLIES TO
///
/// Producers and Admins. A Champion photographing a bin has no compliance data
/// on their account, and signing them out mid-disposal would cost a real
/// action to protect nothing — the same reasoning that gives them a longer
/// absolute limit.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../controllers/auth_controller.dart';
import '../core/constants.dart';

/// How long a portal session may sit untouched.
///
/// Thirty minutes is the shortest window that does not interrupt real work:
/// a producer assembling a put-on-market declaration is reading spreadsheets
/// between edits, and a timeout that fires mid-filing would be turned off by
/// whoever owns the machine — which is worse than a longer one that survives.
const Duration idleTimeout = Duration(minutes: 30);

/// The roles the idle timeout applies to.
const Set<String> idleTimeoutRoles = {
  AppConstants.roleProducer,
  AppConstants.roleAdmin,
};

/// Signs a portal session out after [idleTimeout] without human input.
///
/// Wraps the app. A `Listener` rather than a `GestureDetector` because it sees
/// events during the capture phase and never competes with a child for them —
/// a gesture detector here would swallow taps meant for the screen underneath.
class IdleSessionGuard extends ConsumerStatefulWidget {
  const IdleSessionGuard({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<IdleSessionGuard> createState() => _IdleSessionGuardState();
}

class _IdleSessionGuardState extends ConsumerState<IdleSessionGuard> {
  Timer? _timer;

  /// Guards against a second sign-out while the first is in flight — the
  /// timeout and a user-initiated sign-out can race.
  bool _signingOut = false;

  @override
  void initState() {
    super.initState();
    // Started here, not only from the `ref.listen` below.
    //
    // `ref.listen` fires on CHANGES. A user who is already signed in when this
    // mounts — every cold start into an existing session, which is the common
    // case — produces no change, so no timer was armed and the control did
    // nothing at all until they happened to sign in or out again. Caught by
    // the test, not by reading it.
    HardwareKeyboard.instance.addHandler(_onKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _touched();
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _timer?.cancel();
    super.dispose();
  }

  void _touched() {
    if (_signingOut) return;
    _timer?.cancel();

    final role = ref.read(currentUserProvider).value?.role;
    // No timer at all for a role it does not apply to, rather than a timer
    // that fires and then decides to do nothing: a pending timer is a thing
    // somebody later has to reason about.
    if (role == null || !idleTimeoutRoles.contains(role)) return;

    _timer = Timer(idleTimeout, _expire);
  }

  Future<void> _expire() async {
    if (_signingOut || !mounted) return;
    _signingOut = true;
    try {
      // The ordinary sign-out, so the server-side revocation runs too. An idle
      // session that was only ended locally would leave the refresh token
      // alive — which is the half of SEC-9 this project had already missed
      // once.
      await ref.read(authControllerProvider.notifier).signOut();
    } finally {
      _signingOut = false;
    }
  }

  /// Keyboard activity, WITHOUT a `Focus` widget.
  ///
  /// A `Focus` here wrapped `MaterialApp` — above the Navigator and above the
  /// View — and Flutter's focus traversal then tried to sort descendants that
  /// had not been laid out yet:
  ///
  ///   RenderBox was not laid out: RenderSemanticsAnnotations NEEDS-LAYOUT
  ///   ... focus_traversal.dart sortDescendants → findFirstFocus
  ///
  /// It threw on the first frame in a browser, before anything rendered. The
  /// widget tests never saw it because they mount the guard INSIDE a
  /// MaterialApp, where a Focus node is ordinary.
  ///
  /// `HardwareKeyboard` is a global hook that needs no widget and takes no
  /// part in the focus tree, which is what this always wanted: a signal that
  /// somebody is at the keyboard, not a claim on where input goes.
  bool _onKey(KeyEvent _) {
    _touched();
    // False: observed, never consumed. Returning true here would swallow every
    // keystroke in the application.
    return false;
  }

  @override
  Widget build(BuildContext context) {
    // Start or restart whenever the signed-in role changes: a Champion who
    // signs out and a producer who signs in on the same device must each get
    // the right treatment without a reload.
    ref.listen(currentUserProvider, (_, _) => _touched());

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _touched(),
      onPointerSignal: (_) => _touched(),
      child: widget.child,
    );
  }
}
