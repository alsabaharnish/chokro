import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/cart_controller.dart';
import '../../controllers/orders_controller.dart';
import '../../controllers/points_policy_controller.dart';
import '../../core/checkout_math.dart';
import '../../core/label_format.dart';
import '../../core/network_errors.dart';
import '../../core/theme.dart';
import '../../models/order_model.dart';
import '../../services/order_service.dart';
import '../shared/content_state.dart';
import '../shared/prototype_payment_dialog.dart';

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
  SettlementMethod _settlementMethod = SettlementMethod.cashOnDelivery;

  @override
  Widget build(BuildContext context) {
    final quote = ref.watch(checkoutQuoteProvider);
    final policyAsync = ref.watch(pointsPolicyProvider);
    final balanceAsync = ref.watch(spendableBalanceProvider);

    final receipt = _receipt;

    return Scaffold(
      appBar: AppBar(
        title: Text(receipt == null ? 'Checkout' : 'Order placed'),
        automaticallyImplyLeading: receipt == null,
      ),
      body: receipt != null
          ? _Receipt(outcome: receipt)
          : policyAsync.when(
              loading: () => const ContentLoading(
                label: 'Reading the points policy…',
                slowHint: ContentLoading.serverWakingHint,
              ),
              // "Try again in a moment" with only a "Back to cart" button was a
              // promise the screen did not keep: the provider holds its error,
              // so returning to checkout showed the same message again and the
              // buyer had no way to re-attempt the read short of restarting the
              // app. The retry now actually re-runs it.
              error: (error, _) => _CheckoutUnavailable(
                title: 'The points policy did not load',
                message:
                    'Checkout needs the redemption rate before it can show you '
                    'a total. Nothing has been ordered or charged.',
                onRetry: () => ref.invalidate(pointsPolicyProvider),
              ),
              data: (_) {
                // The balance is checked before the quote, because a failed
                // wallet read used to reach here as a confident zero — slider
                // capped at nothing, no error, and a buyer told they had no
                // points to spend. `checkoutQuoteProvider` now yields null
                // rather than assuming, so this branch has to say which.
                if (balanceAsync.hasError) {
                  return _CheckoutUnavailable(
                    title: 'Your balance did not load',
                    message:
                        'Checkout needs it before it can show what your points '
                        'are worth on this order. Nothing has been ordered or '
                        'charged.',
                    onRetry: () => ref.invalidate(spendableBalanceProvider),
                  );
                }
                if (balanceAsync.isLoading || quote == null) {
                  return const ContentLoading(label: 'Reading your balance…');
                }

                if (quote.isEmpty) {
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
                  settlementMethod: _settlementMethod,
                  onSettlementChanged: (method) {
                    setState(() => _settlementMethod = method);
                  },
                  onPlace: _place,
                );
              },
            ),
    );
  }

  Future<void> _place(CheckoutQuote quote) async {
    if (_settlementMethod.isPrototype) {
      final approved = await showPrototypePaymentDialog(
        context: context,
        method: _settlementMethod,
        amountTaka: quote.payable,
        purpose: orderCount(quote.orderCount),
      );
      if (!approved || !mounted) return;
    }

    setState(() => _placing = true);
    try {
      final outcome = await ref
          .read(orderActionsProvider)
          .checkout(
            pointsRequested: quote.pointsApplied,
            settlementMethod: _settlementMethod,
          );

      if (!mounted) return;
      setState(() => _receipt = outcome);
    } on OrderException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } catch (error) {
      if (!mounted) return;
      // Anything that is not an OrderException reaching here is a Firestore or
      // platform error, and its `toString()` names a vendor and a code rather
      // than anything the buyer can act on.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Your order could not be placed. ${friendlyErrorMessage(error)}',
          ),
        ),
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
    required this.settlementMethod,
    required this.onSettlementChanged,
    required this.onPlace,
  });

  final CheckoutQuote quote;
  final bool placing;
  final SettlementMethod settlementMethod;
  final ValueChanged<SettlementMethod> onSettlementChanged;
  final Future<void> Function(CheckoutQuote) onPlace;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final policy = ref.watch(pointsPolicyProvider).asData?.value;
    // Resolved by the parent before this widget is built, so `?? 0` here is a
    // type formality rather than the silent assumption it used to be.
    final balance = ref.watch(spendableBalanceProvider).asData?.value ?? 0;

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
                      _SettlementCard(
                        method: settlementMethod,
                        enabled: !placing,
                        onChanged: onSettlementChanged,
                      ),

                      const SizedBox(height: AppTheme.gapMd),
                      _TotalsCard(
                        quote: quote,
                        settlementMethod: settlementMethod,
                      ),

                      const SizedBox(height: AppTheme.gapMd),
                      Text(
                        'Totals are recalculated by the server from the '
                        'Greenpreneurs’ stored prices when you place the order. '
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
                          : settlementMethod.isPrototype
                          ? 'Pay ${formatTaka(quote.payable)} with '
                                '${settlementMethod.shortLabel} (prototype)'
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
                    group.shopName.isEmpty
                        ? 'A 3ZERO Greenpreneur'
                        : group.shopName,
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
                    'Payable to this Greenpreneur',
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
                // At most a hundred notches, because a slider with six hundred
                // of them is not a control anybody can aim.
                divisions: (cap ~/ pointsPerTaka).clamp(1, 100),
                label: '${quote.pointsApplied} pts',
                // Snapped to a whole-taka block on the way in, NOT left to the
                // divisions.
                //
                // The clamp above means a notch is only worth one taka while
                // the cap is at most a hundred taka's worth of points. Above
                // that a notch is `cap / 100` points, which need not be a
                // multiple of `pointsPerTaka` — so the buyer released the thumb
                // on 347 points, `applyRedemption` floored it to 340, and the
                // label said 340 while the thumb sat somewhere else. Rounding
                // down here makes every value this control can produce one the
                // policy will accept unchanged.
                onChanged: (value) => ref
                    .read(checkoutPointsProvider.notifier)
                    .set((value.round() ~/ pointsPerTaka) * pointsPerTaka),
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
/// Cash remains available; online options are explicitly simulated.
class _SettlementCard extends StatelessWidget {
  const _SettlementCard({
    required this.method,
    required this.enabled,
    required this.onChanged,
  });

  final SettlementMethod method;
  final bool enabled;
  final ValueChanged<SettlementMethod> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppTheme.gapSm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.gapMd,
                AppTheme.gapSm,
                AppTheme.gapMd,
                AppTheme.gapXs,
              ),
              child: Text(
                'Payment method',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            RadioGroup<SettlementMethod>(
              groupValue: method,
              onChanged: (value) {
                if (value != null && enabled) onChanged(value);
              },
              child: Column(
                children: [
                  for (final option in SettlementMethod.values)
                    RadioListTile<SettlementMethod>(
                      value: option,
                      enabled: enabled,
                      secondary: Icon(_paymentIcon(option)),
                      title: Text(option.label),
                      subtitle: Text(
                        option.isPrototype
                            ? 'Simulation only — no real money or payment details.'
                            : 'Pay the Greenpreneur when the order arrives.',
                      ),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AppTheme.gapMd,
                AppTheme.gapXs,
                AppTheme.gapMd,
                AppTheme.gapSm,
              ),
              child: Text(
                'Prototype options never ask for card, PIN, OTP, or wallet details.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static IconData _paymentIcon(SettlementMethod method) => switch (method) {
    SettlementMethod.cashOnDelivery => Icons.payments_outlined,
    SettlementMethod.prototypeBkash => Icons.phone_android_outlined,
    SettlementMethod.prototypeNagad => Icons.smartphone_outlined,
    SettlementMethod.prototypeCard => Icons.credit_card_outlined,
  };
}

class _TotalsCard extends StatelessWidget {
  const _TotalsCard({required this.quote, required this.settlementMethod});

  final CheckoutQuote quote;
  final SettlementMethod settlementMethod;

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
            row(
              settlementMethod.isPrototype
                  ? 'Prototype payment'
                  : 'Payable on delivery',
              formatTaka(quote.payable),
              strong: true,
            ),
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
                      ? 'The Greenpreneur has it and will send it to you.'
                      : 'One for each Greenpreneur in your cart, under a shared '
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
                          label: outcome.paymentStatus == PaymentStatus.paid
                              ? 'Prototype payment recorded'
                              : 'Due on delivery',
                          value: formatTaka(outcome.payable),
                          strong: true,
                        ),
                        _ReceiptRow(
                          label: 'Payment method',
                          value: outcome.settlementMethod.label,
                        ),
                        if (outcome.paymentReference != null)
                          _ReceiptRow(
                            label: 'Simulation reference',
                            value: outcome.paymentReference!,
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
                  outcome.settlementMethod.isPrototype
                      ? 'This payment is a simulation; no real money moved. '
                            'Confirm receipt when the order arrives to collect '
                            'purchase points and close the order.'
                      : 'Confirm receipt when the order arrives — that is what '
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: AppTheme.gapMd),
          Flexible(
            child: Text(value, textAlign: TextAlign.end, style: style),
          ),
        ],
      ),
    );
  }
}

/// A checkout read that failed, with both ways out of it.
///
/// Checkout cannot show a total until the points policy and the wallet balance
/// have both been read, so a failure in either has to stop the screen. What it
/// must not do is strand the buyer: these two branches previously offered only
/// "Back to cart" while their own text said "Try again in a moment", and since
/// the providers retain their error, coming back to checkout produced the same
/// dead end. Retry is the primary action because a failed read here is almost
/// always the trusted service still waking.
class _CheckoutUnavailable extends StatelessWidget {
  const _CheckoutUnavailable({
    required this.title,
    required this.message,
    required this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(AppTheme.gapXl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.cloud_off_outlined,
                size: 40,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: AppTheme.gapMd),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: AppTheme.gapSm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: AppTheme.gapLg),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
              const SizedBox(height: AppTheme.gapSm),
              TextButton(
                onPressed: () => context.pop(),
                child: const Text('Back to cart'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
