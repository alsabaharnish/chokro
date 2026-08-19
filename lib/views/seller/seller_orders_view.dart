import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/orders_controller.dart';
import '../../core/theme.dart';
import '../../models/order_model.dart';
import '../../services/order_service.dart';
import '../orders/order_card.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';

/// The seller's fulfilment queue (F4.6, F4.8).
///
/// A seller can move an order to `shipped` and then to `delivered`, and no
/// further. `confirmed` belongs to the buyer — a seller who could confirm their
/// own delivery would hold both ends of a two-party confirmation, and the
/// purchase award would rest on nothing. The button simply stops appearing after
/// `delivered`, and `server/src/orders.js` refuses the transition regardless of
/// what any client asks for.
class SellerOrdersView extends ConsumerWidget {
  const SellerOrdersView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ordersAsync = ref.watch(sellerOrdersProvider);
    final open = ref.watch(sellerOpenOrdersProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Orders to fulfil')),
      body: ordersAsync.when(
        loading: () => const ContentLoading(label: 'Loading your orders…'),
        error: (error, _) => ErrorRetry(
          error: error,
          title: 'Your orders',
          onRetry: () => ref.invalidate(sellerOrdersProvider),
        ),
        data: (orders) {
          if (orders.isEmpty) {
            return const ContentEmpty(
              icon: Icons.local_shipping_outlined,
              title: 'No orders yet',
              message:
                  'When a buyer checks out with one of your products, their '
                  'order appears here.',
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
                      if (open.isNotEmpty) ...[
                        _OpenBanner(count: open.length),
                        const SizedBox(height: AppTheme.gapMd),
                      ],
                      for (final order in orders) ...[
                        OrderCard(
                          order: order,
                          viewerIsSeller: true,
                          action:
                              OrderStatus.nextFor(
                                    order.status,
                                    isSeller: true,
                                  ) ==
                                  null
                              ? null
                              : _AdvanceButton(order: order),
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

class _OpenBanner extends StatelessWidget {
  const _OpenBanner({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return Card(
      color: scheme.tertiaryContainer,
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Row(
          children: [
            Icon(Icons.pending_actions, color: scheme.onTertiaryContainer),
            const SizedBox(width: AppTheme.gapMd),
            Expanded(
              child: Text(
                count == 1
                    ? '1 order needs something from you.'
                    : '$count orders need something from you.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onTertiaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdvanceButton extends ConsumerStatefulWidget {
  const _AdvanceButton({required this.order});

  final OrderModel order;

  @override
  ConsumerState<_AdvanceButton> createState() => _AdvanceButtonState();
}

class _AdvanceButtonState extends ConsumerState<_AdvanceButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final next = OrderStatus.nextFor(widget.order.status, isSeller: true);
    if (next == null) return const SizedBox.shrink();

    final label = next == OrderStatus.shipped
        ? 'Mark as shipped'
        : 'Mark as delivered and paid';

    return FilledButton.icon(
      onPressed: _busy ? null : () => _advance(next),
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              next == OrderStatus.shipped
                  ? Icons.local_shipping_outlined
                  : Icons.payments_outlined,
            ),
      label: Text(_busy ? 'Updating…' : label),
    );
  }

  Future<void> _advance(OrderStatus next) async {
    if (next == OrderStatus.delivered) {
      // Delivery is also where cash changes hands (F4.8), so it is worth one
      // confirmation: it records payment as well as arrival, and nothing walks
      // it back.
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Delivered and paid?'),
          content: Text(
            'This records that the buyer has the order and has paid '
            '${widget.order.payable} taka in cash. They then confirm receipt '
            'themselves, which is what closes the order.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Not yet'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delivered'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() => _busy = true);
    try {
      await ref.read(orderActionsProvider).advance(widget.order);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Order marked ${next.label.toLowerCase()}.')),
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
