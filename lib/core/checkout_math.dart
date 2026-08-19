/// Chokro — checkout arithmetic (F4.3, F4.4, F4.5).
///
/// Plain Dart, no Firebase imports (§5.1). Mirrored by `server/src/checkout.js`,
/// which is the authority: the figures produced here are what the buyer is shown
/// before they commit, and the server recomputes every one of them from stored
/// prices inside the checkout transaction. A client that lied about a subtotal
/// would be corrected, not obeyed.
///
/// Both copies exist for the same reason `points_policy.dart` and
/// `pointsPolicy.js` do — the buyer needs to see the discount before pressing a
/// button, and the button must not be what decides it. `test/checkout_math_test.dart`
/// and `server/test/checkout.test.js` assert the same worked examples so the two
/// cannot drift silently.
library;

import 'points_policy.dart';

/// One line of a resolved cart: a product, its price *now*, and how many.
///
/// The cart document stores `productId` and `qty` only (§6.2) — never a price.
/// A [CartLine] is what you get after resolving those against the live product
/// documents, and it is short-lived by design: the price on it is a reading, not
/// a promise. Only an order snapshots a price, and only at the moment it is
/// written.
class CartLine {
  const CartLine({
    required this.productId,
    required this.sellerId,
    required this.shopName,
    required this.title,
    required this.unitPrice,
    required this.qty,
    this.imageUrl,
    this.stock,
  });

  final String productId;
  final String sellerId;

  /// The seller's self-declared shop name, denormalised onto the product.
  final String shopName;

  /// Snapshotted onto the order line at checkout, so a later rename does not
  /// rewrite what a buyer purchased (§6.2).
  final String title;

  /// Whole taka.
  final int unitPrice;

  final int qty;
  final String? imageUrl;

  /// Stock as last read. Null when unknown — the quote then cannot judge
  /// availability and says so rather than guessing.
  final int? stock;

  int get lineTotal => unitPrice * qty;

  /// Whether this line can be fulfilled from what the catalogue currently shows.
  /// Advisory: the authoritative check is the stock decrement inside the
  /// server's checkout transaction, which is what makes two buyers racing for
  /// the last unit resolve cleanly (§7.4).
  bool get isAvailable => stock == null || stock! >= qty;

  CartLine copyWith({int? qty}) => CartLine(
    productId: productId,
    sellerId: sellerId,
    shopName: shopName,
    title: title,
    unitPrice: unitPrice,
    qty: qty ?? this.qty,
    imageUrl: imageUrl,
    stock: stock,
  );
}

/// One seller's share of a checkout — which becomes exactly one order (§7.4).
class SellerGroup {
  const SellerGroup({
    required this.sellerId,
    required this.shopName,
    required this.lines,
    required this.subtotal,
    required this.discount,
    required this.pointsApplied,
  });

  final String sellerId;
  final String shopName;
  final List<CartLine> lines;

  /// Sum of this group's line totals, in whole taka.
  final int subtotal;

  /// This group's share of the checkout-wide discount, in whole taka.
  final int discount;

  /// The points that bought [discount]. Sums across groups to the checkout's
  /// total, exactly — see [allocateDiscount].
  final int pointsApplied;

  int get payable => subtotal - discount;
}

/// What the buyer is shown on the checkout screen, and what the server rebuilds.
class CheckoutQuote {
  const CheckoutQuote({
    required this.groups,
    required this.subtotal,
    required this.pointsApplied,
    required this.discount,
    required this.payable,
    required this.maxRedeemablePoints,
  });

  final List<SellerGroup> groups;
  final int subtotal;
  final int pointsApplied;
  final int discount;
  final int payable;

  /// The ceiling this quote clamped against, so the screen can explain *why* a
  /// requested figure was reduced rather than silently changing it.
  final int maxRedeemablePoints;

  bool get isEmpty => groups.isEmpty;

  /// One order per seller (§7.4). Shown before checkout because "this becomes
  /// two orders" is surprising if you first learn it afterwards.
  int get orderCount => groups.length;

  /// Every line across every group, in group order.
  Iterable<CartLine> get lines => groups.expand((group) => group.lines);
}

/// Groups resolved lines by seller, deterministically.
///
/// Ordered by `sellerId` rather than by insertion, because the server allocates
/// the discount across groups in list order and the two copies must produce
/// identical arithmetic. Insertion order depends on how the cart was built,
/// which the server does not observe.
List<List<CartLine>> groupBySeller(List<CartLine> lines) {
  final bySeller = <String, List<CartLine>>{};
  for (final line in lines) {
    bySeller.putIfAbsent(line.sellerId, () => <CartLine>[]).add(line);
  }
  final sellerIds = bySeller.keys.toList()..sort();
  return [for (final id in sellerIds) bySeller[id]!];
}

/// Splits [discount] across [subtotals] proportionally, in whole taka.
///
/// Largest-remainder, not naive rounding. Three ৳100 orders sharing a ৳50
/// discount give exact shares of 16.67 each; flooring hands back 16+16+16 = 48
/// and loses ৳2, which then has to go somewhere or the buyer is charged for
/// points they spent. The two leftover taka go to the two largest fractional
/// remainders, so the parts always sum to the whole.
///
/// Ties break toward the earlier index, which is stable because [groupBySeller]
/// sorts by seller id.
///
/// Returns a list the same length as [subtotals]. Every element is at least zero
/// and never exceeds its own subtotal, provided `discount <= sum(subtotals)` —
/// which the redemption ceiling guarantees, since it caps the discount at a
/// percentage of the subtotal.
List<int> allocateDiscount(List<int> subtotals, int discount) {
  final total = subtotals.fold<int>(0, (sum, value) => sum + value);
  if (subtotals.isEmpty || discount <= 0 || total <= 0) {
    return List<int>.filled(subtotals.length, 0);
  }
  if (discount >= total) return List<int>.of(subtotals);

  final shares = <int>[];
  // Remainder as a scaled integer: `subtotal * discount % total`. Kept in
  // integers rather than doubles so the comparison is exact — a floating-point
  // remainder can tie in a way that depends on the platform's rounding.
  final remainders = <int>[];

  for (final subtotal in subtotals) {
    final product = subtotal * discount;
    shares.add(product ~/ total);
    remainders.add(product % total);
  }

  var allocated = shares.fold<int>(0, (sum, value) => sum + value);
  var leftover = discount - allocated;

  // Indices ordered by descending remainder, then ascending index.
  final order = List<int>.generate(subtotals.length, (i) => i)
    ..sort((a, b) {
      final byRemainder = remainders[b].compareTo(remainders[a]);
      return byRemainder != 0 ? byRemainder : a.compareTo(b);
    });

  var cursor = 0;
  while (leftover > 0 && cursor < order.length) {
    final index = order[cursor];
    // Never push a group's discount past its own subtotal; a group already at
    // its ceiling is skipped and the taka moves to the next.
    if (shares[index] < subtotals[index]) {
      shares[index] += 1;
      leftover -= 1;
    }
    cursor += 1;
    // A full pass that placed nothing would loop forever; restarting is safe
    // because `discount < total` guarantees somewhere has headroom.
    if (cursor == order.length && leftover > 0) cursor = 0;
  }

  return shares;
}

/// Builds the quote the checkout screen shows and the server re-derives.
///
/// [pointsRequested] is clamped to what the policy and the wallet allow rather
/// than rejected, matching [PointsPolicy.applyRedemption]: the slider should
/// prevent an over-request, and the arithmetic must be safe if it does not.
/// [CheckoutQuote.maxRedeemablePoints] carries the ceiling so the screen can say
/// what happened.
CheckoutQuote quoteCheckout({
  required List<CartLine> lines,
  required PointsPolicy policy,
  required int balance,
  int pointsRequested = 0,
}) {
  final grouped = groupBySeller(lines);
  final subtotals = [
    for (final group in grouped)
      group.fold<int>(0, (sum, line) => sum + line.lineTotal),
  ];
  final subtotal = subtotals.fold<int>(0, (sum, value) => sum + value);

  final outcome = policy.applyRedemption(
    subtotal: subtotal,
    balance: balance,
    pointsRequested: pointsRequested,
  );

  final discounts = allocateDiscount(subtotals, outcome.discount);

  final groups = <SellerGroup>[];
  for (var i = 0; i < grouped.length; i++) {
    groups.add(
      SellerGroup(
        sellerId: grouped[i].first.sellerId,
        shopName: grouped[i].first.shopName,
        lines: grouped[i],
        subtotal: subtotals[i],
        discount: discounts[i],
        // Derived from this group's taka, not apportioned separately, so the
        // per-order points always buy exactly the per-order discount.
        pointsApplied: policy.pointsToSpendForTaka(discounts[i]),
      ),
    );
  }

  return CheckoutQuote(
    groups: groups,
    subtotal: subtotal,
    pointsApplied: outcome.pointsApplied,
    discount: outcome.discount,
    payable: outcome.payable,
    maxRedeemablePoints: policy.maxRedeemablePoints(
      subtotal: subtotal,
      balance: balance,
    ),
  );
}
