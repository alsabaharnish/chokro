/// Chokro — orders, and the status machine that releases purchase points
/// (F4.4, F4.6, F4.7, F4.8).
///
/// Plain Dart, no Firebase imports (§5.1). Every field here is written by the
/// trusted service; there is no client write path to an order at all, so this
/// model carries no `toCreateJson`. What the client sends is a *request* to
/// check out or to advance a status, and the server decides what that becomes.
///
/// ## Why orders are entirely server-owned
///
/// §6.3 assigns the transitions by party — the seller ships and delivers, the
/// buyer confirms — and rules could express that much. They cannot express the
/// part that matters: `confirmed` is the transition that credits a wallet
/// (F4.7), and a rule permitting the buyer to set it would be a rule permitting
/// a client to trigger a payout. Splitting the machine so that two transitions
/// were rules-enforced and one was server-enforced would put the same invariant
/// in two places with different reasoning behind each. Every transition
/// therefore goes to the server, which checks the party, the order of states and
/// the idempotence in one function — and rules deny the whole collection to
/// every client, administrators included, exactly as they do for `disposals`.
library;

/// Where an order is in its life. Ordered, and the order is enforced.
///
/// A seller cannot skip to `delivered` without shipping, cannot confirm their
/// own delivery, and cannot move an order that a buyer has already confirmed.
enum OrderStatus {
  /// Created by checkout. Stock is already decremented and points already
  /// debited — an order exists because a buyer committed, not because a seller
  /// accepted.
  pending,

  /// The seller has dispatched it.
  shipped,

  /// The seller says it arrived. Cash is collected on delivery (F4.8), so this
  /// is also where payment is recorded.
  delivered,

  /// The **buyer** says it arrived. The only transition that credits points.
  confirmed;

  /// Falls back to [pending] for anything unrecognised — the same fail-toward-
  /// no-payout rule as `DisposalStatus` and `ClaimStatus`. An unreadable status
  /// must never resolve to `confirmed`, which is the one that pays.
  static OrderStatus fromName(String? name) {
    for (final status in OrderStatus.values) {
      if (status.name == name) return status;
    }
    return OrderStatus.pending;
  }

  bool get isConfirmed => this == OrderStatus.confirmed;

  /// Nothing more will happen to this order.
  bool get isTerminal => this == OrderStatus.confirmed;

  String get label {
    switch (this) {
      case OrderStatus.pending:
        return 'Placed';
      case OrderStatus.shipped:
        return 'Shipped';
      case OrderStatus.delivered:
        return 'Delivered';
      case OrderStatus.confirmed:
        return 'Confirmed';
    }
  }

  /// What the buyer should understand is happening now.
  String get buyerDescription {
    switch (this) {
      case OrderStatus.pending:
        return 'The seller has your order and is preparing it.';
      case OrderStatus.shipped:
        return 'On its way to you.';
      case OrderStatus.delivered:
        return 'The seller has marked this delivered. Confirm to close it and '
            'collect your points.';
      case OrderStatus.confirmed:
        return 'You confirmed this order. Points have been credited.';
    }
  }

  /// The next status this party may set, or null if there is nothing for them
  /// to do.
  ///
  /// This is the single source of truth for the machine, mirrored by
  /// `nextStatusFor` in `server/src/orders.js`. The server's copy is the one
  /// that enforces; this one exists so a button that would be refused is never
  /// shown.
  static OrderStatus? nextFor(OrderStatus current, {required bool isSeller}) {
    if (isSeller) {
      switch (current) {
        case OrderStatus.pending:
          return OrderStatus.shipped;
        case OrderStatus.shipped:
          return OrderStatus.delivered;
        case OrderStatus.delivered:
        case OrderStatus.confirmed:
          // A seller cannot confirm their own delivery (§6.3). This returning
          // null is that rule, stated where the button is drawn.
          return null;
      }
    }
    return current == OrderStatus.delivered ? OrderStatus.confirmed : null;
  }
}

/// How the order is settled (F4.8).
///
/// One value today, and the field exists anyway. §6.2 forbids storing card data
/// in any schema, so the alternatives are cash or nothing; recording *which*
/// keeps the receipt honest and leaves somewhere for a second method to go
/// without a migration.
enum SettlementMethod {
  cashOnDelivery;

  static SettlementMethod fromName(String? name) {
    for (final method in SettlementMethod.values) {
      if (method.name == name) return method;
    }
    return SettlementMethod.cashOnDelivery;
  }

  String get label => 'Cash on delivery';
}

/// Whether the money has changed hands (F4.8). Points are settled separately and
/// immediately at checkout; this tracks the taka only.
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

/// One line of an order, with the title and unit price **snapshotted** at
/// purchase time (§6.2).
///
/// A later price change or rename must not rewrite what somebody bought. The
/// `productId` is kept as well, so a receipt can still link to the listing —
/// which is also why F4.1's delete deactivates rather than removes.
class OrderLine {
  const OrderLine({
    required this.productId,
    required this.title,
    required this.unitPrice,
    required this.qty,
  });

  final String productId;
  final String title;
  final int unitPrice;
  final int qty;

  int get lineTotal => unitPrice * qty;

  factory OrderLine.fromMap(Map<String, dynamic>? raw) {
    final data = raw ?? const <String, dynamic>{};
    return OrderLine(
      productId: _string(data['productId']),
      title: _string(data['title'], fallback: 'Removed item'),
      unitPrice: _int(data['unitPrice']),
      qty: _int(data['qty']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'productId': productId,
    'title': title,
    'unitPrice': unitPrice,
    'qty': qty,
  };
}

/// One seller's order, produced by splitting a checkout (§7.4).
class OrderModel {
  const OrderModel({
    required this.id,
    required this.buyerId,
    required this.buyerName,
    required this.sellerId,
    required this.sellerName,
    required this.shopName,
    required this.checkoutId,
    required this.items,
    required this.subtotal,
    required this.pointsApplied,
    required this.discount,
    required this.payable,
    required this.settlementMethod,
    required this.paymentStatus,
    required this.status,
    this.pointsAwarded,
    this.createdAt,
    this.shippedAt,
    this.deliveredAt,
    this.confirmedAt,
  });

  final String id;

  final String buyerId;

  /// Resolved by the server from `users`, not supplied by either party. A buyer
  /// and a seller are counterparties in a cash transaction, so each is entitled
  /// to know the other's name — and neither is entitled to invent it.
  final String buyerName;

  final String sellerId;
  final String sellerName;

  /// The seller's self-declared shop name, snapshotted from the products.
  final String shopName;

  /// Shared by every order from one checkout, so a buyer who bought from three
  /// sellers can see the three orders as one purchase (§7.4).
  final String checkoutId;

  final List<OrderLine> items;

  /// Whole taka, before points.
  final int subtotal;

  /// This order's share of the checkout's redeemed points.
  final int pointsApplied;

  /// The taka [pointsApplied] bought.
  final int discount;

  /// What the buyer pays in cash. `subtotal - discount`.
  final int payable;

  final SettlementMethod settlementMethod;
  final PaymentStatus paymentStatus;
  final OrderStatus status;

  /// Purchase points credited on confirmation, snapshotted at that moment
  /// (§6.2). Null until confirmed.
  final int? pointsAwarded;

  final DateTime? createdAt;
  final DateTime? shippedAt;
  final DateTime? deliveredAt;
  final DateTime? confirmedAt;

  int get itemCount => items.fold<int>(0, (sum, line) => sum + line.qty);

  /// Whether [uid] may advance this order, and to what.
  OrderStatus? nextStatusFor(String uid) {
    if (uid == sellerId) {
      return OrderStatus.nextFor(status, isSeller: true);
    }
    if (uid == buyerId) {
      return OrderStatus.nextFor(status, isSeller: false);
    }
    return null;
  }

  factory OrderModel.fromMap(Map<String, dynamic>? raw, {required String id}) {
    final data = raw ?? const <String, dynamic>{};
    final rawItems = data['items'];

    return OrderModel(
      id: id,
      buyerId: _string(data['buyerId']),
      buyerName: _string(data['buyerName'], fallback: 'A buyer'),
      sellerId: _string(data['sellerId']),
      sellerName: _string(data['sellerName'], fallback: 'A seller'),
      shopName: _string(data['shopName']),
      checkoutId: _string(data['checkoutId']),
      items: rawItems is List
          ? rawItems
                .map(
                  (item) => OrderLine.fromMap(
                    item is Map<String, dynamic> ? item : null,
                  ),
                )
                .toList()
          : const <OrderLine>[],
      subtotal: _int(data['subtotal']),
      pointsApplied: _int(data['pointsApplied']),
      discount: _int(data['discount']),
      payable: _int(data['payable']),
      settlementMethod: SettlementMethod.fromName(
        data['settlementMethod'] as String?,
      ),
      paymentStatus: PaymentStatus.fromName(data['paymentStatus'] as String?),
      status: OrderStatus.fromName(data['status'] as String?),
      pointsAwarded: data['pointsAwarded'] is num
          ? (data['pointsAwarded'] as num).toInt()
          : null,
      createdAt: _date(data['createdAt']),
      shippedAt: _date(data['shippedAt']),
      deliveredAt: _date(data['deliveredAt']),
      confirmedAt: _date(data['confirmedAt']),
    );
  }

  @override
  String toString() =>
      'OrderModel($id, ${status.name}, payable $payable, ${items.length} lines)';
}

String _string(Object? value, {String fallback = ''}) =>
    value is String && value.isNotEmpty ? value : fallback;

int _int(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? fallback;
  return fallback;
}

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
