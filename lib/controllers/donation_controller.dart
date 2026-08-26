import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/donation_model.dart';
import '../models/payment_model.dart';
import '../services/donation_service.dart';

final donationServiceProvider = Provider<DonationService>((ref) {
  return DonationService();
});

class DonationController extends AsyncNotifier<DonationOutcome?> {
  String? _requestId;
  String? _fingerprint;

  @override
  Future<DonationOutcome?> build() async => null;

  /// Whether the outcome now held has been shown to the user.
  ///
  /// The controller is not `autoDispose`, so a `donate()` that is still in
  /// flight when the user leaves the screen finishes and stores its receipt
  /// with nobody watching. Re-entering must tell that apart from a receipt the
  /// user has already read: the first has to be shown, the second cleared.
  bool _seen = false;

  bool get outcomeWasSeen => _seen;

  /// Marks the held receipt as read. Called by the success screen as it builds.
  void markOutcomeSeen() => _seen = true;

  /// Clears the displayed outcome, leaving the idempotency key alone.
  ///
  /// **Does not mint a new key**, and that is the whole point. This used to
  /// null `_requestId`, and the screen calls it from six ordinary-interaction
  /// callbacks — every keystroke in the amount field, every suggested-amount
  /// chip, the initiative radio, the mode switch. So a donation that failed
  /// with the response lost in flight, followed by the user tapping the same
  /// 100-point chip and pressing send again, minted a *second* key: the server
  /// keys idempotency on `${uid}_${donationId}`, so it committed a second
  /// debit for what the user experienced as one retry.
  ///
  /// [donate] already mints a key whenever the intent genuinely changes, by
  /// comparing the fingerprint. That check is sufficient and this method was
  /// actively defeating it.
  void resetDraft() {
    _seen = false;
    state = const AsyncData(null);
  }

  /// Deliberately begins a *new* donation, discarding the previous key.
  ///
  /// For "Support another initiative" and for re-entering the screen after the
  /// last receipt was read — the two places where the user has genuinely
  /// finished with the previous donation and a repeat of the same amount to the
  /// same initiative must be a second donation rather than an idempotent
  /// replay of the first.
  void startNewDonation() {
    _requestId = null;
    _fingerprint = null;
    resetDraft();
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

class PrototypeDonationController
    extends AsyncNotifier<PrototypeDonationOutcome?> {
  String? _requestId;
  String? _fingerprint;

  @override
  Future<PrototypeDonationOutcome?> build() async => null;

  /// See [DonationController.outcomeWasSeen].
  bool _seen = false;

  bool get outcomeWasSeen => _seen;

  void markOutcomeSeen() => _seen = true;

  /// Clears the displayed outcome only — see [DonationController.resetDraft]
  /// for why this must not touch the idempotency key.
  void resetDraft() {
    _seen = false;
    state = const AsyncData(null);
  }

  /// See [DonationController.startNewDonation].
  void startNewDonation() {
    _requestId = null;
    _fingerprint = null;
    resetDraft();
  }

  Future<void> donate({
    required GreenInitiative initiative,
    required int amountTaka,
    required SettlementMethod settlementMethod,
  }) async {
    final fingerprint =
        '${initiative.wireValue}:$amountTaka:${settlementMethod.name}';
    if (_fingerprint != fingerprint || _requestId == null) {
      _fingerprint = fingerprint;
      _requestId = _newPrototypeRequestId();
    }

    state = const AsyncLoading();
    state = await AsyncValue.guard(
      () => ref
          .read(donationServiceProvider)
          .donatePrototypePayment(
            donationId: _requestId!,
            initiative: initiative,
            amountTaka: amountTaka,
            settlementMethod: settlementMethod,
          ),
    );
  }

  String _newPrototypeRequestId() {
    final random = Random();
    final now = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final first = random.nextInt(1 << 32).toRadixString(36);
    final second = random.nextInt(1 << 32).toRadixString(36);
    return 'pdn_${now}_$first$second';
  }
}

final prototypeDonationControllerProvider =
    AsyncNotifierProvider<
      PrototypeDonationController,
      PrototypeDonationOutcome?
    >(PrototypeDonationController.new);
