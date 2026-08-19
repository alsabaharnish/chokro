import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/catalog_controller.dart';
import '../../controllers/cart_controller.dart';
import '../../core/constants.dart';
import '../../core/product_taxonomy.dart';
import '../../core/theme.dart';
import '../../models/product_model.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import 'product_card.dart';

/// The buyer's catalogue (F4.2).
///
/// ## What the search box actually does
///
/// Firestore has no full-text search (§6.3), so a query is an `array-contains`
/// against the `searchTokens` array each listing carries. That has two visible
/// consequences and the screen states both rather than implying a search engine:
/// matching is by whole word, and a multi-word query narrows client-side after
/// the first token.
///
/// The category filter is a separate equality clause, which is why
/// `firestore.indexes.json` carries a composite index for every combination of
/// active, category, token and sort order.
class CatalogView extends ConsumerStatefulWidget {
  const CatalogView({super.key});

  @override
  ConsumerState<CatalogView> createState() => _CatalogViewState();
}

class _CatalogViewState extends ConsumerState<CatalogView> {
  late final TextEditingController _search;

  @override
  void initState() {
    super.initState();
    // Seeded from the provider so returning from a product detail screen does
    // not silently drop the query the results are still filtered by.
    _search = TextEditingController(
      text: ref.read(catalogFilterProvider).query,
    );
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filter = ref.watch(catalogFilterProvider);
    final catalogAsync = ref.watch(catalogProvider);
    final cartCount = ref.watch(cartCountProvider);

    return AppShell(
      title: 'Shop',
      child: Column(
        children: [
          _SearchAndFilters(
            controller: _search,
            filter: filter,
            cartCount: cartCount,
            onQueryChanged: (value) =>
                ref.read(catalogFilterProvider.notifier).setQuery(value),
            onCategoryChanged: (category) =>
                ref.read(catalogFilterProvider.notifier).setCategory(category),
            onOpenCart: () => context.push('/cart'),
          ),
          const Divider(height: 1),
          Expanded(
            child: catalogAsync.when(
              loading: () => const ContentLoading(label: 'Loading the shop…'),
              error: (error, _) => ErrorRetry(
                error: error,
                title: 'The shop',
                onRetry: () => ref.invalidate(catalogProvider),
              ),
              data: (products) => _CatalogBody(
                products: products,
                filter: filter,
                onClearFilters: () {
                  _search.clear();
                  ref.read(catalogFilterProvider.notifier).clear();
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchAndFilters extends StatelessWidget {
  const _SearchAndFilters({
    required this.controller,
    required this.filter,
    required this.cartCount,
    required this.onQueryChanged,
    required this.onCategoryChanged,
    required this.onOpenCart,
  });

  final TextEditingController controller;
  final CatalogFilter filter;
  final int cartCount;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<ProductCategory?> onCategoryChanged;
  final VoidCallback onOpenCart;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.gapMd,
        AppTheme.gapMd,
        AppTheme.gapMd,
        AppTheme.gapSm,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: AppTheme.maxDashboardWidth,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: controller,
                      textInputAction: TextInputAction.search,
                      onChanged: onQueryChanged,
                      decoration: InputDecoration(
                        prefixIcon: const Icon(Icons.search),
                        hintText: 'Search by product name or tag',
                        // Says what the search can do, rather than letting a
                        // buyer conclude the catalogue is empty when they typed
                        // half a word.
                        helperText: 'Matches whole words',
                        suffixIcon: controller.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                icon: const Icon(Icons.close),
                                onPressed: () {
                                  controller.clear();
                                  onQueryChanged('');
                                },
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppTheme.gapSm),
                  _CartButton(count: cartCount, onPressed: onOpenCart),
                ],
              ),
              const SizedBox(height: AppTheme.gapSm),
              SizedBox(
                height: 40,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    FilterChip(
                      label: const Text('All'),
                      selected: filter.category == null,
                      onSelected: (_) => onCategoryChanged(null),
                    ),
                    for (final category in ProductCategory.values) ...[
                      const SizedBox(width: AppTheme.gapSm),
                      FilterChip(
                        label: Text(category.label),
                        selected: filter.category == category,
                        onSelected: (selected) =>
                            onCategoryChanged(selected ? category : null),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CartButton extends StatelessWidget {
  const _CartButton({required this.count, required this.onPressed});

  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Badge.count(
      count: count,
      isLabelVisible: count > 0,
      child: IconButton.filledTonal(
        tooltip: count == 0 ? 'Cart' : 'Cart — $count in it',
        onPressed: onPressed,
        icon: const Icon(Icons.shopping_cart_outlined),
      ),
    );
  }
}

class _CatalogBody extends StatelessWidget {
  const _CatalogBody({
    required this.products,
    required this.filter,
    required this.onClearFilters,
  });

  final List<ProductModel> products;
  final CatalogFilter filter;
  final VoidCallback onClearFilters;

  @override
  Widget build(BuildContext context) {
    if (products.isEmpty) {
      // Two genuinely different situations, and a buyer needs to be able to tell
      // them apart: nothing matches what they asked for, or nothing is listed
      // at all.
      return filter.isActive
          ? ContentEmpty(
              icon: Icons.search_off,
              title: 'Nothing matched',
              message:
                  'Search matches whole words, so try a shorter term — or clear '
                  'the filters to see everything on sale.',
              actionLabel: 'Clear filters',
              onAction: onClearFilters,
            )
          : const ContentEmpty(
              icon: Icons.storefront_outlined,
              title: 'The shop is empty',
              message:
                  'Nothing is listed yet. Sellers add products from their own '
                  'console.',
            );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= AppConstants.webBreakpoint;
        final columns = isWide ? 2 : 1;

        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppTheme.gapMd,
            AppTheme.gapMd,
            AppTheme.gapMd,
            AppTheme.gapXl,
          ),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: AppTheme.maxDashboardWidth,
                ),
                child: LayoutBuilder(
                  builder: (context, inner) {
                    final width = columns == 1
                        ? inner.maxWidth
                        : (inner.maxWidth - AppTheme.gapMd) / 2;

                    return Wrap(
                      spacing: AppTheme.gapMd,
                      runSpacing: AppTheme.gapMd,
                      children: [
                        for (final product in products)
                          SizedBox(
                            width: width,
                            child: ProductCard(
                              product: product,
                              onTap: () =>
                                  context.push('/market/${product.id}'),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
