import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/cart_controller.dart';
import '../../controllers/catalog_controller.dart';
import '../../core/label_format.dart';
import '../../core/network_errors.dart';
import '../../core/theme.dart';
import '../../models/product_model.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import 'product_card.dart';

/// One listing, and the decision to buy it (F4.2, F4.3).
///
/// Watches the product live rather than taking a snapshot from the catalogue,
/// because stock is the field the buyer is about to act on: a product that sells
/// out while they are reading should stop offering an "Add to cart" button
/// rather than fail at checkout.
class ProductDetailView extends ConsumerWidget {
  const ProductDetailView({super.key, required this.productId});

  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final productAsync = ref.watch(productProvider(productId));

    return Scaffold(
      appBar: AppBar(title: const Text('Product')),
      body: productAsync.when(
        loading: () => const ContentLoading(label: 'Loading the listing…'),
        error: (error, _) => ErrorRetry(
          error: error,
          title: 'This listing',
          onRetry: () => ref.invalidate(productProvider(productId)),
        ),
        data: (product) {
          if (product == null || !product.active) {
            return ContentEmpty(
              icon: Icons.remove_shopping_cart_outlined,
              title: 'No longer listed',
              message:
                  'The Greenpreneur has withdrawn this product. Nothing has been '
                  'charged.',
              actionLabel: 'Back to the shop',
              onAction: () => context.go('/market'),
            );
          }
          return _ProductBody(product: product);
        },
      ),
    );
  }
}

class _ProductBody extends ConsumerWidget {
  const _ProductBody({required this.product});

  final ProductModel product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final user = ref.watch(currentUserProvider).value;
    final inCart =
        ref.watch(cartProvider).asData?.value.qtyOf(product.id!) ?? 0;

    // Self-dealing is refused at checkout, in the rules' spirit and in
    // `checkout.js` for real (§7.4). Saying so here means a seller browsing
    // their own shop understands why the button is absent rather than reporting
    // it as a bug.
    final isOwnListing = user != null && user.uid == product.sellerId;
    final suspended = user != null && !user.isActive;

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppTheme.gapMd,
        AppTheme.gapMd,
        AppTheme.gapMd,
        AppTheme.gap2Xl,
      ),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: AppTheme.maxContentWidth,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (product.imageUrls.isNotEmpty)
                  SizedBox(
                    height: 220,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: product.imageUrls.length,
                      separatorBuilder: (_, _) =>
                          const SizedBox(width: AppTheme.gapSm),
                      itemBuilder: (context, index) => ProductThumbnail(
                        url: product.imageUrls[index],
                        size: 220,
                      ),
                    ),
                  )
                else
                  const ProductThumbnail(url: null, size: 160),

                const SizedBox(height: AppTheme.gapLg),
                Text(
                  product.title,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: AppTheme.gapXs),
                Text(
                  formatTaka(product.price),
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                    color: scheme.primary,
                  ),
                ),

                const SizedBox(height: AppTheme.gapMd),
                Wrap(
                  spacing: AppTheme.gapSm,
                  runSpacing: AppTheme.gapSm,
                  children: [
                    Chip(
                      avatar: const Icon(Icons.category_outlined, size: 16),
                      label: Text(product.category.label),
                      visualDensity: VisualDensity.compact,
                    ),
                    if (product.shopName.isNotEmpty)
                      Chip(
                        avatar: const Icon(Icons.storefront_outlined, size: 16),
                        // Labelled "Shop" rather than presented as a verified
                        // identity — see `ProductModel.shopName`.
                        label: Text('Shop: ${product.shopName}'),
                        visualDensity: VisualDensity.compact,
                      ),
                    Chip(
                      avatar: Icon(
                        product.isOutOfStock
                            ? Icons.remove_shopping_cart_outlined
                            : Icons.inventory_2_outlined,
                        size: 16,
                      ),
                      label: Text(
                        product.isOutOfStock
                            ? 'Out of stock'
                            : '${product.stock} in stock',
                      ),
                      visualDensity: VisualDensity.compact,
                    ),
                  ],
                ),

                const SizedBox(height: AppTheme.gapLg),
                Text(
                  product.description,
                  style: theme.textTheme.bodyLarge?.copyWith(height: 1.5),
                ),

                if (product.tags.isNotEmpty) ...[
                  const SizedBox(height: AppTheme.gapLg),
                  Wrap(
                    spacing: AppTheme.gapSm,
                    runSpacing: AppTheme.gapSm,
                    children: [
                      for (final tag in product.tags)
                        // Tapping a tag searches for it, which is the only thing
                        // a tag is for — the token is in this product's search
                        // index, so the query is guaranteed to find it.
                        ActionChip(
                          label: Text('#$tag'),
                          onPressed: () {
                            ref
                                .read(catalogFilterProvider.notifier)
                                .setQuery(tag);
                            context.go('/market');
                          },
                        ),
                    ],
                  ),
                ],

                const SizedBox(height: AppTheme.gapXl),
                _BuyRow(
                  product: product,
                  inCart: inCart,
                  isOwnListing: isOwnListing,
                  suspended: suspended,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BuyRow extends ConsumerStatefulWidget {
  const _BuyRow({
    required this.product,
    required this.inCart,
    required this.isOwnListing,
    required this.suspended,
  });

  final ProductModel product;
  final int inCart;
  final bool isOwnListing;
  final bool suspended;

  @override
  ConsumerState<_BuyRow> createState() => _BuyRowState();
}

class _BuyRowState extends ConsumerState<_BuyRow> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final product = widget.product;

    if (widget.isOwnListing) {
      return _Notice(
        icon: Icons.storefront_outlined,
        message:
            'This is your own listing. Buying from yourself is refused at '
            'checkout, so no cart button is offered here.',
      );
    }
    if (widget.suspended) {
      return _Notice(
        icon: Icons.pause_circle_outline,
        message: 'Your account is suspended, so you cannot place an order.',
      );
    }
    if (product.isOutOfStock) {
      return _Notice(
        icon: Icons.remove_shopping_cart_outlined,
        message: 'This is out of stock. The Greenpreneur may restock it.',
      );
    }

    final atLimit = widget.inCart >= product.stock;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.inCart > 0) ...[
          Text(
            '${widget.inCart} already in your cart.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: AppTheme.gapSm),
        ],
        FilledButton.icon(
          onPressed: _busy || atLimit ? null : _add,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add_shopping_cart),
          label: Text(
            atLimit
                ? 'All ${product.stock} in your cart'
                : widget.inCart > 0
                ? 'Add another'
                : 'Add to cart',
          ),
        ),
        if (widget.inCart > 0) ...[
          const SizedBox(height: AppTheme.gapSm),
          OutlinedButton.icon(
            onPressed: () => context.push('/cart'),
            icon: const Icon(Icons.shopping_cart_outlined),
            label: const Text('Go to cart'),
          ),
        ],
      ],
    );
  }

  Future<void> _add() async {
    setState(() => _busy = true);
    try {
      await ref.read(cartActionsProvider).add(widget.product.id!);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${widget.product.title} added to your cart.'),
          action: SnackBarAction(
            label: 'Cart',
            onPressed: () => context.push('/cart'),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        // `CartUnavailableException` already carries a sentence and passes
        // through unchanged; a Firestore failure on the cart write does not,
        // and `$error` rendered its vendor prefix to the buyer.
        SnackBar(
          content: Text(
            'Could not update your cart. ${friendlyErrorMessage(error)}',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      color: scheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: scheme.onSurfaceVariant),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
