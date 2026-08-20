/// Chokro — the shopping cart (F4.3).
///
/// Plain Dart, no Firebase imports (§5.1).
///
/// ## The cart stores no prices (§6.2)
///
/// An item is a `productId` and a `qty`, and nothing else. This is the invariant
/// that stops a cart from becoming a quotation: if a price were cached here, a
/// buyer could add an item, wait for the seller to raise the price, and check
/// out at yesterday's figure — or the reverse, and be charged more than the
/// screen showed. Price is resolved from the product document at checkout, by
/// the server, every time.
///
/// Firestore rules validate every bounded item and the server validates again at
/// checkout. The second check protects against legacy or imported data because
/// trusted server code bypasses client security rules.
library;

/// One line the buyer intends to purchase.
class CartItem {
  const CartItem({required this.productId, required this.qty});

  final String productId;
  final int qty;

  /// Quantity ceiling per line. Bounded so a single line cannot be used to force
  /// an arithmetic overflow at checkout, and because nobody in this marketplace
  /// is ordering ninety-nine of anything.
  static const int maxQty = 20;

  /// Cart size ceiling, mirrored in `firestore.rules`.
  static const int maxItems = 20;

  CartItem copyWith({int? qty}) =>
      CartItem(productId: productId, qty: qty ?? this.qty);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'productId': productId,
    'qty': qty,
  };

  /// Returns null for an entry that is not a usable line, rather than a line
  /// with defaults. A cart with junk in it should lose the junk, not gain a
  /// phantom item with quantity zero.
  static CartItem? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final productId = raw['productId'];
    final qty = raw['qty'];
    if (productId is! String || productId.isEmpty) return null;
    final count = qty is int
        ? qty
        : qty is num && qty.isFinite && qty == qty.truncateToDouble()
        ? qty.toInt()
        : null;
    if (count == null || count < 1 || count > maxQty) return null;
    return CartItem(productId: productId, qty: count);
  }
}

/// A user's cart. One document, id `carts/{userId}`.
class CartModel {
  const CartModel({
    required this.userId,
    this.items = const <CartItem>[],
    this.updatedAt,
  });

  final String userId;
  final List<CartItem> items;
  final DateTime? updatedAt;

  bool get isEmpty => items.isEmpty;

  /// Total units, which is what the navigation badge shows. Not a taka figure —
  /// the cart cannot compute one, by design.
  int get unitCount => items.fold<int>(0, (sum, item) => sum + item.qty);

  int qtyOf(String productId) {
    for (final item in items) {
      if (item.productId == productId) return item.qty;
    }
    return 0;
  }

  /// Adds [qty] of [productId], merging with an existing line.
  ///
  /// Pure: returns a new cart rather than mutating, so the controller can write
  /// the result and the arithmetic can be tested without Firestore. Quantities
  /// clamp at [CartItem.maxQty] rather than throwing — a buyer tapping "add"
  /// repeatedly should stop climbing, not see an error.
  CartModel withItem(String productId, {int qty = 1}) {
    if (qty <= 0) return withoutItem(productId);

    final next = <CartItem>[];
    var found = false;

    for (final item in items) {
      if (item.productId == productId) {
        found = true;
        final merged = item.qty + qty;
        next.add(
          item.copyWith(
            qty: merged > CartItem.maxQty ? CartItem.maxQty : merged,
          ),
        );
      } else {
        next.add(item);
      }
    }

    if (!found) {
      if (items.length >= CartItem.maxItems) return this;
      next.add(
        CartItem(
          productId: productId,
          qty: qty > CartItem.maxQty ? CartItem.maxQty : qty,
        ),
      );
    }

    return CartModel(userId: userId, items: next, updatedAt: updatedAt);
  }

  /// Sets a line to exactly [qty]. Zero or less removes the line.
  CartModel withQuantity(String productId, int qty) {
    if (qty <= 0) return withoutItem(productId);
    final capped = qty > CartItem.maxQty ? CartItem.maxQty : qty;

    final next = [
      for (final item in items)
        item.productId == productId ? item.copyWith(qty: capped) : item,
    ];
    if (!next.any((item) => item.productId == productId)) {
      return withItem(productId, qty: capped);
    }
    return CartModel(userId: userId, items: next, updatedAt: updatedAt);
  }

  CartModel withoutItem(String productId) => CartModel(
    userId: userId,
    items: items.where((item) => item.productId != productId).toList(),
    updatedAt: updatedAt,
  );

  CartModel cleared() => CartModel(userId: userId, updatedAt: updatedAt);

  factory CartModel.fromMap(
    Map<String, dynamic>? raw, {
    required String userId,
  }) {
    final data = raw ?? const <String, dynamic>{};
    final rawItems = data['items'];

    final items = <CartItem>[];
    if (rawItems is List) {
      for (final entry in rawItems) {
        final item = CartItem.fromMap(entry);
        if (item != null) items.add(item);
        if (items.length >= CartItem.maxItems) break;
      }
    }

    return CartModel(
      userId: userId,
      items: items,
      updatedAt: _date(data['updatedAt']),
    );
  }

  /// The write payload. `updatedAt` is supplied by the service as a server
  /// timestamp, which the rules require.
  Map<String, dynamic> toJson() => <String, dynamic>{
    'userId': userId,
    'items': [for (final item in items) item.toJson()],
  };
}

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  if (value is String) return DateTime.tryParse(value);
  if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
  return null;
}
