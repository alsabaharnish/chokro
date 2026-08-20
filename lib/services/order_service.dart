import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/constants.dart';
import '../core/network_errors.dart';
import '../models/order_model.dart';

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

  Stream<List<OrderModel>> watchBuyerOrders(String uid) => _orders
      .where('buyerId', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .limit(QueryLimits.orders)
      .snapshots()
      .map((snap) => snap.docs.map(_fromDoc).toList());

  Stream<List<OrderModel>> watchSellerOrders(String uid) => _orders
      .where('sellerId', isEqualTo: uid)
      .orderBy('createdAt', descending: true)
      .limit(QueryLimits.orders)
      .snapshots()
      .map((snap) => snap.docs.map(_fromDoc).toList());

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
    String settlementMethod = 'cashOnDelivery',
  }) async {
    final response = await _send(
      () async => _client
          .post(
            ApiConfig.path('/checkout'),
            headers: await _headers(),
            body: jsonEncode({
              'pointsRequested': pointsRequested,
              'settlementMethod': settlementMethod,
            }),
          )
          .timeout(ApiConfig.coldStartTimeout),
      action: 'placing your order',
    );

    final body = _decode(response.body);

    if (response.statusCode == 201) {
      final rawOrders = body['orders'];
      return CheckoutOutcome(
        checkoutId: (body['checkoutId'] as String?) ?? '',
        orderIds: rawOrders is List
            ? rawOrders
                  .map((o) => o is Map ? o['orderId'] as String? : null)
                  .whereType<String>()
                  .toList()
            : const <String>[],
        subtotal: (body['subtotal'] as num?)?.toInt() ?? 0,
        pointsApplied: (body['pointsApplied'] as num?)?.toInt() ?? 0,
        discount: (body['discount'] as num?)?.toInt() ?? 0,
        payable: (body['payable'] as num?)?.toInt() ?? 0,
        balanceAfter: (body['balanceAfter'] as num?)?.toInt(),
      );
    }

    // A 409 carries a message written for the buyer: an empty cart, a delisted
    // product, "only 2 left", a seller who is not trading. Surfaced verbatim,
    // because a generic failure at checkout leaves nothing to act on.
    throw OrderException(
      (body['message'] as String?) ??
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
      return OrderStatus.fromName(body['status'] as String?);
    }

    throw OrderException(
      (body['message'] as String?) ??
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
        pointsAwarded: (body['pointsAwarded'] as num?)?.toInt() ?? 0,
        balanceAfter: (body['balanceAfter'] as num?)?.toInt(),
      );
    }

    throw OrderException(
      (body['message'] as String?) ??
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
    this.balanceAfter,
  });

  final String checkoutId;

  /// One id per seller in the cart (§7.4).
  final List<String> orderIds;

  final int subtotal;
  final int pointsApplied;
  final int discount;
  final int payable;
  final int? balanceAfter;

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

class OrderException implements Exception {
  final String message;
  const OrderException(this.message);

  @override
  String toString() => message;
}
