import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/api_config.dart';
import '../core/constants.dart';
import '../core/network_errors.dart';
import '../core/product_taxonomy.dart';
import '../core/wire_values.dart';
import '../models/product_model.dart';

/// Marketplace listings (F4.1, F4.2).
///
/// Unlike the disposal and claim services, the writes here are Firestore writes
/// and they are the real thing — a seller's own listing, validated by
/// `firestore.rules` against an exact key set. See the note at the top of
/// `product_model.dart` for why that is the right side of the trust boundary
/// for a price and the wrong side for a wallet balance.
///
/// The one call that goes to the trusted service is the catalogue sweep an
/// administrator triggers when suspending a seller: `products` is writable only
/// by its owner, so an administrator has no rule that would let them reach in,
/// and inventing one would be a far larger privilege than the job needs.
class ProductService {
  ProductService({FirebaseFirestore? firestore, http.Client? client})
    : _db = firestore ?? FirebaseFirestore.instance,
      _client = client ?? http.Client();

  final FirebaseFirestore _db;
  final http.Client _client;

  CollectionReference<Map<String, dynamic>> get _products =>
      _db.collection('products');

  // Caps live in `QueryLimits` (§ lib/core/constants.dart). The catalogue's is
  // applied BEFORE the client-side multi-token narrowing in `watchCatalog`, which
  // is a real limitation and is documented there.

  // ---------------------------------------------------------------------------
  // Catalogue reads (F4.2)
  // ---------------------------------------------------------------------------

  /// The buyer-facing catalogue, newest first.
  ///
  /// [query] is matched with `array-contains` against `searchTokens`, because
  /// Firestore has no full-text search (§6.3). Only the **first** token of a
  /// multi-word query is sent: `array-contains` accepts one value, and
  /// `array-contains-any` is a union rather than an intersection, so it would
  /// widen a two-word search instead of narrowing it. The remaining tokens are
  /// applied client-side by [matchesAllTokens], which is honest at this scale —
  /// the catalogue holds tens of products — and is stated as a limitation rather
  /// than presented as a search engine.
  ///
  /// **The cap applies before the narrowing, and that is a real limitation.**
  /// Firestore applies `.limit()` server-side, so a two-word search sees only
  /// the first [QueryLimits.catalog] listings matching token one, and a product
  /// matching both words but sitting outside that window is not found. At the
  /// catalogue size this project targets (§6.3, tens of products) the window
  /// covers everything; it is stated here rather than discovered later.
  ///
  /// Composite indexes for every combination below are committed in
  /// `firestore.indexes.json`.
  Stream<List<ProductModel>> watchCatalog({
    String query = '',
    ProductCategory? category,
  }) {
    final tokens = tokenizeQuery(query);

    Query<Map<String, dynamic>> q = _products.where('active', isEqualTo: true);

    if (category != null) {
      q = q.where('category', isEqualTo: category.name);
    }
    if (tokens.isNotEmpty) {
      q = q.where('searchTokens', arrayContains: tokens.first);
    }

    return q
        .orderBy('createdAt', descending: true)
        .limit(QueryLimits.catalog)
        .snapshots()
        .map((snap) {
          final products = snap.docs.map(_fromDoc).toList();
          if (tokens.length <= 1) return products;
          return products
              .where((product) => matchesAllTokens(product, tokens))
              .toList();
        });
  }

  /// Whether a listing carries every token of a multi-word query.
  ///
  /// Pure and public so `test/` can assert the narrowing behaviour without an
  /// emulator.
  static bool matchesAllTokens(ProductModel product, List<String> tokens) {
    final indexed = product.searchTokens.toSet();
    return tokens.every(indexed.contains);
  }

  Stream<ProductModel?> watchProduct(String productId) => _products
      .doc(productId)
      .snapshots()
      .map((doc) => doc.exists ? _fromDoc(doc) : null);

  /// Resolves several listings at once, for a cart.
  ///
  /// `whereIn` caps at 30 values per query, which sits above the cart's own
  /// ceiling of 20 (§ `CartItem.maxItems`), so one query always suffices. The
  /// guard is here anyway because the two limits are set in different files and
  /// nothing else would notice if one moved.
  Stream<List<ProductModel>> watchProductsByIds(List<String> ids) {
    if (ids.isEmpty) {
      return Stream<List<ProductModel>>.value(const <ProductModel>[]);
    }
    final capped = ids.take(30).toList();
    return _products
        .where(FieldPath.documentId, whereIn: capped)
        .snapshots()
        .map((snap) => snap.docs.map(_fromDoc).toList());
  }

  /// Everything one seller has listed, active or not — the seller console shows
  /// their delisted products too, since delisting is how F4.1 deletes.
  Stream<List<ProductModel>> watchSellerProducts(String sellerId) => _products
      .where('sellerId', isEqualTo: sellerId)
      .orderBy('createdAt', descending: true)
      .limit(QueryLimits.sellerListings)
      .snapshots()
      .map((snap) => snap.docs.map(_fromDoc).toList());

  // ---------------------------------------------------------------------------
  // Seller writes (F4.1)
  // ---------------------------------------------------------------------------

  /// Creates a listing and returns its document id.
  ///
  /// Both timestamps are server timestamps: the rules require each to equal
  /// `request.time`, so a device clock is refused outright (§6.2).
  Future<String> createProduct(ProductModel product) async {
    final doc = await _products.add(<String, dynamic>{
      ...product.toCreateJson(),
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return doc.id;
  }

  /// Saves an edit.
  ///
  /// The payload omits `sellerId` and `createdAt` deliberately — rules pin the
  /// affected key set, so including either, even unchanged, is a permission
  /// denial rather than a no-op.
  Future<void> updateProduct(String productId, ProductModel product) {
    return _products.doc(productId).update(<String, dynamic>{
      ...product.toUpdateJson(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// F4.1's "delete". Never a hard delete (§6.2): an order line keeps a
  /// `productId` beside its price snapshot, and a dangling reference breaks a
  /// buyer's receipt.
  Future<void> setActive(String productId, bool active) {
    return _products.doc(productId).update(<String, dynamic>{
      'active': active,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // ---------------------------------------------------------------------------
  // Administrator sweep (§7.4)
  // ---------------------------------------------------------------------------

  /// Hides or restores a seller's whole catalogue alongside a suspension.
  ///
  /// Returns how many listings changed, so the administrator's screen can say
  /// "8 listings hidden" rather than claiming something happened.
  ///
  /// This is a second operation after the suspension write, not part of it. The
  /// screen has to report a partial failure honestly rather than pretend the
  /// pair was atomic — a suspension that took effect with the catalogue still
  /// visible is a state somebody has to be told about.
  Future<int> setSellerListingsVisible(String sellerUid, bool visible) async {
    final response = await _send(
      () async => _client
          .post(
            ApiConfig.path('/sellers/$sellerUid/listings'),
            headers: await _headers(),
            body: jsonEncode({'visible': visible}),
          )
          .timeout(ApiConfig.coldStartTimeout),
      action: visible ? 'restoring their listings' : 'hiding their listings',
    );

    final body = _decode(response.body);
    if (response.statusCode == 200) {
      return wireInt(body['changed']) ?? 0;
    }

    throw ProductException(
      wireString(body['message']) ??
          'Their listings could not be updated (${response.statusCode}).',
    );
  }

  ProductModel _fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = Map<String, dynamic>.from(doc.data() ?? <String, dynamic>{});
    for (final key in ['createdAt', 'updatedAt']) {
      final value = data[key];
      data[key] = value is Timestamp ? value.toDate() : null;
    }
    return ProductModel.fromMap(data, id: doc.id);
  }

  Future<Map<String, String>> _headers() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw const ProductException('You are not signed in.');
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
      throw ProductException(slowServerMessage);
    } on http.ClientException catch (error) {
      _log('client exception $action — on web, check CORS', error);
      throw ProductException(unreachableServerMessage);
    } on ProductException {
      rethrow;
    } catch (error, stackTrace) {
      _log('unexpected failure $action', error, stackTrace);
      throw ProductException('Something went wrong $action. Try again.');
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

void _log(String context, Object error, [StackTrace? stackTrace]) {
  if (!kDebugMode) return;
  debugPrint('[ProductService] $context: $error');
  if (stackTrace != null) debugPrint('$stackTrace');
}

class ProductException implements Exception {
  final String message;
  const ProductException(this.message);

  @override
  String toString() => message;
}
