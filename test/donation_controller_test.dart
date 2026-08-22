import 'package:chokro/controllers/donation_controller.dart';
import 'package:chokro/models/donation_model.dart';
import 'package:chokro/services/donation_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingDonationService extends DonationService {
  final requestIds = <String>[];
  bool failNext = false;

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

  test('changing the draft creates a different request key', () async {
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
      initiative: GreenInitiative.treePlanting,
      points: 100,
    );

    expect(service.requestIds, hasLength(2));
    expect(service.requestIds.first, isNot(service.requestIds.last));
  });
}
