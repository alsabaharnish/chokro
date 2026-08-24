import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../controllers/orders_controller.dart';
import '../../core/theme.dart';
import '../../models/order_model.dart';
import '../../services/order_service.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';
import 'order_card.dart';

/// The buyer's orders, and the confirmation that closes the cycle (F4.6, F4.7).
///
/// Confirming receipt is the transition that credits `source=purchase` — the
/// fourth ledger source, and the one that makes the earn and spend paths a cycle
/// rather than a pipeline (§7.1). That is why it is a deliberate button with a
/// dialog rather than something that happens on delivery: only the buyer can say
/// the goods arrived, and the award rests on their saying it.
class BuyerOrdersView extends ConsumerWidget {
  const BuyerOrdersView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ordersAsync = ref.watch(buyerOrdersProvider);
    final awaiting = ref.watch(ordersAwaitingConfirmationProvider);

    // Inside `AppShell` — the same stranding as `/appeals`, and on a worse path.
    // The checkout receipt's "View my orders" is a `context.go`, so a Champion
    // who had just paid landed here with an empty stack, no back button and no
    // navigation.
    return AppShell(
      title: 'My orders',
      child: ordersAsync.when(
        loading: () => const ContentLoading(label: 'Loading your orders…'),
        error: (error, _) => ErrorRetry(
          error: error,
          title: 'Your orders',
          onRetry: () => ref.invalidate(buyerOrdersProvider),
        ),
        data: (orders) {
          if (orders.isEmpty) {
            return ContentEmpty(
              icon: Icons.receipt_long_outlined,
              title: 'No orders yet',
              message:
                  'Anything you buy in the shop appears here, with its status '
                  'and what you paid.',
              actionLabel: 'Browse the shop',
              onAction: () => context.go('/market'),
            );
          }

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
                    maxWidth: AppTheme.maxContentWidth,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (awaiting.isNotEmpty) ...[
                        _AwaitingBanner(count: awaiting.length),
                        const SizedBox(height: AppTheme.gapMd),
                      ],
                      for (final order in orders) ...[
                        OrderCard(
                          order: order,
                          viewerIsSeller: false,
                          action: order.status == OrderStatus.delivered
                              ? _ConfirmButton(order: order)
                              : null,
                        ),
                        const SizedBox(height: AppTheme.gapMd),
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

class _AwaitingBanner extends StatelessWidget {
  const _AwaitingBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      color: scheme.secondaryContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Row(
          children: [
            Icon(Icons.inbox_outlined, color: scheme.onSecondaryContainer),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: Text(
                count == 1
                    ? 'One order is waiting for you to confirm receipt. Your '
                          'purchase points are credited when you do.'
                    : '$count orders are waiting for you to confirm receipt. '
                          'Your purchase points are credited when you do.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConfirmButton extends ConsumerStatefulWidget {
  const _ConfirmButton({required this.order});

  final OrderModel order;

  @override
  ConsumerState<_ConfirmButton> createState() => _ConfirmButtonState();
}

class _ConfirmButtonState extends ConsumerState<_ConfirmButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: _busy ? null : _confirm,
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.check_circle_outline),
      label: Text(_busy ? 'Confirming…' : 'Confirm receipt'),
    );
  }

  Future<void> _confirm() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm you received this?'),
        content: const Text(
          'This closes the order and credits your purchase points. It cannot '
          'be undone, so only confirm once the goods are actually with you.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not yet'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Confirm receipt'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final outcome = await ref
          .read(orderActionsProvider)
          .confirm(widget.order);
      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            outcome.pointsAwarded > 0
                ? 'Order closed. ${outcome.pointsAwarded} points credited.'
                // 5% of a small order legitimately rounds down to nothing, and
                // saying so is better than an unexplained silence where the
                // points were expected.
                : 'Order closed. This one was too small to earn points.',
          ),
        ),
      );
    } on OrderException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
