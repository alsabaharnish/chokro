import 'package:chokro/controllers/donation_controller.dart';
import 'package:chokro/models/donation_model.dart';
import 'package:chokro/models/payment_model.dart';
import 'package:chokro/services/donation_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingDonationService extends DonationService {
  final requestIds = <String>[];
  bool failNext = false;
  bool failNextPrototype = false;

  @override
  Future<DonationOutcome> donate({
    required String donationId,
    required GreenInitiative initiative,
    required int points,
  }) async {
    requestIds.add(donationId);
    if (failNext) {
      failNext = false;
      throw const DonationException('The response was lost.');
    }
    return DonationOutcome(
      donationId: donationId,
      initiative: initiative,
      points: points,
      balanceAfter: 400 - points,
    );
  }

  @override
  Future<PrototypeDonationOutcome> donatePrototypePayment({
    required String donationId,
    required GreenInitiative initiative,
    required int amountTaka,
    required SettlementMethod settlementMethod,
  }) async {
    requestIds.add(donationId);
    if (failNextPrototype) {
      failNextPrototype = false;
      throw const DonationException('The response was lost.');
    }
    return PrototypeDonationOutcome(
      donationId: donationId,
      initiative: initiative,
      amountTaka: amountTaka,
      settlementMethod: settlementMethod,
      paymentReference: 'SIM-DON-BKASH-TEST',
    );
  }
}

void main() {
  test('a successful donation exposes the trusted-server outcome', () async {
    final service = _RecordingDonationService();
    final container = ProviderContainer(
      overrides: [donationServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    await container.read(donationControllerProvider.future);

    await container
        .read(donationControllerProvider.notifier)
        .donate(initiative: GreenInitiative.treePlanting, points: 100);

    final outcome = container.read(donationControllerProvider).value;
    expect(outcome?.points, 100);
    expect(outcome?.balanceAfter, 300);
    expect(service.requestIds.single, startsWith('dn_'));
  });

  test('retrying the same intent reuses its idempotency key', () async {
    final service = _RecordingDonationService()..failNext = true;
    final container = ProviderContainer(
      overrides: [donationServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    await container.read(donationControllerProvider.future);
    final controller = container.read(donationControllerProvider.notifier);

    await controller.donate(
      initiative: GreenInitiative.wasteRecovery,
      points: 50,
    );
    expect(container.read(donationControllerProvider).hasError, isTrue);

    await controller.donate(
      initiative: GreenInitiative.wasteRecovery,
      points: 50,
    );

    expect(service.requestIds, hasLength(2));
    expect(service.requestIds.first, service.requestIds.last);
    expect(container.read(donationControllerProvider).value?.balanceAfter, 350);
  });

  test('editing the amount after a lost response does not mint a second key '
      'for the same intent', () async {
    // The double-debit path. `resetDraft()` used to null the idempotency key,
    // and the screen calls it from six ordinary-interaction callbacks — every
    // keystroke in the amount field, every suggested-amount chip, the
    // initiative radio, the mode switch. So a Champion whose donation failed
    // with the response lost in flight, who then tapped the same 100-point
    // chip and pressed send again, sent a *new* key. The server keys
    // idempotency on `{uid}_{donationId}`, so it committed a second debit for
    // what the user experienced as one retry.
    final service = _RecordingDonationService();
    final container = ProviderContainer(
      overrides: [donationServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    await container.read(donationControllerProvider.future);
    final controller = container.read(donationControllerProvider.notifier);

    service.failNext = true;
    await controller.donate(
      initiative: GreenInitiative.wasteRecovery,
      points: 100,
    );
    expect(container.read(donationControllerProvider).hasError, isTrue);

    // What the screen does on any field or chip interaction.
    controller.resetDraft();

    await controller.donate(
      initiative: GreenInitiative.wasteRecovery,
      points: 100,
    );

    expect(service.requestIds, hasLength(2));
    expect(
      service.requestIds.first,
      service.requestIds.last,
      reason: 'the same intent must retry under the same idempotency key',
    );
  });

  test('a genuinely changed amount still mints a new key', () async {
    final service = _RecordingDonationService();
    final container = ProviderContainer(
      overrides: [donationServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    await container.read(donationControllerProvider.future);
    final controller = container.read(donationControllerProvider.notifier);

    await controller.donate(
      initiative: GreenInitiative.wasteRecovery,
      points: 50,
    );
    controller.resetDraft();
    await controller.donate(
      initiative: GreenInitiative.wasteRecovery,
      points: 75,
    );

    expect(service.requestIds.first, isNot(service.requestIds.last));
  });

  test('a receipt is only clearable once it has been seen', () async {
    final service = _RecordingDonationService();
    final container = ProviderContainer(
      overrides: [donationServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    await container.read(donationControllerProvider.future);
    final controller = container.read(donationControllerProvider.notifier);

    await controller.donate(
      initiative: GreenInitiative.treePlanting,
      points: 50,
    );

    // A donation that landed while the user was away from the screen.
    expect(controller.outcomeWasSeen, isFalse);

    controller.markOutcomeSeen();
    expect(controller.outcomeWasSeen, isTrue);
  });

  test('starting a new donation creates a different request key', () async {
    final service = _RecordingDonationService();
    final container = ProviderContainer(
      overrides: [donationServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    await container.read(donationControllerProvider.future);
    final controller = container.read(donationControllerProvider.notifier);

    await controller.donate(
      initiative: GreenInitiative.wasteRecovery,
      points: 50,
    );
    controller.startNewDonation();
    await controller.donate(
      initiative: GreenInitiative.treePlanting,
      points: 100,
    );

    expect(service.requestIds, hasLength(2));
    expect(service.requestIds.first, isNot(service.requestIds.last));
  });

  test('prototype donation exposes the simulation receipt', () async {
    final service = _RecordingDonationService();
    final container = ProviderContainer(
      overrides: [donationServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    await container.read(prototypeDonationControllerProvider.future);

    await container
        .read(prototypeDonationControllerProvider.notifier)
        .donate(
          initiative: GreenInitiative.treePlanting,
          amountTaka: 500,
          settlementMethod: SettlementMethod.prototypeBkash,
        );

    final outcome = container.read(prototypeDonationControllerProvider).value;
    expect(outcome?.amountTaka, 500);
    expect(outcome?.paymentReference, startsWith('SIM-'));
    expect(service.requestIds.single, startsWith('pdn_'));
  });

  test('prototype retry reuses its idempotency key', () async {
    final service = _RecordingDonationService()..failNextPrototype = true;
    final container = ProviderContainer(
      overrides: [donationServiceProvider.overrideWithValue(service)],
    );
    addTearDown(container.dispose);
    await container.read(prototypeDonationControllerProvider.future);
    final controller = container.read(
      prototypeDonationControllerProvider.notifier,
    );

    await controller.donate(
      initiative: GreenInitiative.wasteRecovery,
      amountTaka: 250,
      settlementMethod: SettlementMethod.prototypeNagad,
    );
    await controller.donate(
      initiative: GreenInitiative.wasteRecovery,
      amountTaka: 250,
      settlementMethod: SettlementMethod.prototypeNagad,
    );

    expect(service.requestIds, hasLength(2));
    expect(service.requestIds.first, service.requestIds.last);
  });
}
