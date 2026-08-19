import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/product_model.dart';
import '../services/photo_upload_service.dart';
import '../services/product_service.dart';
import 'catalog_controller.dart';
import 'current_user_provider.dart';

final productPhotoUploadProvider = Provider<PhotoUploadService>((ref) {
  return PhotoUploadService();
});

/// The signed-in seller's own listings, active and delisted alike (F4.1).
///
/// Delisted ones are included deliberately: F4.1's "delete" sets `active: false`
/// (§6.2), so a seller who could not see their delisted products would have no
/// way to bring one back and would reasonably conclude the delete had worked
/// like a delete.
final sellerProductsProvider = StreamProvider.autoDispose<List<ProductModel>>((
  ref,
) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) {
    return Stream<List<ProductModel>>.value(const <ProductModel>[]);
  }
  return ref.watch(productServiceProvider).watchSellerProducts(uid);
});

/// Create, edit, delist and photograph a listing.
///
/// A plain class behind a `Provider` rather than a notifier, for the same reason
/// as `PointsPolicyEditor`: the form owns its in-progress state in its own text
/// controllers, and a second copy of that state here would be two things to keep
/// in step.
class SellerProductActions {
  SellerProductActions(this._ref);

  final Ref _ref;

  /// Writes a new listing and returns its id.
  ///
  /// Validation runs before the write, because the rules give no reason when
  /// they refuse — a `permission-denied` on a product create could be any of a
  /// dozen bounds, and the seller would have nothing to correct.
  Future<String> create(ProductModel product) async {
    _assertValid(product);
    return _ref.read(productServiceProvider).createProduct(product);
  }

  Future<void> update(String productId, ProductModel product) async {
    _assertValid(product);
    await _ref.read(productServiceProvider).updateProduct(productId, product);
  }

  /// F4.1's delete, and its undo. Never a hard delete.
  Future<void> setActive(String productId, bool active) {
    return _ref.read(productServiceProvider).setActive(productId, active);
  }

  /// Uploads a listing photograph and returns its stored URL.
  ///
  /// The URL is what `firestore.rules` checks against this seller's own product
  /// folder, so it has to come back from the server rather than being composed
  /// here. Works on web as well as mobile: the bytes arrive from `image_picker`
  /// and nothing on this path touches `dart:io`.
  Future<String> uploadPhoto(Uint8List bytes) async {
    final photo = await _ref
        .read(productPhotoUploadProvider)
        .uploadProductPhoto(bytes);
    return photo.url;
  }

  void _assertValid(ProductModel product) {
    final problems = product.validate();
    if (problems.isNotEmpty) throw ProductException(problems.first);
  }
}

final sellerProductActionsProvider = Provider<SellerProductActions>((ref) {
  return SellerProductActions(ref);
});
