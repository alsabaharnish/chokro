/// Payment vocabulary shared by marketplace orders and prototype donations.
///
/// The online values are demonstrations only. They intentionally carry no
/// account number, card number, PIN, OTP, token, or processor payload. A real
/// integration must replace the simulation with a provider-verified callback
/// before anything is marked paid.
library;

enum SettlementMethod {
  cashOnDelivery,
  prototypeBkash,
  prototypeNagad,
  prototypeCard;

  static SettlementMethod fromName(String? name) {
    for (final method in SettlementMethod.values) {
      if (method.name == name) return method;
    }
    return SettlementMethod.cashOnDelivery;
  }

  bool get isPrototype => this != SettlementMethod.cashOnDelivery;

  String get label => switch (this) {
    SettlementMethod.cashOnDelivery => 'Cash on delivery',
    SettlementMethod.prototypeBkash => 'bKash (prototype)',
    SettlementMethod.prototypeNagad => 'Nagad (prototype)',
    SettlementMethod.prototypeCard => 'Card (prototype)',
  };

  String get shortLabel => switch (this) {
    SettlementMethod.cashOnDelivery => 'Cash on delivery',
    SettlementMethod.prototypeBkash => 'bKash',
    SettlementMethod.prototypeNagad => 'Nagad',
    SettlementMethod.prototypeCard => 'Card',
  };
}

/// Whether the taka side of a transaction is settled.
enum PaymentStatus {
  pending,
  paid;

  static PaymentStatus fromName(String? name) {
    for (final status in PaymentStatus.values) {
      if (status.name == name) return status;
    }
    return PaymentStatus.pending;
  }

  String get label => this == PaymentStatus.paid ? 'Paid' : 'Payment due';
}
