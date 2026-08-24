import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/seller_products_controller.dart';
import '../../core/network_errors.dart';
import '../../core/theme.dart';
import '../../models/product_model.dart';
import '../market/product_card.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';

/// The seller's console (F4.1).
///
/// Shows delisted listings alongside active ones, because F4.1's "delete" sets
/// `active: false` (§6.2) — a seller who could not see a delisted product would
/// have no way to bring it back and would reasonably conclude the delete had
/// been a delete.
class SellerProductsView extends ConsumerWidget {
  const SellerProductsView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final productsAsync = ref.watch(sellerProductsProvider);

    // Inside `AppShell`, like every other navigation destination. As a bare
    // `Scaffold` this screen removed the navigation bar the moment it was
    // selected from the navigation bar, and offered no back button, so its two
    // app-bar actions were carrying the whole burden of escape. Both are now
    // redundant and gone: switching profile is in the shell's account menu, and
    // "Orders to fulfil" is the Orders tab sitting next to this one.
    return AppShell(
      title: 'Your listings',
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/seller/products/new'),
        icon: const Icon(Icons.add),
        label: const Text('New listing'),
      ),
      child: productsAsync.when(
        loading: () => const ContentLoading(label: 'Loading your listings…'),
        error: (error, _) => ErrorRetry(
          error: error,
          title: 'Your listings',
          onRetry: () => ref.invalidate(sellerProductsProvider),
        ),
        data: (products) {
          if (products.isEmpty) {
            return ContentEmpty(
              icon: Icons.storefront_outlined,
              title: 'Nothing listed yet',
              message:
                  'Add a product and it appears in the shop straight away. '
                  '3ZERO Champions can pay for part of it with points.',
              actionLabel: 'Add your first listing',
              onAction: () => context.push('/seller/products/new'),
            );
          }

          final hidden = products
              .where((product) => product.hiddenBySuspension)
              .length;

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
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (hidden > 0) ...[
                        _SuspensionNotice(count: hidden),
                        const SizedBox(height: AppTheme.gapMd),
                      ],
                      for (final product in products) ...[
                        ProductCard(
                          product: product,
                          showSellerState: true,
                          onTap: () =>
                              context.push('/seller/products/${product.id}'),
                          trailing: _ListingMenu(product: product),
                        ),
                        const SizedBox(height: AppTheme.gapSm),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Explains listings the seller did not take down themselves (§7.4).
///
/// Without this, a suspended seller returning to the console finds their whole
/// catalogue delisted with no explanation and no way to tell it from something
/// they did.
class _SuspensionNotice extends StatelessWidget {
  const _SuspensionNotice({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      color: scheme.errorContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.visibility_off_outlined, color: scheme.onErrorContainer),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: Text(
                count == 1
                    ? 'One listing was hidden from the shop while your account '
                          'was suspended. A 3ZERO Admin restores it when the '
                          'suspension is lifted — nothing has been deleted.'
                    : '$count listings were hidden from the shop while your '
                          'account was suspended. A 3ZERO Admin restores them '
                          'when the suspension is lifted — nothing has been '
                          'deleted.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ListingMenu extends ConsumerWidget {
  const _ListingMenu({required this.product});

  final ProductModel product;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return PopupMenuButton<String>(
      tooltip: 'Listing actions',
      onSelected: (value) async {
        switch (value) {
          case 'edit':
            context.push('/seller/products/${product.id}');
          case 'delist':
            await _setActive(context, ref, false);
          case 'relist':
            await _setActive(context, ref, true);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'edit', child: Text('Edit')),
        if (product.active)
          const PopupMenuItem(value: 'delist', child: Text('Take off the shop'))
        else
          const PopupMenuItem(value: 'relist', child: Text('Put back on sale')),
      ],
    );
  }

  Future<void> _setActive(
    BuildContext context,
    WidgetRef ref,
    bool active,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(sellerProductActionsProvider)
          .setActive(product.id!, active);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            active
                ? '${product.title} is back on the shop.'
                : '${product.title} is off the shop. Nothing has been deleted, '
                      'and past orders keep their record.',
          ),
        ),
      );
    } catch (error) {
      messenger.showSnackBar(
        // Interpreted, not printed. `setActive` is a bare Firestore write, so
        // `$error` put `[cloud_firestore/permission-denied] Missing or
        // insufficient permissions.` in front of a seller.
        SnackBar(
          content: Text('That did not save. ${friendlyErrorMessage(error)}'),
        ),
      );
    }
  }
}
