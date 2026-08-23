import 'package:flutter/material.dart';

import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../models/order_model.dart';

/// One order, from either side of it (F4.6).
///
/// The same card serves the buyer and the seller because they need the same
/// facts — what was bought, for how much, where it has got to — and differ only
/// in which counterparty is worth naming and which action is theirs to take.
/// Two near-identical cards would have drifted apart the way the home screen's
/// eight hand-written rows did.
class OrderCard extends StatelessWidget {
  const OrderCard({
    super.key,
    required this.order,
    required this.viewerIsSeller,
    this.action,
  });

  final OrderModel order;

  /// Which side of the transaction is looking.
  final bool viewerIsSeller;

  /// The one thing this viewer can do next, if anything.
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final counterparty = viewerIsSeller
        ? order.buyerName
        : (order.shopName.isNotEmpty ? order.shopName : order.sellerName);

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(AppTheme.gapMd),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  viewerIsSeller
                      ? Icons.person_outline
                      : Icons.storefront_outlined,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppTheme.gapSm),
                Expanded(
                  child: Text(
                    counterparty,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                OrderStatusChip(status: order.status),
              ],
            ),
            const SizedBox(height: AppTheme.gapXs),
            Text(
              '${formatAge(order.createdAt)} · ${itemCount(order.itemCount)}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),

            const Divider(height: AppTheme.gapLg),

            for (final line in order.items)
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

            const SizedBox(height: AppTheme.gapSm),

            if (order.pointsApplied > 0)
              _Row(
                label: 'Points applied (${order.pointsApplied} pts)',
                value: '-${formatTaka(order.discount)}',
                muted: true,
              ),
            _Row(
              label: order.paymentStatus == PaymentStatus.paid
                  ? 'Paid — ${order.settlementMethod.label.toLowerCase()}'
                  : 'Due on ${order.settlementMethod.label.toLowerCase()}',
              value: formatTaka(order.payable),
              strong: true,
            ),
            if (order.paymentReference != null)
              _Row(
                label: 'Simulation reference',
                value: order.paymentReference!,
                muted: true,
              ),

            if (order.status.isConfirmed && order.pointsAwarded != null) ...[
              const SizedBox(height: AppTheme.gapXs),
              _Row(
                label: 'Purchase points credited',
                value: signedPoints(order.pointsAwarded!),
                muted: true,
              ),
            ],

            const SizedBox(height: AppTheme.gapSm),
            Text(
              // Written for the buyer. A seller reading "confirm to collect
              // your points" would be told about somebody else's award, so the
              // seller gets the state name and the action button instead.
              viewerIsSeller
                  ? _sellerDescription(order)
                  : order.status.buyerDescription,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),

            if (action != null) ...[
              const SizedBox(height: AppTheme.gapMd),
              action!,
            ],
          ],
        ),
      ),
    );
  }

  static String _sellerDescription(OrderModel order) {
    switch (order.status) {
      case OrderStatus.pending:
        return 'Waiting for you to send it.';
      case OrderStatus.shipped:
        return order.paymentStatus == PaymentStatus.paid
            ? 'On its way and already recorded as paid. Mark it delivered once '
                  'the Champion has it.'
            : 'On its way. Mark it delivered once the Champion has it and has '
                  'paid.';
      case OrderStatus.delivered:
        return 'Waiting for the Champion to confirm. Only they can close it.';
      case OrderStatus.confirmed:
        return 'The Champion confirmed receipt. This order is complete.';
    }
  }
}

/// The four order states, rendered.
///
/// Exhaustive over the enum with no fallback, exactly like [StatusChip] for
/// disposals: an unrecognised wire value is already resolved to
/// [OrderStatus.pending] at the parse boundary, and one fallback in one place is
/// the rule.
class OrderStatusChip extends StatelessWidget {
  const OrderStatusChip({super.key, required this.status});

  final OrderStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    final (
      Color foreground,
      Color background,
      IconData icon,
    ) = switch (status) {
      OrderStatus.pending => (
        scheme.onSurfaceVariant,
        scheme.surfaceContainerHighest,
        Icons.inventory_2_outlined,
      ),
      OrderStatus.shipped => (
        scheme.onTertiaryContainer,
        scheme.tertiaryContainer,
        Icons.local_shipping_outlined,
      ),
      OrderStatus.delivered => (
        scheme.onSecondaryContainer,
        scheme.secondaryContainer,
        Icons.inbox_outlined,
      ),
      OrderStatus.confirmed => (
        scheme.onPrimaryContainer,
        scheme.primaryContainer,
        Icons.verified_outlined,
      ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: foreground),
          const SizedBox(width: 5),
          Text(
            status.label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({
    required this.label,
    required this.value,
    this.strong = false,
    this.muted = false,
  });

  final String label;
  final String value;
  final bool strong;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    var style = strong
        ? theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800)
        : theme.textTheme.bodyMedium;
    if (muted) {
      style = theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: Text(label, style: style)),
          const SizedBox(width: AppTheme.gapSm),
          Flexible(
            child: Text(value, textAlign: TextAlign.end, style: style),
          ),
        ],
      ),
    );
  }
}
