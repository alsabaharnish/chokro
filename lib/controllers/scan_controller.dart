import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/label_format.dart';
import '../models/bin_model.dart';
import '../services/bin_service.dart';
import '../services/lockout_service.dart';
import '../core/network_errors.dart';

final binServiceProvider = Provider<BinService>((ref) => BinService());

final lockoutServiceProvider = Provider<LockoutService>(
  (ref) => LockoutService(),
);

/// What happened when a scanned code was looked up.
///
/// A sealed-style enum rather than a nullable bin, because "no bin found" and
/// "bin found but closed" need different messages and only one of them means
/// the user should try a different bin.
enum ScanOutcome {
  /// Nothing scanned yet.
  idle,

  /// Looking the payload up in Firestore.
  resolving,

  /// Bin found and accepting submissions.
  resolved,

  /// No bin carries this payload.
  unknownCode,

  /// Bin exists but is no longer in service.
  binClosed,

  /// Bin is fine, but this user submitted here recently (F2.6).
  ///
  /// Checked here rather than left to the write, because the rules can only
  /// answer with `permission-denied` and cannot say which condition failed. A
  /// user who found out at submit time had already photographed a bag and waited
  /// for a GPS fix for nothing.
  lockedOut,

  /// The lookup itself failed — offline, or permission denied.
  error,
}

/// Result of resolving one scanned payload.
class ScanState {
  final ScanOutcome outcome;
  final BinModel? bin;
  final String? message;

  /// When the lockout on this bin lifts. Only set for [ScanOutcome.lockedOut].
  final DateTime? lockedUntil;

  const ScanState({
    this.outcome = ScanOutcome.idle,
    this.bin,
    this.message,
    this.lockedUntil,
  });

  bool get isBusy => outcome == ScanOutcome.resolving;
  bool get canProceed => outcome == ScanOutcome.resolved && bin != null;

  /// Message for the user. Deliberately distinguishes the failure modes: being
  /// told "this bin is closed" tells you to walk to another one, while "code not
  /// recognised" tells you the code is not ours at all.
  String get displayMessage {
    switch (outcome) {
      case ScanOutcome.idle:
        return 'Point the camera at the code on the bin.';
      case ScanOutcome.resolving:
        return 'Looking up this bin…';
      case ScanOutcome.resolved:
        return bin?.label ?? 'Bin found.';
      case ScanOutcome.unknownCode:
        return 'This code is not a Chokro bin.';
      case ScanOutcome.binClosed:
        return 'This bin is no longer in service. Try another one.';
      case ScanOutcome.lockedOut:
        return 'You already submitted at this bin. You can use it again in '
            '${formatCountdown(lockedUntil)}, or use a different bin now.';
      case ScanOutcome.error:
        return message ?? 'Could not check this code. Check your connection.';
    }
  }
}

/// Resolves scanned payloads to bins.
class ScanController extends Notifier<ScanState> {
  @override
  ScanState build() => const ScanState();

  /// Looks up [payload] and updates state with the outcome.
  ///
  /// Ignores repeat scans while a lookup is in flight — the camera fires
  /// continuously, and without this a single code produces a burst of identical
  /// Firestore queries.
  Future<void> resolve(String payload) async {
    if (state.isBusy) return;

    state = const ScanState(outcome: ScanOutcome.resolving);

    try {
      final bin = await ref.read(binServiceProvider).resolveByPayload(payload);

      if (bin == null) {
        state = const ScanState(outcome: ScanOutcome.unknownCode);
        return;
      }

      if (!bin.active) {
        state = ScanState(outcome: ScanOutcome.binClosed, bin: bin);
        return;
      }

      // The lockout window the rules will check on the write (F2.6). Feedback
      // only — the rules re-evaluate it against `request.time`, so nothing is
      // trusted because the client looked.
      final binId = bin.id;
      final uid = FirebaseAuth.instance.currentUser?.uid;

      if (binId != null && uid != null) {
        final until = await ref
            .read(lockoutServiceProvider)
            .activeUntil(uid: uid, binId: binId);

        if (until != null) {
          state = ScanState(
            outcome: ScanOutcome.lockedOut,
            bin: bin,
            lockedUntil: until,
          );
          return;
        }
      }

      state = ScanState(outcome: ScanOutcome.resolved, bin: bin);
    } catch (err) {
      // `friendlyErrorMessage`, not `err.toString()`.
      //
      // This is the first screen of the disposal flow, so a rules or
      // connectivity failure here used to put
      // `[cloud_firestore/permission-denied] Missing or insufficient
      // permissions.` in front of a resident standing at a bin — the exact
      // string `network_errors.dart` was written to eliminate.
      state = ScanState(
        outcome: ScanOutcome.error,
        message: friendlyErrorMessage(err),
      );
    }
  }

  void reset() => state = const ScanState();
}

final scanControllerProvider = NotifierProvider<ScanController, ScanState>(
  ScanController.new,
);
