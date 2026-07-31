import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/transaction_model.dart';
import '../services/transaction_service.dart';
import 'current_user_provider.dart';

final transactionServiceProvider = Provider<TransactionService>((ref) {
  return TransactionService();
});

/// The signed-in user's ledger, newest first.
///
/// Emits an empty list rather than an error when signed out, so a sign-out
/// mid-session tears the screen down cleanly instead of flashing an error.
final ledgerProvider =
    StreamProvider.autoDispose<List<TransactionModel>>((ref) {
  final uid = ref.watch(currentUidProvider);
  if (uid == null) {
    return Stream<List<TransactionModel>>.value(const <TransactionModel>[]);
  }
  return ref.watch(transactionServiceProvider).watchUserTransactions(uid);
});

/// Balance taken from the newest ledger entry's `balanceAfter`.
///
/// Deliberately derived from the ledger rather than read from `wallets/{uid}`.
/// NFR-4 says the balance must be reconstructable from history; showing the
/// user a number that comes out of the history is that property made visible,
/// and it means this screen has exactly one data dependency.
///
/// Null when the ledger is empty, still loading, or when the newest entry
/// predates `balanceAfter` — the view falls back to the wallet figure in the
/// first case and hides the header in the others.
final ledgerBalanceProvider = Provider.autoDispose<int?>((ref) {
  final entries = ref.watch(ledgerProvider).asData?.value;
  if (entries == null || entries.isEmpty) return null;
  return entries.first.balanceAfter;
});

/// Lifetime points earned — credits only, debits excluded.
///
/// Computed over the loaded page only, so it is labelled "recent" in the UI.
/// The non-decreasing lifetime Sustainability Score is a separate server-held
/// counter and is not this number.
final recentEarnedProvider = Provider.autoDispose<int>((ref) {
  final entries = ref.watch(ledgerProvider).asData?.value ?? const [];
  return entries
      .where((e) => e.isCredit)
      .fold<int>(0, (sum, e) => sum + e.delta);
});
