import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/constants.dart';
import '../core/network_errors.dart';
import '../core/wire_values.dart';
import '../models/order_model.dart';

/// A page of a seller's orders, and whether the read was capped.
///
/// The flag travels with the data rather than being re-derived downstream,
/// because the only place that can know it is the query that applied the limit.
class SellerOrderPage {
  const SellerOrderPage({required this.orders, required this.truncated});

  final List<OrderModel> orders;

  /// True when more orders exist than this page carries, so any total computed
  /// from [orders] is a floor rather than a sum.
  final bool truncated;
}

/// A page of a Champion's orders, and whether older purchases exist.
///
/// Kept separate from [SellerOrderPage] even though the shape is the same so a
/// provider cannot accidentally feed a seller queue into the buyer history (or
/// vice versa) without the type system noticing.
class BuyerOrderPage {
  const BuyerOrderPage({required this.orders, required this.truncated});

  final List<OrderModel> orders;
  final bool truncated;
}

/// Orders (F4.4–F4.8).
///
/// Split along the trust boundary like every other paying path: reads come
/// straight from Firestore, and **every write goes to the trusted service**.
/// There is no client write path to an order at all — `firestore.rules` denies
/// the collection to buyers, sellers and administrators alike — because
/// `confirmed` is the transition that credits a wallet, and that has to be
/// decided where the wallet is written.
class OrderService {
  OrderService({FirebaseFirestore? firestore, http.Client? client})
    : _db = firestore ?? FirebaseFirestore.instance,
      _client = client ?? http.Client();

  final FirebaseFirestore _db;
  final http.Client _client;

  CollectionReference<Map<String, dynamic>> get _orders =>
      _db.collection('orders');

  // Caps live in `QueryLimits` (§ lib/core/constants.dart), which documents
  // why they are caps and not page sizes — there is no `startAfter` anywhere.

  // ---------------------------------------------------------------------------
  // Reads
  // ---------------------------------------------------------------------------

  Stream<BuyerOrderPage> watchBuyerOrders(
    String uid, {
    int limit = QueryLimits.orders,
  }) => _orders
      .where('buyerId', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .limit(limit + 1)
      .snapshots()
      .map((snap) {
        final truncated = snap.docs.length > limit;
        final docs = truncated ? snap.docs.take(limit) : snap.docs;
        return BuyerOrderPage(
          orders: docs.map(_fromDoc).toList(),
          truncated: truncated,
        );
      });

  Stream<SellerOrderPage> watchSellerOrders(
    String uid, {
    int limit = QueryLimits.orders,
  }) => _orders
      .where('sellerId', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .limit(limit + 1)
      .snapshots()
      .map((snap) {
        final truncated = snap.docs.length > limit;
        final docs = truncated ? snap.docs.take(limit) : snap.docs;
        return SellerOrderPage(
          orders: docs.map(_fromDoc).toList(),
          truncated: truncated,
        );
      });

  /// Every order a seller has, up to [QueryLimits.salesReport], for the sales
  /// report to total.
  ///
  /// Separate from [watchSellerOrders] because of the cap. Forty is the right
  /// number for a fulfilment list and the wrong one for an "all time" total — so
  /// this reads far deeper, and the caller is handed the raw count so it can tell
  /// whether the cap bound and say so on screen.
  ///
  /// Uses the same `sellerId` + `createdAt desc` composite index the list
  /// already relies on (`firestore.indexes.json`), so no index is added. Periods
  /// are applied in Dart rather than as a `where` range: one subscription serves
  /// all five windows, and switching between them costs no read at all.
  ///
  /// Fetches one document beyond the cap and trims it. Asking for exactly the
  /// cap and inferring truncation from `length == cap` is ambiguous precisely
  /// when it matters — a seller with exactly [QueryLimits.salesReport] orders
  /// would be warned their complete total might be partial. Reading one more
  /// turns the question into a fact: if the extra document exists, there are
  /// more orders than the report covers.
  Stream<SellerOrderPage> watchSellerOrdersForReport(String uid) => _orders
      .where('sellerId', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .limit(QueryLimits.salesReport + 1)
      .snapshots()
      .map((snap) {
        final truncated = snap.docs.length > QueryLimits.salesReport;
        final docs = truncated
            ? snap.docs.take(QueryLimits.salesReport)
            : snap.docs;
        return SellerOrderPage(
          orders: docs.map(_fromDoc).toList(),
          truncated: truncated,
        );
      });

  OrderModel _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.from(doc.data() ?? <String, dynamic>{});
    for (final key in [
      'createdAt',
      'shippedAt',
      'deliveredAt',
      'confirmedAt',
    ]) {
      final value = data[key];
      data[key] = value is Timestamp ? value.toDate() : null;
    }
    return OrderModel.fromMap(data, id: doc.id);
  }

  // ---------------------------------------------------------------------------
  // Server calls
  // ---------------------------------------------------------------------------

  /// Places the cart (F4.4, F4.5).
  ///
  /// [pointsRequested] is what the buyer asked to spend, not what they will
  /// spend: the server clamps it against the live policy, the wallet balance
  /// and the subtotal, and returns what it actually applied.
  ///
  /// **Not retried automatically, and it must not be.** A checkout consumes the
  /// cart, so the failure mode of a lost response is an apparently-failed
  /// request that actually succeeded. Retrying would find an empty cart and fail
  /// cleanly — but the buyer would still have been told the wrong thing twice,
  /// so the screen sends them to their orders instead of guessing.
  Future<CheckoutOutcome> checkout({
    required int pointsRequested,
    SettlementMethod settlementMethod = SettlementMethod.cashOnDelivery,
  }) async {
    final response = await _send(
      () async => _client
          .post(
            ApiConfig.path('/checkout'),
            headers: await _headers(),
            body: jsonEncode({
              'pointsRequested': pointsRequested,
              'settlementMethod': settlementMethod.name,
            }),
          )
          .timeout(ApiConfig.coldStartTimeout),
      action: 'placing your order',
    );

    final body = _decode(response.body);

    if (response.statusCode == 201) {
      final rawOrders = body['orders'];
      final receiptMethod = SettlementMethod.fromName(
        wireString(body['settlementMethod']),
      );
      final receiptStatus = PaymentStatus.fromName(
        wireString(body['paymentStatus']),
      );
      final receiptReference = wireString(body['paymentReference']);
      final validPayment =
          receiptMethod == settlementMethod &&
          (settlementMethod.isPrototype
              ? receiptStatus == PaymentStatus.paid &&
                    receiptReference != null &&
                    receiptReference.isNotEmpty &&
                    body['paymentPrototype'] == true
              : receiptStatus == PaymentStatus.pending);
      if (!validPayment) {
        throw const OrderException(
          'The order may have been placed, but its payment receipt was invalid. '
          'Check My orders before trying again.',
        );
      }
      return CheckoutOutcome(
        checkoutId: wireString(body['checkoutId']) ?? '',
        orderIds: rawOrders is List
            ? rawOrders
                  .map((o) => o is Map ? wireString(o['orderId']) : null)
                  .whereType<String>()
                  .toList()
            : const <String>[],
        subtotal: wireInt(body['subtotal']) ?? 0,
        pointsApplied: wireInt(body['pointsApplied']) ?? 0,
        discount: wireInt(body['discount']) ?? 0,
        payable: wireInt(body['payable']) ?? 0,
        balanceAfter: wireInt(body['balanceAfter']),
        settlementMethod: receiptMethod,
        paymentStatus: receiptStatus,
        paymentReference: receiptReference,
      );
    }

    // A 409 carries a message written for the buyer: an empty cart, a delisted
    // product, "only 2 left", a seller who is not trading. Surfaced verbatim,
    // because a generic failure at checkout leaves nothing to act on.
    throw OrderException(
      wireString(body['message']) ??
          'Your order could not be placed (${response.statusCode}).',
    );
  }

  /// The seller ships or delivers (F4.6).
  Future<OrderStatus> advance(String orderId, OrderStatus status) async {
    final response = await _send(
      () async => _client
          .post(
            ApiConfig.path('/orders/$orderId/status'),
            headers: await _headers(),
            body: jsonEncode({'status': status.name}),
          )
          .timeout(ApiConfig.coldStartTimeout),
      action: 'updating the order',
    );

    final body = _decode(response.body);
    if (response.statusCode == 200) {
      return OrderStatus.fromName(wireString(body['status']));
    }

    throw OrderException(
      wireString(body['message']) ??
          'The order could not be updated (${response.statusCode}).',
    );
  }

  /// The buyer confirms receipt, which is the only transition that pays (F4.7).
  Future<ConfirmOutcome> confirm(String orderId) async {
    final response = await _send(
      () async => _client
          .post(
            ApiConfig.path('/orders/$orderId/confirm'),
            headers: await _headers(),
          )
          .timeout(ApiConfig.coldStartTimeout),
      action: 'confirming the order',
    );

    final body = _decode(response.body);
    if (response.statusCode == 200) {
      return ConfirmOutcome(
        orderId: orderId,
        pointsAwarded: wireInt(body['pointsAwarded']) ?? 0,
        balanceAfter: wireInt(body['balanceAfter']),
      );
    }

    throw OrderException(
      wireString(body['message']) ??
          'The order could not be confirmed (${response.statusCode}).',
    );
  }

  Future<Map<String, String>> _headers() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw const OrderException('You are not signed in.');
    final token = await user.getIdToken();
    return {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $token',
    };
  }

  Future<http.Response> _send(
    Future<http.Response> Function() request, {
    required String action,
  }) async {
    try {
      return await request();
    } on TimeoutException catch (error) {
      _log('timed out $action', error);
      throw OrderException(slowServerMessage);
    } on http.ClientException catch (error) {
      _log('client exception $action — on web, check CORS', error);
      throw OrderException(unreachableServerMessage);
    } on OrderException {
      rethrow;
    } catch (error, stackTrace) {
      _log('unexpected failure $action', error, stackTrace);
      throw OrderException('Something went wrong $action. Try again.');
    }
  }

  Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : <String, dynamic>{};
    } catch (error) {
      _log('response body was not JSON', error);
      return <String, dynamic>{};
    }
  }
}

/// What a checkout actually did, as the server reports it.
///
/// The figures here are the authoritative ones. The quote the buyer saw came
/// from `checkout_math.dart` over prices read a moment earlier; these came out
/// of the transaction that charged them.
class CheckoutOutcome {
  const CheckoutOutcome({
    required this.checkoutId,
    required this.orderIds,
    required this.subtotal,
    required this.pointsApplied,
    required this.discount,
    required this.payable,
    required this.settlementMethod,
    required this.paymentStatus,
    this.balanceAfter,
    this.paymentReference,
  });

  final String checkoutId;

  /// One id per seller in the cart (§7.4).
  final List<String> orderIds;

  final int subtotal;
  final int pointsApplied;
  final int discount;
  final int payable;
  final SettlementMethod settlementMethod;
  final PaymentStatus paymentStatus;
  final int? balanceAfter;
  final String? paymentReference;

  int get orderCount => orderIds.length;

  /// True when the server applied fewer points than the buyer asked for —
  /// worth saying out loud rather than quietly charging a different total.
  bool appliedLessThan(int requested) => pointsApplied < requested;
}

class ConfirmOutcome {
  const ConfirmOutcome({
    required this.orderId,
    required this.pointsAwarded,
    this.balanceAfter,
  });

  final String orderId;
  final int pointsAwarded;
  final int? balanceAfter;
}

void _log(String context, Object error, [StackTrace? stackTrace]) {
  if (!kDebugMode) return;
  debugPrint('[OrderService] $context: $error');
  if (stackTrace != null) debugPrint('$stackTrace');
}

class OrderException implements UserFacingException {
  @override
  final String message;
  const OrderException(this.message);

  @override
  String toString() => message;
}
