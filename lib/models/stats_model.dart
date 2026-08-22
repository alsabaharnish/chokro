/// Chokro — the admin dashboard's counters (F5.1).
///
/// Plain Dart, no Firebase imports (§5.1).
///
/// ## Why counters and not queries
///
/// §6.3 is explicit: maintain a `stats` document incremented with
/// `FieldValue.increment()` inside the same transactions that create
/// submissions and awards, rather than reading whole collections. A dashboard
/// that counted by fetching every disposal would cost a read per document per
/// page load, and would get slower exactly as the demonstration data grew.
///
/// The counters are therefore written by the trusted service, inside the
/// transactions that cause them, and read here. That has one honest consequence:
/// a counter is a record of what the server did, not a recount of the
/// collection. If a document were ever written outside a counting path the two
/// would disagree — which is why every write that should count goes through
/// `award.js`, `checkout.js` or `orders.js` and nowhere else.
///
/// Two figures on the dashboard are *not* counters: the user and product totals
/// come from collections an administrator can already read, are small, and are
/// bounded by the size of the demonstration. Those are counted live and stated
/// as such.
library;

/// The `stats/platform` document.
///
/// Every field defaults to zero: the document does not exist until the first
/// transaction increments something, and a dashboard on a fresh database should
/// read zeros rather than fail.
class PlatformStats {
  const PlatformStats({
    this.disposalsApproved = 0,
    this.disposalsRejected = 0,
    this.claimsApproved = 0,
    this.claimsRejected = 0,
    this.pointsIssued = 0,
    this.pointsRedeemed = 0,
    this.pointsDonated = 0,
    this.donationsReceived = 0,
    this.ordersCreated = 0,
    this.ordersConfirmed = 0,
    this.salesPayable = 0,
  });

  /// Disposals credited, by either lane (F2.12).
  final int disposalsApproved;
  final int disposalsRejected;

  final int claimsApproved;
  final int claimsRejected;

  /// Every point ever credited, from any source. The gross of the economy.
  final int pointsIssued;

  /// Every point ever spent at checkout (`source=redemption`).
  final int pointsRedeemed;

  /// Champion contributions removed from spendable wallets, plus receipt count.
  final int pointsDonated;
  final int donationsReceived;

  final int ordersCreated;
  final int ordersConfirmed;

  /// Cash value of orders placed, in whole taka, after points were applied.
  final int salesPayable;

  static const PlatformStats empty = PlatformStats();

  /// Points still held in wallets across the platform, as the ledger sees it.
  ///
  /// A derived figure, not a stored one, and it is the number worth looking at:
  /// issued minus checkout redemptions and donations is the outstanding
  /// liability of the points economy.
  int get pointsOutstanding {
    final outstanding = pointsIssued - pointsRedeemed - pointsDonated;
    return outstanding < 0 ? 0 : outstanding;
  }

  int get disposalsDecided => disposalsApproved + disposalsRejected;
  int get claimsDecided => claimsApproved + claimsRejected;

  /// Approval rate as a whole percentage, or null when nothing has been decided
  /// — which is different from zero percent and must not be shown as it.
  int? get disposalApprovalPercent => disposalsDecided == 0
      ? null
      : (disposalsApproved * 100) ~/ disposalsDecided;

  int? get claimApprovalPercent =>
      claimsDecided == 0 ? null : (claimsApproved * 100) ~/ claimsDecided;

  /// Orders placed but not yet confirmed by their buyer.
  int get ordersOpen {
    final open = ordersCreated - ordersConfirmed;
    return open < 0 ? 0 : open;
  }

  factory PlatformStats.fromMap(Map<String, dynamic>? raw) {
    final data = raw ?? const <String, dynamic>{};

    int read(String key) {
      final value = data[key];
      if (value is int) return value;
      if (value is num && value.isFinite && value == value.truncateToDouble()) {
        return value.toInt();
      }
      return 0;
    }

    return PlatformStats(
      disposalsApproved: read('disposalsApproved'),
      disposalsRejected: read('disposalsRejected'),
      claimsApproved: read('claimsApproved'),
      claimsRejected: read('claimsRejected'),
      pointsIssued: read('pointsIssued'),
      pointsRedeemed: read('pointsRedeemed'),
      pointsDonated: read('pointsDonated'),
      donationsReceived: read('donationsReceived'),
      ordersCreated: read('ordersCreated'),
      ordersConfirmed: read('ordersConfirmed'),
      salesPayable: read('salesPayable'),
    );
  }
}
