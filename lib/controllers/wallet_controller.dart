import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/wallet_model.dart';
import 'auth_controller.dart';

/// Watches the signed-in user's wallet document.
/// Balance is read-only from the client — all mutations happen in
/// transactions in M2/M3, never by writing this document directly.
final walletProvider = StreamProvider<WalletModel?>((ref) {
  final user = ref.watch(currentUserProvider).value;
  if (user == null) return Stream.value(null);
  return ref.watch(userServiceProvider).watchWallet(user.uid);
});
