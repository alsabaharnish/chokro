import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/cart_controller.dart';
import '../../core/checkout_math.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../shared/content_state.dart';
import 'product_card.dart';

/// The cart (F4.3).
///
/// Prices shown here are read from the live product documents, not stored on the
/// cart — the cart holds ids and quantities only (§6.2). What follows from that
/// is visible on this screen: a line whose listing has been withdrawn or has run
/// short does not appear at a stale price, it appears in the "needs attention"
/// block with what to do about it.
class CartView extends ConsumerWidget {
  const CartView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cartAsync = ref.watch(cartProvider);
    final lines = ref.watch(cartLinesProvider);
    final problems = ref.watch(unavailableCartItemsProvider);
    final quote = ref.watch(checkoutQuoteProvider);
    // The footer's total comes from the lines, not the quote, so a wallet or
    // policy read failing does not take the subtotal down with it.
    final subtotal = ref.watch(cartSubtotalProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cart'),
        actions: [
          if (lines.isNotEmpty || problems.isNotEmpty)
            TextButton(
              onPressed: () => _confirmClear(context, ref),
              child: const Text('Empty'),
            ),
        ],
      ),
      body: cartAsync.when(
        loading: () => const ContentLoading(label: 'Loading your cart…'),
        error: (error, _) => ContentEmpty(
          icon: Icons.cloud_off_outlined,
          title: 'Your cart did not load',
          message: 'Check your connection and open it again.',
          actionLabel: 'Back to the shop',
          onAction: () => context.go('/market'),
        ),
        data: (cart) {
          if (cart.isEmpty) {
            return ContentEmpty(
              icon: Icons.shopping_cart_outlined,
              title: 'Your cart is empty',
              message:
                  'Points you have earned can pay for part of an order — up to '
                  'half of it.',
              actionLabel: 'Browse the shop',
              onAction: () => context.go('/market'),
            );
          }

          return Column(
            children: [
              Expanded(
                child: ListView(
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
                          maxWidth: AppTheme.maxContentWidth,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (problems.isNotEmpty) ...[
                              _ProblemsCard(problems: problems),
                              const SizedBox(height: AppTheme.gapLg),
                            ],
                            for (final line in lines) ...[
                              _CartLineTile(line: line),
                              const SizedBox(height: AppTheme.gapSm),
                            ],
                            if ((quote?.orderCount ?? 0) > 1) ...[
                              const SizedBox(height: AppTheme.gapSm),
                              _SplitNotice(sellerCount: quote!.orderCount),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (lines.isNotEmpty)
                _CartFooter(
                  subtotal: subtotal,
                  sellerCount: quote?.orderCount,
                  blocked: problems.isNotEmpty,
                ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Empty your cart?'),
        content: const Text(
          'Everything in it is removed. Nothing has been ordered or charged.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Empty'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    await ref.read(cartActionsProvider).clear();
  }
}

class _CartLineTile extends ConsumerWidget {
  const _CartLineTile({required this.line});

  final CartLine line;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final actions = ref.read(cartActionsProvider);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapSm),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ProductThumbnail(url: line.imageUrl, size: 64),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    '${formatTaka(line.unitPrice)} each',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppTheme.gapSm),
                  Row(
                    children: [
                      _QuantityStepper(
                        qty: line.qty,
                        // The ceiling is the seller's stock, so a buyer cannot
                        // build a cart that checkout will refuse. The
                        // authoritative check is still the decrement inside the
                        // checkout transaction (§7.4).
                        max: line.stock ?? line.qty,
                        onChanged: (qty) =>
                            actions.setQuantity(line.productId, qty),
                      ),
                      const Spacer(),
                      Text(
                        formatTaka(line.lineTotal),
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Remove',
              onPressed: () => actions.remove(line.productId),
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
      ),
    );
  }
}

class _QuantityStepper extends StatelessWidget {
  const _QuantityStepper({
    required this.qty,
    required this.max,
    required this.onChanged,
  });

  final int qty;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: qty <= 1 ? 'Remove' : 'One fewer',
            visualDensity: VisualDensity.compact,
            onPressed: () => onChanged(qty - 1),
            icon: Icon(qty <= 1 ? Icons.delete_outline : Icons.remove),
          ),
          Text(
            '$qty',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          IconButton(
            tooltip: qty >= max ? 'No more in stock' : 'One more',
            visualDensity: VisualDensity.compact,
            onPressed: qty >= max ? null : () => onChanged(qty + 1),
            icon: const Icon(Icons.add),
          ),
        ],
      ),
    );
  }
}

/// Lines that cannot be bought as they stand.
///
/// Shown rather than silently dropped. Checkout refuses the whole cart if any
/// line is unavailable — one transaction, all or nothing — so a buyer who was
/// not told would meet a failure with no cause attached to it.
class _ProblemsCard extends ConsumerWidget {
  const _ProblemsCard({required this.problems});

  final List<UnavailableCartItem> problems;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      color: scheme.errorContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.error_outline, color: scheme.onErrorContainer),
                const SizedBox(width: AppTheme.gapSm),
                Expanded(
                  child: Text(
                    problems.length == 1
                        ? '1 item needs attention'
                        : '${problems.length} items need attention',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: scheme.onErrorContainer,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.gapSm),
            for (final problem in problems)
              Padding(
                padding: const EdgeInsets.only(bottom: AppTheme.gapXs),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${problem.title} — ${problem.reason}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onErrorContainer,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: () => ref
                          .read(cartActionsProvider)
                          .remove(problem.productId),
                      child: const Text('Remove'),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// A cart may hold several sellers, but an order carries one (§7.4).
///
/// Said before checkout rather than after, because "this became two orders" is
/// surprising if you first learn it on the receipt.
class _SplitNotice extends StatelessWidget {
  const _SplitNotice({required this.sellerCount});

  /// One order per seller, so this number is both figures at once.
  final int sellerCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      children: [
        Icon(
          Icons.info_outline,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: AppTheme.gapSm),
        Expanded(
          child: Text(
            'Your cart holds items from $sellerCount sellers, so checkout '
            'creates ${orderCount(sellerCount)} — one for each of them, under '
            'a shared reference.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

class _CartFooter extends StatelessWidget {
  const _CartFooter({
    required this.subtotal,
    required this.sellerCount,
    required this.blocked,
  });

  final int subtotal;

  /// Null while the quote is unavailable — the checkout button still works,
  /// because the server is the thing that decides the split anyway.
  final int? sellerCount;

  final bool blocked;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      elevation: 3,
      color: theme.colorScheme.surface,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(AppTheme.gapMd),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppTheme.maxContentWidth,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Subtotal',
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                        Text(
                          formatTaka(subtotal),
                          style: theme.textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: blocked ? null : () => context.push('/checkout'),
                    icon: const Icon(Icons.lock_outline),
                    label: Text(blocked ? 'Fix items first' : 'Checkout'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
