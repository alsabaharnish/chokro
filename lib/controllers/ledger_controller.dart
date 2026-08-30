import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/constants.dart';
import '../models/transaction_model.dart';
import '../services/transaction_service.dart';
import 'current_user_provider.dart';
import 'wallet_controller.dart';

final transactionServiceProvider = Provider<TransactionService>((ref) {
  return TransactionService();
});

class LedgerLimitController extends Notifier<int> {
  @override
  int build() => QueryLimits.ledger;

  void loadOlder() => state += QueryLimits.ledger;
}

/// How many of the newest ledger entries the wallet currently asks for.
///
/// Riverpod providers auto-dispose in this project, so leaving the wallet puts
/// the next visit back at one inexpensive page instead of retaining an ever
/// growing live query for the rest of the session.
final ledgerLimitProvider =
    NotifierProvider.autoDispose<LedgerLimitController, int>(
      LedgerLimitController.new,
    );

/// The signed-in user's bounded ledger page, newest first.
///
/// Emits an empty list rather than an error when signed out, so a sign-out
/// mid-session tears the screen down cleanly instead of flashing an error.
final ledgerProvider = StreamProvider.autoDispose<TransactionPage>((ref) {
  final uid = ref.watch(currentUidProvider);
  final limit = ref.watch(ledgerLimitProvider);
  if (uid == null) {
    return Stream<TransactionPage>.value(
      const TransactionPage(entries: <TransactionModel>[], truncated: false),
    );
  }
  return ref
      .watch(transactionServiceProvider)
      .watchUserTransactions(uid, limit: limit);
});

/// Balance taken from the newest ledger entry's `balanceAfter`.
///
/// Deliberately derived from the ledger rather than read from `wallets/{uid}`.
/// NFR-4 says the balance must be reconstructable from history; showing the
/// user a number that comes out of the history is that property made visible,
/// and it means this screen has exactly one data dependency.
///
/// Null only while the ledger is still loading. An empty ledger, or a newest
/// entry that carries no `balanceAfter`, falls back to `wallets/{uid}`.
///
/// The fallback is not decoration. This doc comment used to promise it and the
/// screen did not have it: `_BalanceHeader` rendered `balance?.toString() ??
/// '0'`, so a single newest entry without a `balanceAfter` — a legacy row, or
/// a document that failed to parse — showed a Champion with points a balance
/// of **0**, next to a ledger visibly full of credits. Of everything in this
/// app, the balance is the number a user is least willing to see wrong, and
/// the authoritative figure was one provider away the whole time.
final ledgerBalanceProvider = Provider.autoDispose<int?>((ref) {
  final ledger = ref.watch(ledgerProvider);
  if (ledger.isLoading && !ledger.hasValue) return null;

  final entries = ledger.asData?.value.entries;
  final fromLedger = (entries == null || entries.isEmpty)
      ? null
      : entries.first.balanceAfter;
  if (fromLedger != null) return fromLedger;

  return ref.watch(walletProvider).asData?.value?.balance;
});

/// Lifetime points earned — credits only, debits excluded.
///
/// Computed over the loaded page only, so it is labelled "recent" in the UI.
/// The non-decreasing lifetime Sustainability Score is a separate server-held
/// counter and is not this number.
final recentEarnedProvider = Provider.autoDispose<int>((ref) {
  final entries =
      ref.watch(ledgerProvider).asData?.value.entries ??
      const <TransactionModel>[];
  return entries
      .where((e) => e.isCredit)
      .fold<int>(0, (sum, e) => sum + e.delta);
});
