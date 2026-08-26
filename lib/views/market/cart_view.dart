import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/auth_controller.dart';
import '../../controllers/cart_controller.dart';
import '../../core/checkout_math.dart';
import '../../core/label_format.dart';
import '../../core/network_errors.dart';
import '../../core/theme.dart';
import '../../models/cart_model.dart';
import '../shared/content_state.dart';
import '../shared/app_snackbar.dart';
import '../shared/error_retry.dart';
import '../shared/notice_card.dart';
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
    final productsAsync = ref.watch(cartProductsProvider);
    final lines = ref.watch(cartLinesProvider);
    final problems = ref.watch(unavailableCartItemsProvider);
    final quote = ref.watch(checkoutQuoteProvider);
    // The footer's total comes from the lines, not the quote, so a wallet or
    // policy read failing does not take the subtotal down with it.
    final subtotal = ref.watch(cartSubtotalProvider);
    // A suspended buyer got two misleading dead ends on this screen — Checkout
    // teleported them to /home via `requireSignedIn`'s sibling guards, and
    // Remove failed as "you do not have permission to view this", advice that
    // cannot work — while the one fact that explains both was stated only on
    // the product screen one tap away.
    final user = ref.watch(currentUserProvider).value;
    final suspended = user != null && !user.isActive;

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
        error: (error, _) => ErrorRetry(
          error: error,
          title: 'Your cart',
          onRetry: () => ref.invalidate(cartProvider),
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

          return productsAsync.when(
            loading: () => const ContentLoading(
              label: 'Checking current prices and stock…',
            ),
            error: (error, _) => ErrorRetry(
              error: error,
              title: 'Cart prices and stock',
              onRetry: () => ref.invalidate(cartProductsProvider),
            ),
            data: (_) => Column(
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
                              if (suspended) ...[
                                const NoticeCard(
                                  icon: Icons.pause_circle_outline,
                                  tone: NoticeTone.warning,
                                  title: 'Your account is suspended',
                                  message:
                                      'You cannot check out or change this '
                                      'cart until the suspension lifts. '
                                      'Everything in it is kept.',
                                ),
                                const SizedBox(height: AppTheme.gapLg),
                              ],
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
                    blocked: problems.isNotEmpty || suspended,
                    // "Fix items first" is the wrong sentence for a suspension:
                    // there is nothing on this screen to fix.
                    blockedLabel: suspended ? 'Account suspended' : null,
                  ),
              ],
            ),
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
          // Styled destructive, like rejection_reason_dialog.dart. Muscle
          // memory for "the filled button is the safe one" emptied a cart the
          // buyer spent time building, and nothing in the app restores it. The
          // label is spelled out too, so the confirm no longer reads
          // identically to the app-bar button that opened this dialog.
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            child: const Text('Empty the cart'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;
    await _runCartAction(context, () => ref.read(cartActionsProvider).clear());
  }
}

class _CartLineTile extends ConsumerWidget {
  const _CartLineTile({required this.line});

  final CartLine line;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final actions = ref.read(cartActionsProvider);

    final total = Text(
      formatTaka(line.lineTotal),
      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
    );

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapSm),
        child: Column(
          children: [
            Row(
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
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Remove',
                  onPressed: () async {
                    await _runCartAction(
                      context,
                      () => actions.remove(line.productId),
                    );
                  },
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.gapSm),
            LayoutBuilder(
              builder: (context, constraints) {
                final stackControls =
                    constraints.maxWidth < 280 ||
                    MediaQuery.textScalerOf(context).scale(1) > 1.3;
                // Two ceilings apply, and the stepper only knew about one.
                // `CartItem.setQuantity` clamps at `CartItem.maxQty`, so past
                // 20 the "+" stayed enabled, wrote an unchanged cart document
                // to Firestore, and changed nothing on screen — an enabled
                // control that reports no error and produces no change reads as
                // a broken app, and the tooltip said "One more" at the exact
                // point where one more was impossible.
                final stockLimit = line.stock ?? line.qty;
                final stepper = _QuantityStepper(
                  qty: line.qty,
                  max: math.min(stockLimit, CartItem.maxQty),
                  atStockLimit: line.qty >= stockLimit,
                  onChanged: (qty) async {
                    await _runCartAction(
                      context,
                      () => actions.setQuantity(line.productId, qty),
                    );
                  },
                );

                if (stackControls) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(alignment: Alignment.centerLeft, child: stepper),
                      const SizedBox(height: AppTheme.gapSm),
                      Align(alignment: Alignment.centerRight, child: total),
                    ],
                  );
                }

                return Row(children: [stepper, const Spacer(), total]);
              },
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
    required this.atStockLimit,
    required this.onChanged,
  });

  final int qty;
  final int max;

  /// Which of the two ceilings [max] came from, so the disabled tooltip can
  /// name the real reason rather than always blaming stock.
  final bool atStockLimit;

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
            tooltip: qty < max
                ? 'One more'
                : (atStockLimit
                      ? 'No more in stock'
                      : 'Most you can order is ${CartItem.maxQty}'),
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
                      onPressed: () async {
                        await _runCartAction(
                          context,
                          () => ref
                              .read(cartActionsProvider)
                              .remove(problem.productId),
                        );
                      },
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

Future<void> _runCartAction(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (error) {
    if (!context.mounted) return;
    // The cart is the only screen where a *write* denial is user-reachable, and
    // `friendlyErrorMessage` answers for a read: it tells the user to sign out
    // and back in, which cannot help when the real cause is a suspension.
    final denied =
        error is FirebaseException && error.code == 'permission-denied';
    AppSnackBar.of(context).failure(
      denied
          ? 'Your cart cannot be changed right now. If your account is '
                'suspended, that is why.'
          : friendlyErrorMessage(error),
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
            'Your cart holds items from $sellerCount Greenpreneurs, so checkout '
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
    this.blockedLabel,
  });

  final int subtotal;

  /// Null while the quote is unavailable — the checkout button still works,
  /// because the server is the thing that decides the split anyway.
  final int? sellerCount;

  final bool blocked;

  /// What the disabled button should say. Null falls back to the cart-problem
  /// wording, which is what [blocked] originally only ever meant.
  final String? blockedLabel;

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
            heightFactor: 1,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: AppTheme.maxContentWidth,
              ),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final stack =
                      constraints.maxWidth < 420 ||
                      MediaQuery.textScalerOf(context).scale(1) > 1.3;
                  final amount = Column(
                    mainAxisSize: MainAxisSize.min,
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
                  );
                  final checkout = FilledButton.icon(
                    onPressed: blocked ? null : () => context.push('/checkout'),
                    icon: const Icon(Icons.lock_outline),
                    label: Text(
                      blocked
                          ? (blockedLabel ?? 'Fix items first')
                          : 'Checkout',
                    ),
                  );

                  if (stack) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        amount,
                        const SizedBox(height: AppTheme.gapMd),
                        checkout,
                      ],
                    );
                  }

                  return Row(
                    children: [
                      Expanded(child: amount),
                      checkout,
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}
