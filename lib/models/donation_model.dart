import 'payment_model.dart';

enum GreenInitiative { wasteRecovery, treePlanting, greenEntrepreneurship }

extension GreenInitiativeDisplay on GreenInitiative {
  String get label => switch (this) {
    GreenInitiative.wasteRecovery => 'Waste recovery',
    GreenInitiative.treePlanting => 'Tree planting',
    GreenInitiative.greenEntrepreneurship => 'Green entrepreneurship',
  };

  String get description => switch (this) {
    GreenInitiative.wasteRecovery =>
      'Help communities collect, sort and recover more waste.',
    GreenInitiative.treePlanting =>
      'Support locally cared-for trees and restored green spaces.',
    GreenInitiative.greenEntrepreneurship =>
      'Help new Greenpreneurs turn sustainable ideas into livelihoods.',
  };

  String get wireValue => name;
}

class DonationOutcome {
  const DonationOutcome({
    required this.donationId,
    required this.initiative,
    required this.points,
    required this.balanceAfter,
  });

  final String donationId;
  final GreenInitiative initiative;
  final int points;
  final int balanceAfter;
}

/// Receipt for a simulation-only online donation.
class PrototypeDonationOutcome {
  const PrototypeDonationOutcome({
    required this.donationId,
    required this.initiative,
    required this.amountTaka,
    required this.settlementMethod,
    required this.paymentReference,
  });

  final String donationId;
  final GreenInitiative initiative;
  final int amountTaka;
  final SettlementMethod settlementMethod;
  final String paymentReference;
}
