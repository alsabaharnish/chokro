import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/orders_controller.dart';
import '../../core/constants.dart';
import '../../core/theme.dart';
import '../../models/order_model.dart';
import '../../services/order_service.dart';
import '../orders/order_card.dart';
import '../shared/app_shell.dart';
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

    // Inside `AppShell` — see the note in `seller_products_view.dart`. The
    // "Switch to 3ZERO Champion" action that used to be the only way off this
    // screen is now the shell's account menu, which switches profile because
    // the user asked to rather than because they wanted to leave.
    return AppShell(
      title: 'Your orders',
      child: ordersAsync.when(
        loading: () => const ContentLoading(label: 'Loading your orders…'),
        error: (error, _) => ErrorRetry(
          error: error,
          title: 'Your orders',
          onRetry: () => ref.invalidate(sellerOrdersProvider),
        ),
        data: (page) {
          final orders = page.orders;
          if (orders.isEmpty) {
            return const ContentEmpty(
              icon: Icons.local_shipping_outlined,
              title: 'No orders yet',
              message:
                  'When a Champion checks out with one of your products, their '
                  'order appears here.',
            );
          }

          final headerCount = open.isNotEmpty ? 1 : 0;
          final footerCount = page.truncated ? 1 : 0;

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.gapMd,
              AppTheme.gapMd,
              AppTheme.gapMd,
              AppTheme.gapXl,
            ),
            itemCount: orders.length + headerCount + footerCount,
            itemBuilder: (context, index) {
              Widget child;
              if (headerCount == 1 && index == 0) {
                child = _OpenBanner(
                  count: open.length,
                  moreOrdersExist: page.truncated,
                );
              } else {
                final orderIndex = index - headerCount;
                if (orderIndex == orders.length) {
                  child = OutlinedButton.icon(
                    onPressed: () =>
                        ref.read(sellerOrderLimitProvider.notifier).loadOlder(),
                    icon: const Icon(Icons.expand_more),
                    label: const Text(
                      'Load ${QueryLimits.orders} older orders',
                    ),
                  );
                } else {
                  final order = orders[orderIndex];
                  child = OrderCard(
                    key: ValueKey(order.id),
                    order: order,
                    viewerIsSeller: true,
                    action:
                        OrderStatus.nextFor(order.status, isSeller: true) ==
                            null
                        ? null
                        : _AdvanceButton(order: order),
                  );
                }
              }
              return Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: AppTheme.maxContentWidth,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: AppTheme.gapMd),
                    child: child,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _OpenBanner extends StatelessWidget {
  const _OpenBanner({required this.count, required this.moreOrdersExist});

  final int count;
  final bool moreOrdersExist;

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
                moreOrdersExist
                    ? count == 1
                          ? 'At least 1 loaded order needs something from you. '
                                'Load older orders to check the rest.'
                          : 'At least $count loaded orders need something from '
                                'you. Load older orders to check the rest.'
                    : count == 1
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
        : widget.order.paymentStatus == PaymentStatus.paid
        ? 'Mark as delivered'
        : 'Mark as delivered and paid';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
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
        ),
        if (_busy) const SlowServerNote(),
      ],
    );
  }

  Future<void> _advance(OrderStatus next) async {
    if (next == OrderStatus.delivered) {
      final alreadyPaid = widget.order.paymentStatus == PaymentStatus.paid;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(alreadyPaid ? 'Delivered?' : 'Delivered and paid?'),
          content: Text(
            alreadyPaid
                ? 'This order is already recorded as paid through a prototype '
                      'online payment. Confirm that the Champion now has it. '
                      'They will close the order themselves.'
                : 'This records that the Champion has the order and has paid '
                      '${widget.order.payable} taka in cash. They then confirm '
                      'receipt themselves, which is what closes the order.',
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
