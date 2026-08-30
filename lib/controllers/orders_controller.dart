import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/order_model.dart';
import '../services/order_service.dart';
import 'cart_controller.dart';
import 'current_user_provider.dart';
import 'ledger_controller.dart';
import 'wallet_controller.dart';

final orderServiceProvider = Provider<OrderService>((ref) => OrderService());

/// Orders the signed-in user has placed (F4.6, F4.7).
class BuyerOrderLimitController extends Notifier<int> {
  @override
  int build() => QueryLimits.orders;

  void loadOlder() => state += QueryLimits.orders;
}

final buyerOrderLimitProvider =
    NotifierProvider.autoDispose<BuyerOrderLimitController, int>(
      BuyerOrderLimitController.new,
    );

final buyerOrdersProvider = StreamProvider.autoDispose<BuyerOrderPage>((ref) {
  final uid = ref.watch(currentUidProvider);
  final limit = ref.watch(buyerOrderLimitProvider);
  if (uid == null) {
    return Stream<BuyerOrderPage>.value(
      const BuyerOrderPage(orders: <OrderModel>[], truncated: false),
    );
  }
  return ref.watch(orderServiceProvider).watchBuyerOrders(uid, limit: limit);
});

class SellerOrderLimitController extends Notifier<int> {
  @override
  int build() => QueryLimits.orders;

  void loadOlder() => state += QueryLimits.orders;
}

final sellerOrderLimitProvider =
    NotifierProvider.autoDispose<SellerOrderLimitController, int>(
      SellerOrderLimitController.new,
    );

/// A bounded page of orders the signed-in seller has to fulfil (F4.6).
final sellerOrdersProvider = StreamProvider.autoDispose<SellerOrderPage>((ref) {
  final uid = ref.watch(currentUidProvider);
  final limit = ref.watch(sellerOrderLimitProvider);
  if (uid == null) {
    return Stream<SellerOrderPage>.value(
      const SellerOrderPage(orders: <OrderModel>[], truncated: false),
    );
  }
  return ref.watch(orderServiceProvider).watchSellerOrders(uid, limit: limit);
});

/// Orders awaiting the buyer's confirmation.
///
/// Surfaced separately because this is the one state where the *buyer* is
/// holding up the cycle, and the points they are owed are sitting behind it.
final ordersAwaitingConfirmationProvider =
    Provider.autoDispose<List<OrderModel>>((ref) {
      final orders =
          ref.watch(buyerOrdersProvider).asData?.value.orders ??
          const <OrderModel>[];
      return orders
          .where((order) => order.status == OrderStatus.delivered)
          .toList();
    });

/// Orders the seller still has something to do about.
final sellerOpenOrdersProvider = Provider.autoDispose<List<OrderModel>>((ref) {
  final orders =
      ref.watch(sellerOrdersProvider).asData?.value.orders ??
      const <OrderModel>[];
  return orders
      .where(
        (order) => OrderStatus.nextFor(order.status, isSeller: true) != null,
      )
      .toList();
});

/// Checkout, fulfilment and confirmation.
///
/// Every method here is a call to the trusted service. There is no client write
/// path to an order, so this class has no Firestore write at all — which is the
/// visible shape of the rule that `confirmed` credits a wallet and therefore
/// cannot be a client's decision.
class OrderActions {
  OrderActions(this._ref);

  final Ref _ref;

  /// Places the cart (F4.4, F4.5).
  ///
  /// After a success, the ledger and wallet are invalidated so the balance the
  /// buyer sees next reflects the debit. They are streams and would catch up on
  /// their own; invalidating means the receipt screen is not briefly showing the
  /// pre-checkout balance next to a "points spent" line.
  Future<CheckoutOutcome> checkout({
    required int pointsRequested,
    SettlementMethod settlementMethod = SettlementMethod.cashOnDelivery,
  }) async {
    final outcome = await _ref
        .read(orderServiceProvider)
        .checkout(
          pointsRequested: pointsRequested,
          settlementMethod: settlementMethod,
        );

    _ref.read(cartActionsProvider).resetAfterCheckout();
    _refreshBalance();
    return outcome;
  }

  /// The seller ships or delivers (F4.6, F4.8).
  Future<OrderStatus> advance(OrderModel order) async {
    final next = OrderStatus.nextFor(order.status, isSeller: true);
    if (next == null) {
      throw const OrderException('There is nothing more to do on this order.');
    }
    return _ref.read(orderServiceProvider).advance(order.id, next);
  }

  /// The buyer confirms receipt, which is the only transition that pays (F4.7).
  Future<ConfirmOutcome> confirm(OrderModel order) async {
    final outcome = await _ref.read(orderServiceProvider).confirm(order.id);
    _refreshBalance();
    return outcome;
  }

  void _refreshBalance() {
    _ref.invalidate(ledgerProvider);
    _ref.invalidate(walletProvider);
  }
}

final orderActionsProvider = Provider<OrderActions>((ref) => OrderActions(ref));
