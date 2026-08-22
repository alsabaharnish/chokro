import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/donation_model.dart';
import '../services/donation_service.dart';

final donationServiceProvider = Provider<DonationService>((ref) {
  return DonationService();
});

class DonationController extends AsyncNotifier<DonationOutcome?> {
  String? _requestId;
  String? _fingerprint;

  @override
  Future<DonationOutcome?> build() async => null;

  /// A changed amount or initiative is a new intent and needs a fresh key.
  void resetDraft() {
    _requestId = null;
    _fingerprint = null;
    state = const AsyncData(null);
  }

  /// Keeps one id for retries of the same intent. If the first response is lost
  /// after the server commits, pressing Try again returns that receipt instead
  /// of debiting the wallet twice.
  Future<void> donate({
    required GreenInitiative initiative,
    required int points,
  }) async {
    final fingerprint = '${initiative.wireValue}:$points';
    if (_fingerprint != fingerprint || _requestId == null) {
      _fingerprint = fingerprint;
      _requestId = _newRequestId();
    }

    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref
          .read(donationServiceProvider)
          .donate(
            donationId: _requestId!,
            initiative: initiative,
            points: points,
          ),
    );
  }

  String _newRequestId() {
    final random = Random();
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final first = random.nextInt(1 << 32).toRadixString(36);
    final second = random.nextInt(1 << 32).toRadixString(36);
    return 'dn_${now}_$first$second';
  }
}

final donationControllerProvider =
    AsyncNotifierProvider<DonationController, DonationOutcome?>(
      DonationController.new,
    );
