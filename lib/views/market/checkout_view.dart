import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/cart_controller.dart';
import '../../controllers/ledger_controller.dart';
import '../../controllers/orders_controller.dart';
import '../../controllers/points_policy_controller.dart';
import '../../controllers/wallet_controller.dart';
import '../../core/checkout_math.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../models/order_model.dart';
import '../../services/order_service.dart';
import '../shared/content_state.dart';

/// Checkout (F4.4, F4.5, F4.8).
///
/// ## Every figure on this screen is a preview
///
/// The totals come from `lib/core/checkout_math.dart` over prices read a moment
/// ago. `server/src/checkout.js` recomputes all of them inside the transaction
/// that actually charges the buyer, and its answer is the one that counts. That
/// is why the receipt below reports the server's figures rather than repeating
/// what was shown here: if the two ever differ, the buyer sees the difference
/// instead of a confident wrong number.
///
/// ## Why points are a slider and not a text field
///
/// Points are spent in whole-taka blocks — 10 points buys ৳1 with the default
/// policy — and are capped at half the subtotal and at the wallet balance. A
/// free-text field would invite figures that all three rules then quietly
/// change. The slider can only produce values the policy already accepts.
class CheckoutView extends ConsumerStatefulWidget {
  const CheckoutView({super.key});

  @override
  ConsumerState<CheckoutView> createState() => _CheckoutViewState();
}

class _CheckoutViewState extends ConsumerState<CheckoutView> {
  bool _placing = false;
  CheckoutOutcome? _receipt;

  @override
  Widget build(BuildContext context) {
    final quote = ref.watch(checkoutQuoteProvider);
    final policyAsync = ref.watch(pointsPolicyProvider);

    final receipt = _receipt;

    return Scaffold(
      appBar: AppBar(
        title: Text(receipt == null ? 'Checkout' : 'Order placed'),
        automaticallyImplyLeading: receipt == null,
      ),
      body: receipt != null
          ? _Receipt(outcome: receipt)
          : policyAsync.when(
              loading: () =>
                  const ContentLoading(label: 'Reading the points policy…'),
              error: (error, _) => ContentEmpty(
                icon: Icons.cloud_off_outlined,
                title: 'The points policy did not load',
                message:
                    'Checkout needs the redemption rate before it can show you '
                    'a total. Try again in a moment.',
                actionLabel: 'Back to cart',
                onAction: () => context.pop(),
              ),
              data: (_) {
                if (quote == null || quote.isEmpty) {
                  return ContentEmpty(
                    icon: Icons.shopping_cart_outlined,
                    title: 'Nothing to check out',
                    message: 'Your cart is empty.',
                    actionLabel: 'Browse the shop',
                    onAction: () => context.go('/market'),
                  );
                }
                return _CheckoutBody(
                  quote: quote,
                  placing: _placing,
                  onPlace: _place,
                );
              },
            ),
    );
  }

  Future<void> _place(CheckoutQuote quote) async {
    setState(() => _placing = true);
    try {
      final outcome = await ref
          .read(orderActionsProvider)
          .checkout(pointsRequested: quote.pointsApplied);

      if (!mounted) return;
      setState(() => _receipt = outcome);
    } on OrderException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Your order could not be placed. $error')),
      );
    } finally {
      if (mounted) setState(() => _placing = false);
    }
  }
}

class _CheckoutBody extends ConsumerWidget {
  const _CheckoutBody({
    required this.quote,
    required this.placing,
    required this.onPlace,
  });

  final CheckoutQuote quote;
  final bool placing;
  final Future<void> Function(CheckoutQuote) onPlace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final policy = ref.watch(pointsPolicyProvider).asData?.value;
    final balance =
        ref.watch(ledgerBalanceProvider) ??
        ref.watch(walletProvider).asData?.value?.balance ??
        0;

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
                      for (final group in quote.groups) ...[
                        _SellerGroupCard(group: group),
                        const SizedBox(height: AppTheme.gapMd),
                      ],

                      const SizedBox(height: AppTheme.gapSm),
                      _PointsCard(
                        quote: quote,
                        balance: balance,
                        pointsPerTaka: policy?.pointsPerTaka ?? 10,
                      ),

                      const SizedBox(height: AppTheme.gapMd),
                      const _SettlementCard(),

                      const SizedBox(height: AppTheme.gapMd),
                      _TotalsCard(quote: quote),

                      const SizedBox(height: AppTheme.gapMd),
                      Text(
                        'Totals are recalculated by the server from the '
                        'sellers’ stored prices when you place the order. '
                        'If anything has changed in the meantime you will be '
                        'told rather than charged the old figure.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Material(
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
                  child: FilledButton.icon(
                    onPressed: placing ? null : () => onPlace(quote),
                    icon: placing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_circle_outline),
                    label: Text(
                      placing
                          ? 'Placing your order…'
                          : 'Place ${orderCount(quote.orderCount)} · '
                                '${formatTaka(quote.payable)} on delivery',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// One seller's share of the checkout, which becomes exactly one order (§7.4).
class _SellerGroupCard extends StatelessWidget {
  const _SellerGroupCard({required this.group});

  final SellerGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.storefront_outlined, size: 18),
                const SizedBox(width: AppTheme.gapSm),
                Expanded(
                  child: Text(
                    group.shopName.isEmpty ? 'A seller' : group.shopName,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const Divider(),
            for (final line in group.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${line.qty} × ${line.title}',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      formatTaka(line.lineTotal),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
            if (group.discount > 0) ...[
              const SizedBox(height: AppTheme.gapXs),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Points applied to this order '
                      '(${group.pointsApplied} pts)',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Text(
                    '-${formatTaka(group.discount)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ],
            const Divider(),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Payable to this seller',
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                Text(
                  formatTaka(group.payable),
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The redemption control (F4.5).
class _PointsCard extends ConsumerWidget {
  const _PointsCard({
    required this.quote,
    required this.balance,
    required this.pointsPerTaka,
  });

  final CheckoutQuote quote;
  final int balance;
  final int pointsPerTaka;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final cap = quote.maxRedeemablePoints;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.savings_outlined, color: scheme.primary),
                const SizedBox(width: AppTheme.gapSm),
                Expanded(
                  child: Text(
                    'Pay with points',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '$balance available',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppTheme.gapSm),
            if (cap == 0)
              Text(
                balance == 0
                    ? 'You have no points yet. Dispose waste at a registered '
                          'bin to earn some.'
                    : 'This order is too small to spend points on — points buy '
                          'whole taka, up to half the order.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              )
            else ...[
              Slider(
                value: quote.pointsApplied.toDouble().clamp(0, cap.toDouble()),
                max: cap.toDouble(),
                // One notch per whole taka, so the slider cannot land on a
                // figure the policy would round away underneath the buyer.
                divisions: (cap ~/ pointsPerTaka).clamp(1, 100),
                label: '${quote.pointsApplied} pts',
                onChanged: (value) => ref
                    .read(checkoutPointsProvider.notifier)
                    .set(value.round()),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      quote.pointsApplied == 0
                          ? 'Spend up to $cap points on this order.'
                          : '${quote.pointsApplied} points → '
                                '${formatTaka(quote.discount)} off',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.read(checkoutPointsProvider.notifier).none(),
                    child: const Text('None'),
                  ),
                  TextButton(
                    onPressed: () =>
                        ref.read(checkoutPointsProvider.notifier).max(cap),
                    child: const Text('Max'),
                  ),
                ],
              ),
              Text(
                'Points cover at most half an order, and are spent in whole '
                'taka — $pointsPerTaka points to ৳1.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Settlement (F4.8).
///
/// One option, stated rather than assumed. §6.2 forbids storing card data in any
/// schema, so cash on delivery is the whole payment design and the receipt
/// should say so.
class _SettlementCard extends StatelessWidget {
  const _SettlementCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: const Icon(Icons.payments_outlined),
        title: Text(
          SettlementMethod.cashOnDelivery.label,
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: const Text(
          'You pay the seller when the order arrives. Chokro stores no card '
          'details.',
        ),
        trailing: const Icon(Icons.check_circle, size: 20),
      ),
    );
  }
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.quote});

  final CheckoutQuote quote;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    Widget row(String label, String value, {bool strong = false}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: strong
                  ? theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    )
                  : theme.textTheme.bodyMedium,
            ),
          ),
          Text(
            value,
            style: strong
                ? theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  )
                : theme.textTheme.bodyMedium,
          ),
        ],
      ),
    );

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          children: [
            row('Subtotal', formatTaka(quote.subtotal)),
            if (quote.pointsApplied > 0)
              row(
                'Points (${quote.pointsApplied} pts)',
                '-${formatTaka(quote.discount)}',
              ),
            const Divider(),
            row('Payable on delivery', formatTaka(quote.payable), strong: true),
          ],
        ),
      ),
    );
  }
}

/// What the server actually did.
///
/// Reports the server's figures rather than the ones the buyer was shown. They
/// are almost always the same; when they are not, the difference is the point.
class _Receipt extends ConsumerWidget {
  const _Receipt({required this.outcome});

  final CheckoutOutcome outcome;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return ListView(
      padding: const EdgeInsets.all(AppTheme.gapLg),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: AppTheme.maxFormWidth),
            child: Column(
              children: [
                Icon(Icons.check_circle, size: 56, color: scheme.primary),
                const SizedBox(height: AppTheme.gapMd),
                Text(
                  outcome.orderCount == 1
                      ? 'Your order is placed'
                      : '${outcome.orderCount} orders placed',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: AppTheme.gapSm),
                Text(
                  outcome.orderCount == 1
                      ? 'The seller has it and will send it to you.'
                      : 'One for each seller in your cart, under a shared '
                            'reference.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),

                const SizedBox(height: AppTheme.gapLg),
                Card(
                  margin: EdgeInsets.zero,
                  child: Padding(
                    padding: const EdgeInsets.all(AppTheme.gapMd),
                    child: Column(
                      children: [
                        _ReceiptRow(
                          label: 'Subtotal',
                          value: formatTaka(outcome.subtotal),
                        ),
                        if (outcome.pointsApplied > 0)
                          _ReceiptRow(
                            label: 'Points spent',
                            value:
                                '${outcome.pointsApplied} pts '
                                '(-${formatTaka(outcome.discount)})',
                          ),
                        const Divider(),
                        _ReceiptRow(
                          label: 'Due on delivery',
                          value: formatTaka(outcome.payable),
                          strong: true,
                        ),
                        if (outcome.balanceAfter != null)
                          _ReceiptRow(
                            label: 'Points balance',
                            value: '${outcome.balanceAfter}',
                          ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: AppTheme.gapLg),
                Text(
                  'Confirm receipt when the order arrives — that is what '
                  'credits your purchase points and closes the order.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.45,
                  ),
                ),

                const SizedBox(height: AppTheme.gapLg),
                FilledButton.icon(
                  onPressed: () => context.go('/orders'),
                  icon: const Icon(Icons.receipt_long_outlined),
                  label: const Text('View my orders'),
                ),
                const SizedBox(height: AppTheme.gapSm),
                TextButton(
                  onPressed: () => context.go('/market'),
                  child: const Text('Keep shopping'),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ReceiptRow extends StatelessWidget {
  const _ReceiptRow({
    required this.label,
    required this.value,
    this.strong = false,
  });

  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = strong
        ? theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)
        : theme.textTheme.bodyMedium;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text(value, style: style),
        ],
      ),
    );
  }
}
