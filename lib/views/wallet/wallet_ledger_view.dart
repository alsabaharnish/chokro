import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../controllers/ledger_controller.dart';
import '../../controllers/wallet_controller.dart';
import '../../core/constants.dart';
import '../../core/label_format.dart';
import '../../core/theme.dart';
import '../../models/transaction_model.dart';
import '../shared/app_shell.dart';
import '../shared/content_state.dart';
import '../shared/error_retry.dart';

/// The wallet, told as a ledger (F3.2, NFR-4).
///
/// The balance in the header is the newest entry's `balanceAfter`, not a
/// separate read of `wallets/{uid}`. Every balance change on this screen sits
/// next to the entry that explains it, which is NFR-4 made visible rather than
/// merely asserted.
class WalletLedgerView extends ConsumerWidget {
  const WalletLedgerView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(ledgerProvider);
    final balance = ref.watch(ledgerBalanceProvider);
    final earned = ref.watch(recentEarnedProvider);

    return AppShell(
      title: 'Wallet',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: AppTheme.maxContentWidth),
          child: async.when(
            loading: () => const ContentLoading(label: 'Loading your wallet…'),
            error: (error, _) => ErrorRetry(
              title: 'The ledger',
              error: error,
              onRetry: () => ref.invalidate(ledgerProvider),
            ),
            data: (page) => RefreshIndicator(
              onRefresh: () async {
                try {
                  // The wallet document is the fallback for an empty or legacy
                  // ledger. Refresh both sources so pull-to-refresh never
                  // leaves that fallback stale.
                  ref.invalidate(walletProvider);
                  final refresh = ref.refresh(ledgerProvider.future);
                  await refresh;
                } catch (_) {
                  // The provider retains the error and the screen renders it.
                }
              },
              child: ListView(
                // A short or empty ledger still needs to accept the pull
                // gesture; otherwise the visible refresh affordance appears
                // dead precisely for a new account waiting on its first entry.
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  _BalanceHeader(balance: balance, recentEarned: earned),
                  const SizedBox(height: 20),
                  Text(
                    'Activity',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (page.entries.isEmpty)
                    const _LedgerEmpty()
                  else
                    ...page.entries.map((e) => _LedgerRow(entry: e)),
                  if (page.truncated) ...[
                    const SizedBox(height: AppTheme.gapMd),
                    OutlinedButton.icon(
                      onPressed: () =>
                          ref.read(ledgerLimitProvider.notifier).loadOlder(),
                      icon: const Icon(Icons.expand_more),
                      label: const Text(
                        'Load ${QueryLimits.ledger} older changes',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BalanceHeader extends StatelessWidget {
  const _BalanceHeader({required this.balance, required this.recentEarned});

  final int? balance;
  final int recentEarned;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Balance',
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onPrimaryContainer,
              letterSpacing: 0.6,
            ),
          ),
          const SizedBox(height: 4),
          Semantics(
            label: balance == null
                ? 'Balance is loading'
                : 'Balance: $balance points',
            child: ExcludeSemantics(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      balance?.toString() ?? '—',
                      style: theme.textTheme.displaySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'points',
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            balance == null
                ? 'Checking your current balance…'
                : recentEarned > 0
                ? '+$recentEarned earned across the entries below'
                : 'Every change to this number is listed below.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onPrimaryContainer.withValues(
                alpha: 0.8,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LedgerRow extends StatelessWidget {
  const _LedgerRow({required this.entry});

  final TransactionModel entry;

  IconData get _icon {
    switch (entry.source) {
      case TransactionSource.disposal:
        return Icons.recycling_outlined;
      case TransactionSource.purchase:
        return Icons.storefront_outlined;
      case TransactionSource.claim:
        return Icons.eco_outlined;
      case TransactionSource.redemption:
        return Icons.shopping_bag_outlined;
      case TransactionSource.donation:
        return Icons.volunteer_activism_outlined;
      case TransactionSource.unknown:
        return Icons.receipt_long_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final credit = entry.isCredit;
    final amountColour = credit
        ? theme.colorScheme.primary
        : theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              shape: BoxShape.circle,
            ),
            child: Icon(
              _icon,
              size: 19,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.source.label,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    entry.source.description,
                    formatDateTime(entry.createdAt),
                  ].where((s) => s.isNotEmpty).join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                entry.signedDelta,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: amountColour,
                ),
              ),
              if (entry.balanceAfter != null)
                Text(
                  'balance ${entry.balanceAfter}',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LedgerEmpty extends StatelessWidget {
  const _LedgerEmpty();

  @override
  Widget build(BuildContext context) {
    return const ContentEmpty(
      icon: Icons.receipt_long_outlined,
      title: 'Your wallet is ready',
      message:
          'Approved submissions will appear here with the points they '
          'earned and your balance after each change.',
    );
  }
}

// The private error widget here was replaced by the shared `ErrorRetry`.
//
// Four screens had grown the same icon-title-detail-retry layout, and all four
// printed the raw exception as the detail — `'$error'` renders as
// `[cloud_firestore/permission-denied] Missing or insufficient permissions.`
// `ErrorRetry` interprets it through `friendlyErrorMessage` instead.
