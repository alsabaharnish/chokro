import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/checkout_math.dart';
import '../models/cart_model.dart';
import '../models/product_model.dart';
import '../services/cart_service.dart';
import 'catalog_controller.dart';
import 'current_user_provider.dart';
import 'ledger_controller.dart';
import 'points_policy_controller.dart';
import 'wallet_controller.dart';

final cartServiceProvider = Provider<CartService>((ref) => CartService());

/// The signed-in user's cart (F4.3).
///
/// Not `autoDispose`: the badge in the navigation shows the item count on every
/// screen, so this listener is wanted for the whole session. Emits an empty cart
/// rather than an error when signed out, so signing out mid-session tears down
/// cleanly.
final cartProvider = StreamProvider<CartModel>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) {
    return Stream<CartModel>.value(const CartModel(userId: ''));
  }
  return ref.watch(cartServiceProvider).watchCart(uid);
});

/// Total units in the cart, for the navigation badge.
final cartCountProvider = Provider<int>((ref) {
  return ref.watch(cartProvider).asData?.value.unitCount ?? 0;
});

/// The cart's products, resolved against live listings.
///
/// This is where a cart stops being ids and becomes prices — and it is a *read*,
/// not a quotation. Nothing here is sent to the server at checkout; the server
/// resolves the same ids itself, inside the transaction, and its figures are the
/// ones that charge the buyer.
final cartProductsProvider = StreamProvider.autoDispose<List<ProductModel>>((
  ref,
) {
  final cart = ref.watch(cartProvider).asData?.value;
  final ids = cart?.items.map((item) => item.productId).toList() ?? const [];
  if (ids.isEmpty) {
    return Stream<List<ProductModel>>.value(const <ProductModel>[]);
  }
  return ref.watch(productServiceProvider).watchProductsByIds(ids);
});

/// The cart's lines, in the order the buyer added them.
///
/// A product that has been delisted or removed since it was added is **dropped
/// from the lines and reported separately** by [unavailableCartItemsProvider],
/// rather than shown at a stale price. Checkout would refuse it anyway; saying
/// so on the cart screen is what turns a mystifying failure into something the
/// buyer can fix.
final cartLinesProvider = Provider.autoDispose<List<CartLine>>((ref) {
  final cart = ref.watch(cartProvider).asData?.value;
  final products = ref.watch(cartProductsProvider).asData?.value;
  if (cart == null || products == null) return const <CartLine>[];

  final byId = {for (final product in products) product.id: product};

  final lines = <CartLine>[];
  for (final item in cart.items) {
    final product = byId[item.productId];
    if (product == null || !product.active) {
      continue;
    }
    lines.add(
      CartLine(
        productId: item.productId,
        sellerId: product.sellerId,
        shopName: product.shopName,
        title: product.title,
        unitPrice: product.price,
        qty: item.qty,
        imageUrl: product.primaryImageUrl,
        stock: product.stock,
      ),
    );
  }
  return lines;
});

/// Cart entries that can no longer be bought, with the reason.
///
/// Two distinct cases and they read differently to a buyer: a listing the seller
/// withdrew, and one that is temporarily out of stock.
final unavailableCartItemsProvider =
    Provider.autoDispose<List<UnavailableCartItem>>((ref) {
      final cart = ref.watch(cartProvider).asData?.value;
      final products = ref.watch(cartProductsProvider).asData?.value;
      if (cart == null || products == null) {
        return const <UnavailableCartItem>[];
      }

      final byId = {for (final product in products) product.id: product};

      final problems = <UnavailableCartItem>[];
      for (final item in cart.items) {
        final product = byId[item.productId];
        if (product == null) {
          problems.add(
            UnavailableCartItem(
              productId: item.productId,
              title: 'A removed product',
              reason: 'This listing is no longer available.',
            ),
          );
        } else if (!product.active) {
          problems.add(
            UnavailableCartItem(
              productId: item.productId,
              title: product.title,
              reason: 'The Greenpreneur has withdrawn this listing.',
            ),
          );
        } else if (product.stock < item.qty) {
          problems.add(
            UnavailableCartItem(
              productId: item.productId,
              title: product.title,
              reason: product.stock == 0
                  ? 'Out of stock.'
                  : 'Only ${product.stock} left — reduce the quantity.',
            ),
          );
        }
      }
      return problems;
    });

class UnavailableCartItem {
  const UnavailableCartItem({
    required this.productId,
    required this.title,
    required this.reason,
  });

  final String productId;
  final String title;
  final String reason;
}

/// How many points the buyer has asked to spend on this checkout.
///
/// Held here rather than in the checkout screen's own state so that changing it
/// re-derives the quote through the same provider graph the totals come from —
/// one source for the figure the buyer sees.
class CheckoutPointsController extends Notifier<int> {
  @override
  int build() => 0;

  void set(int points) => state = points < 0 ? 0 : points;

  void none() => state = 0;

  /// Spend as much as the policy and the balance allow.
  void max(int cap) => state = cap;
}

final checkoutPointsProvider = NotifierProvider<CheckoutPointsController, int>(
  CheckoutPointsController.new,
);

/// The cart's subtotal, independent of the wallet.
///
/// Separate from the quote because the cart screen must keep showing a total
/// when the balance is unavailable: a wallet read failing is no reason to stop
/// telling a buyer what their basket costs.
final cartSubtotalProvider = Provider.autoDispose<int>((ref) {
  return ref
      .watch(cartLinesProvider)
      .fold<int>(0, (sum, line) => sum + line.lineTotal);
});

/// The buyer's spendable balance, with loading and error kept distinct.
///
/// `asData?.value` returns null on error exactly as it does while loading, so
/// the previous `?? 0` chain turned a failed wallet read into **a confident zero
/// balance** — the points slider capped at nothing, no error shown, and a buyer
/// told they had nothing to spend when they might have had hundreds.
///
/// The ledger's `balanceAfter` is preferred because NFR-4 makes the balance
/// reconstructable from history, and showing the figure that comes out of the
/// history is that property made visible. The wallet document is the fallback
/// for an account with no ledger entries yet.
final spendableBalanceProvider = Provider.autoDispose<AsyncValue<int>>((ref) {
  final wallet = ref.watch(walletProvider);
  final fromLedger = ref.watch(ledgerBalanceProvider);

  return wallet.when(
    data: (value) => AsyncValue.data(fromLedger ?? value?.balance ?? 0),
    loading: () => const AsyncValue.loading(),
    error: AsyncValue.error,
  );
});

/// The buyer's current total, as they see it before committing.
///
/// **Display only.** `server/src/checkout.js` recomputes every figure here from
/// stored prices inside the transaction, and its answer is the one that charges
/// them. This exists so the buyer is not asked to commit to an unknown number.
///
/// Null while the policy or the wallet is still loading — a quote drawn on a
/// half-loaded policy would be a wrong number shown confidently.
final checkoutQuoteProvider = Provider.autoDispose<CheckoutQuote?>((ref) {
  final policy = ref.watch(pointsPolicyProvider).asData?.value;
  if (policy == null) return null;

  final lines = ref.watch(cartLinesProvider);

  // Null while the balance is loading or in error, so this yields no quote at
  // all rather than one drawn on an assumed zero. The checkout screen branches
  // on `spendableBalanceProvider` and says which of the two it is.
  final balance = ref.watch(spendableBalanceProvider).asData?.value;
  if (balance == null) return null;

  return quoteCheckout(
    lines: lines,
    policy: policy,
    balance: balance,
    pointsRequested: ref.watch(checkoutPointsProvider),
  );
});

/// Cart mutations.
///
/// Every one is a read-modify-write of the whole document, which is what the
/// rules expect — they pin an exact top-level key set, so a partial update would
/// be refused. The cart is small and single-owner, so a lost update is a buyer
/// racing themselves across two devices, not a correctness problem worth a
/// transaction.
class CartActions {
  CartActions(this._ref);

  final Ref _ref;

  /// The current cart, or a thrown explanation of why there isn't one.
  ///
  /// Every mutation used to begin `if (cart == null) return;` — no exception, no
  /// state change, no feedback. The button appeared to work and did nothing,
  /// which is the worst of the three possible behaviours: a buyer taps "Add to
  /// cart", sees no error, and finds an empty cart at checkout.
  ///
  /// The causes are genuinely different and read differently to a user: the
  /// stream has not resolved yet, it failed, or nobody is signed in.
  CartModel _requireCart() {
    final async = _ref.read(cartProvider);

    if (async.hasError) {
      throw const CartUnavailableException(
        'Your cart could not be loaded. Check your connection and try again.',
      );
    }

    final cart = async.asData?.value;
    if (cart == null) {
      throw const CartUnavailableException(
        'Your cart is still loading. Try again in a moment.',
      );
    }
    if (cart.userId.isEmpty) {
      throw const CartUnavailableException('Sign in to use a cart.');
    }
    return cart;
  }

  Future<void> add(String productId, {int qty = 1}) async {
    final cart = _requireCart();
    await _ref
        .read(cartServiceProvider)
        .save(cart.withItem(productId, qty: qty));
  }

  Future<void> setQuantity(String productId, int qty) async {
    final cart = _requireCart();
    await _ref
        .read(cartServiceProvider)
        .save(cart.withQuantity(productId, qty));
  }

  Future<void> remove(String productId) async {
    final cart = _requireCart();
    await _ref.read(cartServiceProvider).save(cart.withoutItem(productId));
  }

  Future<void> clear() async {
    final uid = _ref.read(currentUidProvider);
    if (uid == null) {
      throw const CartUnavailableException('Sign in to use a cart.');
    }
    await _ref.read(cartServiceProvider).clear(uid);
  }

  /// Called after a successful checkout.
  ///
  /// The server has already deleted the cart document inside the transaction —
  /// this only resets the points slider, so the next checkout does not open
  /// pre-loaded with the figure from the last one.
  void resetAfterCheckout() =>
      _ref.read(checkoutPointsProvider.notifier).none();
}

final cartActionsProvider = Provider<CartActions>((ref) => CartActions(ref));

/// A cart operation that could not run, with a sentence fit to show a buyer.
class CartUnavailableException implements Exception {
  const CartUnavailableException(this.message);

  final String message;

  @override
  String toString() => message;
}
