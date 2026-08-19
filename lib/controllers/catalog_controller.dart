import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/product_taxonomy.dart';
import '../models/product_model.dart';
import '../services/product_service.dart';

final productServiceProvider = Provider<ProductService>((ref) {
  return ProductService();
});

/// What the buyer has typed and picked (F4.2).
///
/// One immutable object rather than two providers, so a query and a category
/// change together produce one stream rebuild instead of two — and so the
/// catalogue provider has a single dependency to key on.
class CatalogFilter {
  const CatalogFilter({this.query = '', this.category});

  final String query;
  final ProductCategory? category;

  bool get isActive => query.trim().isNotEmpty || category != null;

  CatalogFilter copyWith({String? query, ProductCategory? category}) =>
      CatalogFilter(
        query: query ?? this.query,
        category: category ?? this.category,
      );

  /// Separate from [copyWith] because passing null to clear a category cannot be
  /// distinguished from omitting it — the same reason `UserModel.copyWith` has
  /// `clearSuspendedUntil`.
  CatalogFilter withoutCategory() => CatalogFilter(query: query);

  @override
  bool operator ==(Object other) =>
      other is CatalogFilter &&
      other.query == query &&
      other.category == category;

  @override
  int get hashCode => Object.hash(query, category);
}

class CatalogFilterController extends Notifier<CatalogFilter> {
  @override
  CatalogFilter build() => const CatalogFilter();

  void setQuery(String query) => state = state.copyWith(query: query);

  void setCategory(ProductCategory? category) {
    state = category == null
        ? state.withoutCategory()
        : state.copyWith(category: category);
  }

  void clear() => state = const CatalogFilter();
}

final catalogFilterProvider =
    NotifierProvider<CatalogFilterController, CatalogFilter>(
      CatalogFilterController.new,
    );

/// The buyer-facing catalogue under the current filter.
///
/// `autoDispose` because a shopper leaving the screen has no reason to keep a
/// Firestore listener open — the disposal flow's own streams are shaped the same
/// way. Re-entering re-reads, which is cheap at this catalogue's size.
final catalogProvider = StreamProvider.autoDispose<List<ProductModel>>((ref) {
  final filter = ref.watch(catalogFilterProvider);
  return ref
      .watch(productServiceProvider)
      .watchCatalog(query: filter.query, category: filter.category);
});

/// One listing, live.
///
/// Live rather than fetched once because stock is the field the buyer is about
/// to act on, and a sold-out product should stop offering an "Add to cart"
/// button while they are looking at it.
final productProvider = StreamProvider.autoDispose
    .family<ProductModel?, String>((ref, productId) {
      return ref.watch(productServiceProvider).watchProduct(productId);
    });
