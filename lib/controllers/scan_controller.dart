import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/bin_model.dart';
import '../services/bin_service.dart';

final binServiceProvider = Provider<BinService>((ref) => BinService());

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

  /// The lookup itself failed — offline, or permission denied.
  error,
}

/// Result of resolving one scanned payload.
class ScanState {
  final ScanOutcome outcome;
  final BinModel? bin;
  final String? message;

  const ScanState({
    this.outcome = ScanOutcome.idle,
    this.bin,
    this.message,
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

      state = ScanState(outcome: ScanOutcome.resolved, bin: bin);
    } catch (err) {
      state = ScanState(outcome: ScanOutcome.error, message: err.toString());
    }
  }

  void reset() => state = const ScanState();
}

final scanControllerProvider =
    NotifierProvider<ScanController, ScanState>(ScanController.new);
