import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/cart_model.dart';

/// The buyer's cart (F4.3).
///
/// One document per user, `carts/{uid}`, holding product ids and quantities and
/// no prices at all (§6.2). Every write is a whole-document `set`, which is what
/// the rules expect: they check an exact top-level key set, so a partial update
/// adding a field would be refused.
///
/// The cart is never read by anything that decides money. The server resolves
/// every `productId` against a live listing inside the checkout transaction, so
/// a stale or malformed cart cannot buy anything — it fails checkout.
class CartService {
  CartService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  DocumentReference<Map<String, dynamic>> _cartRef(String uid) =>
      _db.collection('carts').doc(uid);

  /// The user's cart, live.
  ///
  /// A missing document is an empty cart rather than an error: the document
  /// does not exist until the first item is added, and the server deletes it at
  /// checkout so the next write creates it fresh with a server timestamp.
  Stream<CartModel> watchCart(String uid) =>
      _cartRef(uid).snapshots().map((doc) {
        final data = doc.data();
        for (final key in ['updatedAt']) {
          final value = data?[key];
          if (value is Timestamp) data![key] = value.toDate();
        }
        return CartModel.fromMap(data, userId: uid);
      });

  /// Writes the whole cart.
  ///
  /// `updatedAt` is a server timestamp, which the rules require. A phone with a
  /// wrong clock must not be able to stamp its own cart.
  Future<void> save(CartModel cart) {
    return _cartRef(cart.userId).set(<String, dynamic>{
      ...cart.toJson(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Empties the cart by removing the document.
  ///
  /// Only used when a buyer clears it themselves — the server deletes it as
  /// part of the checkout transaction, where it belongs, so that a cart is never
  /// consumed without orders being written.
  Future<void> clear(String uid) => _cartRef(uid).delete();
}
