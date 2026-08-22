import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/account_profile.dart';
import 'auth_controller.dart';

/// Remembers the profile the person explicitly selected for this app session.
///
/// Null means "use the account's default". Keeping that distinction means an
/// Admin opens in the Admin profile and a Greenpreneur opens in the
/// Greenpreneur profile, while a deliberate switch survives navigation.
class AccountProfileController extends Notifier<AccountProfileSelection?> {
  @override
  AccountProfileSelection? build() => null;

  /// Selects only a profile the current stored role actually holds.
  bool select(AccountProfile profile) {
    final user = ref.read(currentUserProvider).value;
    if (user == null || !roleHoldsAccountProfile(user.role, profile)) {
      return false;
    }
    state = AccountProfileSelection(uid: user.uid, profile: profile);
    return true;
  }

  void useDefault() => state = null;
}

class AccountProfileSelection {
  const AccountProfileSelection({required this.uid, required this.profile});

  final String uid;
  final AccountProfile profile;
}

final accountProfileControllerProvider =
    NotifierProvider<AccountProfileController, AccountProfileSelection?>(
      AccountProfileController.new,
    );

/// The explicit selection for the current person only.
///
/// Tying the choice to the uid makes an identity change synchronous and safe:
/// another signed-in person can never inherit the previous person's UI mode.
final selectedAccountProfileProvider = Provider<AccountProfile?>((ref) {
  final uid = ref.watch(currentUserProvider).value?.uid;
  final selection = ref.watch(accountProfileControllerProvider);
  return selection?.uid == uid ? selection?.profile : null;
});

/// The effective profile, repaired automatically if the stored role changes.
///
/// For example, if an Admin account is later demoted while Champion was
/// selected, Champion remains valid; if Admin was selected, it falls back to
/// the new role's default. No stale UI mode can create stale permissions.
final activeAccountProfileProvider = Provider<AccountProfile>((ref) {
  final role = ref.watch(currentUserProvider).value?.role;
  if (role == null) return AccountProfile.champion;

  final selected = ref.watch(selectedAccountProfileProvider);
  if (selected != null && roleHoldsAccountProfile(role, selected)) {
    return selected;
  }
  return defaultAccountProfileForRole(role);
});
